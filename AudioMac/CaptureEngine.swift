import Accelerate
import AVFoundation

/// Accumulates the (linear) peak between reads. Thread-safe.
final class LevelMeter {
    private let lock = NSLock()
    private var peak: Float = 0

    func report(_ value: Float) {
        lock.lock(); peak = max(peak, value); lock.unlock()
    }

    func take() -> Float {
        lock.lock(); defer { peak = 0; lock.unlock() }
        return peak
    }
}

final class AtomicBool {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum AudioSource { case system, microphone }

/// Receives video frames and audio buffers from the sources (all called on `queue`),
/// updates the levels and, while recording, writes the file with AVAssetWriter.
/// All timestamps are on the host clock (mach_absolute_time).
final class CaptureEngine: @unchecked Sendable {
    /// Serial queue on which sources deliver their samples.
    let queue = DispatchQueue(label: "audiomac.capture", qos: .userInitiated)
    let systemLevel = LevelMeter()
    let micLevel = LevelMeter()
    let systemMuted = AtomicBool(false)
    let micMuted = AtomicBool(false)

    // Confined to `queue`.
    private var recording: Recording?

    private final class Recording {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let system: AVAssetWriterInput
        let mic: AVAssetWriterInput?
        var startTime: CMTime?
        var lastVideoTime: CMTime?
        var systemNext = CMTime.invalid
        var micNext = CMTime.invalid
        var endTime = CMTime.invalid

        init(writer: AVAssetWriter, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
             system: AVAssetWriterInput, mic: AVAssetWriterInput?) {
            self.writer = writer
            self.video = video
            self.adaptor = adaptor
            self.system = system
            self.mic = mic
        }

        func extend(to time: CMTime) {
            if !endTime.isValid || time > endTime { endTime = time }
        }
    }

    // MARK: - Recording

    func prepare(url: URL, width: Int, height: Int, codec: AVVideoCodecType, fps: Int, includeMic: Bool) throws {
        try queue.sync {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: max(2_000_000, Int(Double(width * height * fps) * (codec == .hevc ? 0.04 : 0.07))),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
            if codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ])
            video.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

