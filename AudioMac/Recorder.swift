import AppKit
import AVFoundation

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case display = "Full Screen"
    case window = "Single Window"
    var id: String { rawValue }
}

enum SystemAudioState: Equatable {
    case starting
    case active
    case needsDriver
    case installing
    case failed(String)
}

/// Levels in dBFS (-60...0), kept apart from Recorder so only the meters redraw.
@MainActor
final class Levels: ObservableObject {
    static let floor: Float = -60
    @Published var system: Float = Levels.floor
    @Published var mic: Float = Levels.floor
}

@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    /// To try the Big Sur/Monterey code path (driver + older video APIs) on a recent macOS:
    /// `defaults write com.rikdev.audiomac ForceLegacyCapture -bool YES`
    static let forceLegacy = UserDefaults.standard.bool(forKey: "ForceLegacyCapture")

    /// ScreenCaptureKit (video) exists since macOS 12.3.
    static var usesLegacyVideo: Bool {
        if forceLegacy { return true }
        if #available(macOS 12.3, *) { return false }
        return true
    }

    /// ScreenCaptureKit system audio exists since macOS 13; earlier versions need the driver.
    static var usesDriverAudio: Bool {
        if forceLegacy { return true }
        if #available(macOS 13.0, *) { return false }
        return true
    }

    @Published var mode: CaptureMode = .display {
        didSet { refreshSources() }
    }
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var codec: VideoCodec = .h264
    @Published var fps = 60
    @Published var systemMuted = false {
        didSet { engine.systemMuted.value = systemMuted }
    }
    @Published var micMuted = false {
        didSet { engine.micMuted.value = micMuted }
    }
    @Published private(set) var micAvailable = false
    @Published private(set) var systemAudio: SystemAudioState = .starting
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var status = "Ready"
    @Published private(set) var lastFile: URL?

    let levels = Levels()
    private let engine = CaptureEngine()
    private var systemInput: AudioInput?
    private var micInput: AudioInput?
    private var videoSource: VideoSource?
    private var interruption: String?
    private var didSetup = false
    private var meterTimer: Timer?
    private var clockTimer: Timer?
    private var startDate: Date?
    private var activationObserver: NSObjectProtocol?

    private static let permissionMessage = "Permission missing: System Settings/Preferences → Privacy & Security → Screen Recording. Enable AudioMac, then come back to this window (reopen the app if Mac audio still doesn't start)."

    var driverInstalled: Bool { LoopbackDriver.isInstalled }

    func setup() async {
        guard !didSetup else { return }
        didSetup = true

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        OutputRouter.shared.cleanupLeftovers()
        micAvailable = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        refreshSources()
        await startMicrophone()
        await startSystemAudio()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevels() }
        }

        // The user typically grants Screen Recording in System Settings and then switches back:
        // retry the Mac audio capture instead of requiring a relaunch.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .failed = self.systemAudio else { return }
                await self.startSystemAudio()
            }
        }
    }

    func refreshSources() {
        displays = SourceCatalog.displays()
        windows = SourceCatalog.windows()
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id
        }
        if !windows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = windows.first?.id
        }
    }

    // MARK: - Audio sources

    private func startMicrophone() async {
        await micInput?.stop()
        micInput = nil
        guard micAvailable, let device = AVCaptureDevice.default(for: .audio) else { return }

        let input = DeviceAudioInput(device: device, channels: 1, source: .microphone, engine: engine)
        input.onError = { [weak self] error in
            Task { @MainActor in self?.status = "Microphone: \(error.localizedDescription)" }
        }
        do {
            try await input.start()
            micInput = input
        } catch {
            status = "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    private func startSystemAudio() async {
        await systemInput?.stop()
        systemInput = nil

        let input: AudioInput
        if !Self.usesDriverAudio, #available(macOS 13.0, *) {
            input = SCKSystemAudioInput(engine: engine)
        } else {
            guard LoopbackDriver.deviceID != nil else {
                systemAudio = .needsDriver
                return
            }
            input = LoopbackAudioInput(engine: engine)
        }
        input.onError = { [weak self] error in
            Task { @MainActor in self?.systemAudio = .failed(error.localizedDescription) }
        }

        systemAudio = .starting
        do {
            try await input.start()
            systemInput = input
            systemAudio = .active
            if status == Self.permissionMessage { status = "Ready" }
        } catch {
            systemAudio = .failed(error.localizedDescription)
            if !Self.usesDriverAudio { status = Self.permissionMessage }
        }
    }

    func installDriver() async {
        systemAudio = .installing
        do {
            try await LoopbackDriver.install()
            // Restarting coreaudiod also interrupts the microphone.
            await startMicrophone()
            await startSystemAudio()
            status = "Driver installed."
        } catch {
            systemAudio = .needsDriver
            status = error.localizedDescription
        }
        objectWillChange.send()
    }

    func uninstallDriver() async {
        guard !isRecording else { return }
        await systemInput?.stop()
        systemInput = nil
        do {
            try await LoopbackDriver.uninstall()
            status = "Driver removed."
        } catch {
            status = error.localizedDescription
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await startMicrophone()
        await startSystemAudio()
        objectWillChange.send()
    }

    // MARK: - Recording

    func toggle() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let target: CaptureTarget
        switch mode {
        case .display:
            guard let display = displays.first(where: { $0.id == selectedDisplayID }) ?? displays.first else {
                status = CaptureError.noDisplay.localizedDescription
                return
            }
            target = .display(display)
        case .window:
            let selected = selectedWindowID
            refreshSources()
            guard let window = windows.first(where: { $0.id == selected }) else {
                status = "The selected window no longer exists: pick another one."
                return
            }
            target = .window(window)
        }

        let size = target.videoSize
        let source = makeVideoSource(target: target, fps: fps, legacy: Self.usesLegacyVideo)
        source.onError = { [weak self] error in
            Task { @MainActor in self?.videoFailed(error) }
        }

        do {
            try engine.prepare(url: Self.makeOutputURL(), width: size.width, height: size.height,
                               codec: codec.avCodec, fps: fps, includeMic: micInput != nil)
            try await source.start(engine: engine)
        } catch {
            engine.cancel()
            await source.stop()
            status = "Couldn't start: \(error.localizedDescription)"
            return
        }

        videoSource = source
        interruption = nil
        isRecording = true
        startDate = Date()
        elapsed = 0
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        status = "Recording…"
    }

    func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        clockTimer?.invalidate()
        clockTimer = nil
        startDate = nil
        status = "Saving…"

        await videoSource?.stop()
        videoSource = nil
        let result = await withCheckedContinuation { continuation in
            engine.finish { continuation.resume(returning: $0) }
        }

        isRecording = false
        isBusy = false
        switch result {
        case .success(let url):
            lastFile = url
            status = (interruption.map { "\($0) " } ?? "") + "Saved: \(url.lastPathComponent)"
        case .failure(let error) where error is CancellationError:
            break
        case .failure(let error):
            status = "Recording not saved: \(error.localizedDescription)"
        }
        interruption = nil
    }

    private func videoFailed(_ error: Error) {
        guard isRecording else { return }
        interruption = "Recording interrupted (\(error.localizedDescription))."
        Task { await stop() }
    }

    /// Called when the app quits.
    func shutdown() async {
        await stop()
        await systemInput?.stop()
        await micInput?.stop()
        OutputRouter.shared.restore()
    }

    func revealLastFile() {
        guard let lastFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    // MARK: - Levels

    private func updateLevels() {
        let system = Self.decayed(levels.system, peak: engine.systemLevel.take())
        let mic = Self.decayed(levels.mic, peak: engine.micLevel.take())
        if system != levels.system { levels.system = system }
        if mic != levels.mic { levels.mic = mic }
    }

    /// Instant attack, ~45 dB/s release.
    private static func decayed(_ current: Float, peak: Float) -> Float {
        let db = peak > 0 ? max(Levels.floor, 20 * log10(peak)) : Levels.floor
        return max(db, current - 1.5, Levels.floor)
    }

    private static func makeOutputURL() -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("AudioMac \(formatter.string(from: Date())).mov")
    }
}
