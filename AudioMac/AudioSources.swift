@preconcurrency import AVFoundation
import ScreenCaptureKit

/// Sorgente audio sempre attiva (alimenta i livelli e, durante la registrazione, il file):
/// consegna i buffer a `engine.appendAudio` sulla coda del motore, con timestamp nel clock host.
protocol AudioInput: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    func start() async throws
    func stop() async
}

// MARK: - Dispositivo di ingresso (microfono o driver loopback), tutte le versioni

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

        // startRunning è bloccante: fuori dal main thread.
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

    /// I buffer di AVCaptureSession sono nel clock della sessione; video e altre sorgenti usano il clock host.
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

// MARK: - macOS 13+: audio di sistema con ScreenCaptureKit

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
        // Filtro sull'intero schermo: così l'audio è quello di tutto il Mac (tranne AudioMac),
        // anche quando il video registra una sola finestra.
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
        // ScreenCaptureKit produce comunque video: lo scartiamo.
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

// MARK: - macOS 11–12: audio di sistema tramite il driver AudioMac Loopback

/// Instrada l'uscita audio su "altoparlanti + loopback" e registra dall'ingresso del loopback.
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
