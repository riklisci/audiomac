@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Always-on audio source (feeds the level meters and, while recording, the file):
/// delivers buffers to `engine.appendAudio` on the engine's queue, timestamped on the host clock.
protocol AudioInput: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

// MARK: - Input device (microphone or loopback driver), all versions

final class DeviceAudioInput: NSObject, AudioInput, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onError: ((Error) -> Void)?
    private let device: AVCaptureDevice
    private let channels: Int
    private let source: AudioSource
    private let engine: CaptureEngine
    private let session = AVCaptureSession()
    private var errorObserver: NSObjectProtocol?

    init(device: AVCaptureDevice, channels: Int, source: AudioSource, engine: CaptureEngine) {
        self.device = device
        self.channels = channels
        self.source = source
        self.engine = engine
    }

    func start() async throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: engine.queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.noAudioDevice
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CaptureError.noAudioDevice
            self?.onError?(error)
        }

        // startRunning blocks: keep it off the main thread.
        let session = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() async {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        let session = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine.appendAudio(hostTimed(sampleBuffer), from: source)
    }

    /// AVCaptureSession buffers are on the session clock; video and the other sources use the host clock.
    private func hostTimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        let clock: CMClock?
        if #available(macOS 12.3, *) {
            clock = session.synchronizationClock
        } else {
            clock = session.masterClock
        }
        let host = CMClockGetHostTimeClock()
        guard let clock, !CFEqual(clock, host) else { return sampleBuffer }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock, to: host),
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out ?? sampleBuffer
    }
}

// MARK: - macOS 13+: system audio with ScreenCaptureKit

@available(macOS 13.0, *)
final class SCKSystemAudioInput: NSObject, AudioInput, SCStreamOutput, SCStreamDelegate {
    var onError: ((Error) -> Void)?
    private let engine: CaptureEngine
    private var stream: SCStream?
    private let discard = DiscardOutput()

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // Full-display filter: the audio is the whole Mac's (except AudioMac),
        // even when the video records a single window.
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // ScreenCaptureKit always produces video: discard it.
        try stream.addStreamOutput(discard, type: .screen, sampleHandlerQueue: engine.queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: engine.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        engine.appendAudio(sampleBuffer, from: .system)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

@available(macOS 12.3, *)
private final class DiscardOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: - macOS 11–12: system audio through the AudioMac Loopback driver

/// Routes the audio output to "speakers + loopback" and records from the loopback input.
final class LoopbackAudioInput: AudioInput {
    var onError: ((Error) -> Void)? {
        didSet { capture?.onError = onError }
    }
    private let engine: CaptureEngine
    private var capture: DeviceAudioInput?

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func start() async throws {
        guard LoopbackDriver.deviceID != nil,
              let device = AVCaptureDevice(uniqueID: LoopbackDriver.deviceUID) else { throw CaptureError.driverMissing }
        try OutputRouter.shared.route()
        let capture = DeviceAudioInput(device: device, channels: 2, source: .system, engine: engine)
        capture.onError = onError
        do {
            try await capture.start()
        } catch {
            OutputRouter.shared.restore()
            throw error
        }
        self.capture = capture
    }

    func stop() async {
        await capture?.stop()
        capture = nil
        OutputRouter.shared.restore()
    }
}