            let system = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 2))
            system.expectsMediaDataInRealTime = true

            var mic: AVAssetWriterInput?
            if includeMic {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings(channels: 1))
                input.expectsMediaDataInRealTime = true
                mic = input
            }

            for input in [video, system] + (mic.map { [$0] } ?? []) {
                guard writer.canAdd(input) else { throw CaptureError.writerSetup }
                writer.add(input)
            }
            guard writer.startWriting() else { throw writer.error ?? CaptureError.writerSetup }
            recording = Recording(writer: writer, video: video, adaptor: adaptor, system: system, mic: mic)
        }
    }

    /// Cancels a recording that was prepared but never started (e.g. the video source failed to start).
    func cancel() {
        queue.sync {
            guard let rec = recording else { return }
            recording = nil
            rec.writer.cancelWriting()
            try? FileManager.default.removeItem(at: rec.writer.outputURL)
        }
    }

    /// Finalizes the file. `completion` is called on an arbitrary queue.
    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            guard let rec = self.recording else {
                completion(.failure(CancellationError()))
                return
            }
            self.recording = nil
            let url = rec.writer.outputURL

            guard rec.startTime != nil, rec.writer.status == .writing else {
                let error = rec.writer.error ?? CaptureError.noFrames
                rec.writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                completion(.failure(error))
                return
            }
            rec.video.markAsFinished()
            rec.system.markAsFinished()
            rec.mic?.markAsFinished()
            rec.writer.endSession(atSourceTime: rec.endTime)
            rec.writer.finishWriting {
                if rec.writer.status == .completed {
                    completion(.success(url))
                } else {
                    completion(.failure(rec.writer.error ?? CaptureError.writerSetup))
                }
            }
        }
    }

    private static func aacSettings(channels: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    // MARK: - Sample input (on `queue`)

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let rec = recording, rec.writer.status == .writing else { return }

        if rec.startTime == nil {
            rec.writer.startSession(atSourceTime: pts)
            rec.startTime = pts
            rec.systemNext = pts
            rec.micNext = pts
        }
        if let last = rec.lastVideoTime, pts <= last { return }
        guard rec.video.isReadyForMoreMediaData else { return }
        if rec.adaptor.append(pixelBuffer, withPresentationTime: pts) {
            rec.lastVideoTime = pts
            rec.extend(to: pts)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, from source: AudioSource) {
        dispatchPrecondition(condition: .onQueue(queue))
        let isSystem = source == .system
        (isSystem ? systemLevel : micLevel).report(Self.peak(of: sampleBuffer))

        guard let rec = recording, let start = rec.startTime, rec.writer.status == .writing,
              let input = isSystem ? rec.system : rec.mic,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts >= start else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let timescale = CMTimeScale(asbd.mSampleRate)
        var next = isSystem ? rec.systemNext : rec.micNext

        // If the source skipped buffers (e.g. nothing is playing), fill the gap with silence
        // to keep the track in sync with the video.
        let gap = CMTimeGetSeconds(pts - next)
        if gap > 0.02 {
            var remaining = Int((gap * asbd.mSampleRate).rounded())
            while remaining > 0 {
                let chunk = min(remaining, Int(asbd.mSampleRate))
                if input.isReadyForMoreMediaData,
                   let silence = Self.silentBuffer(format: format, frames: chunk, at: next) {
                    input.append(silence)
                }
                next = next + CMTime(value: CMTimeValue(chunk), timescale: timescale)
                remaining -= chunk
            }
        }

        let muted = (isSystem ? systemMuted : micMuted).value
        let buffer = muted ? Self.silentBuffer(format: format, frames: frames, at: pts) : sampleBuffer
        if let buffer, input.isReadyForMoreMediaData {
            input.append(buffer)
        }
        next = pts + CMTime(value: CMTimeValue(frames), timescale: timescale)
        if isSystem { rec.systemNext = next } else { rec.micNext = next }
        rec.extend(to: next)
    }

    // MARK: - Buffer utilities

    /// Linear peak (0...1) of a PCM buffer.
    static func peak(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }

        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
              size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer) == noErr
        else { return 0 }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            switch (isFloat, asbd.mBitsPerChannel) {
            case (true, 32):
                var value: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &value, vDSP_Length(bytes / 4))
                peak = max(peak, value)
            case (false, 16):
                for sample in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: bytes / 2) {
                    peak = max(peak, abs(Float(sample)) / 32_768)
                }
            case (false, 32):
                for sample in UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: bytes / 4) {
                    peak = max(peak, abs(Float(sample)) / 2_147_483_648)
                }
            default:
                break
            }
        }
        return min(peak, 1)
    }

    /// Silent PCM buffer with the same format as `format`.
    static func silentBuffer(format: CMAudioFormatDescription, frames: Int, at pts: CMTime) -> CMSampleBuffer? {
        guard frames > 0, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let length = frames * Int(asbd.mBytesPerFrame) * (nonInterleaved ? Int(asbd.mChannelsPerFrame) : 1)

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) == noErr
        else { return nil }

        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &out)
        return out
    }
}

enum CaptureError: LocalizedError {
    case writerSetup
    case noFrames
    case targetGone
    case videoStart
    case noDisplay
    case noAudioDevice
    case driverMissing
    case driverInstall(String)

    var errorDescription: String? {
        switch self {
        case .writerSetup: return "Couldn't create the video file."
        case .noFrames: return "No frames were received."
        case .targetGone: return "The selected window or display is no longer available."
        case .videoStart: return "Couldn't start video capture."
        case .noDisplay: return "No display available."
        case .noAudioDevice: return "Audio device not found."
        case .driverMissing: return "The AudioMac Loopback driver isn't installed."
        case .driverInstall(let message): return "Driver installation failed: \(message)"
        }
    }
}
