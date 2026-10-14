import AppKit
import AVFoundation
import CoreAudio

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
    @Published private(set) var outputFolder: URL = Recorder.storedOutputFolder()

    let levels = Levels()
    private let engine = CaptureEngine()
    private var systemInput: AudioInput?
    private var micInput: AudioInput?
    private var micDeviceUID: String?
    private var videoSource: VideoSource?
    private var interruption: String?
    private var didSetup = false
    private var meterTimer: Timer?
    private var clockTimer: Timer?
    private var startDate: Date?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    /// In-flight start/stop, so `shutdown()` can wait for it.
    private var operation: Task<Void, Never>?
    private var isShuttingDown = false
    // Bumped on every (re)start of an input: a call that finds a newer generation after an `await` lost the race.
    private var micGeneration = 0
    private var systemGeneration = 0

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
        installInputListener()

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

        // Displays connected/disconnected or resolution changed.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
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
        micGeneration += 1
        let generation = micGeneration
        let previous = micInput
        micInput = nil
        await previous?.stop()
        guard generation == micGeneration, !isShuttingDown, micAvailable,
              let device = MicrophoneSelection.device() else { return }

        let input = DeviceAudioInput(device: device, channels: 1, source: .microphone, engine: engine)
        input.onError = { [weak self] error in
            Task { @MainActor in self?.status = "Microphone: \(error.localizedDescription)" }
        }
        do {
            try await input.start()
            if generation == micGeneration {
                micInput = input
                micDeviceUID = device.uniqueID
            } else {
                await input.stop()
            }
        } catch {
            if generation == micGeneration { status = "Microphone unavailable: \(error.localizedDescription)" }
        }
    }

    /// Follows the system default input device (System Settings, headset plugged in, active mic unplugged).
    private func installInputListener() {
        guard inputListener == nil else { return }
        var address = MicrophoneSelection.defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                // Restart only if the device we'd pick changed: a restart leaves a short gap in a recording.
                guard let self, self.micInput == nil || MicrophoneSelection.device()?.uniqueID != self.micDeviceUID
                else { return }
                await self.startMicrophone()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr
        else { return }
        inputListener = listener
    }

    private func removeObservers() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        activationObserver = nil
        screenObserver = nil
        if let listener = inputListener {
            var address = MicrophoneSelection.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            inputListener = nil
        }
    }

    private func startSystemAudio() async {
        systemGeneration += 1
        let generation = systemGeneration
        let previous = systemInput
        systemInput = nil
        await previous?.stop()
        guard generation == systemGeneration, !isShuttingDown else { return }

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
            guard generation == systemGeneration else {
                await input.stop()
                return
            }
            systemInput = input
            systemAudio = .active
            if status == Self.permissionMessage { status = "Ready" }
        } catch {
            guard generation == systemGeneration else { return }
            systemAudio = .failed(error.localizedDescription)
            // Other errors are already shown under the Mac Audio meter.
            if !Self.usesDriverAudio, !CGPreflightScreenCaptureAccess() { status = Self.permissionMessage }
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
        systemGeneration += 1 // also cancels a start still in flight
        let previous = systemInput
        systemInput = nil
        await previous?.stop()
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
        guard !isRecording, !isBusy, !isShuttingDown else { return }
        await runExclusive { await self.performStart() }
    }

    func stop() async {
        guard isRecording, !isBusy else { return }
        await runExclusive { await self.performStop() }
    }

    /// Runs a start/stop as a tracked task (`isBusy` while it runs) so `shutdown()` can wait for it.
    private func runExclusive(_ body: @escaping @MainActor () async -> Void) async {
        isBusy = true
        let task = Task { @MainActor in
            await body()
            self.isBusy = false
            self.operation = nil
        }
        operation = task
        await task.value
    }

    private func performStart() async {
        let target: CaptureTarget
        switch mode {
        case .display:
            // Re-read the displays: the list may be stale (resolution or arrangement changed).
            let selected = selectedDisplayID
            refreshSources()
            guard !displays.isEmpty else {
                status = CaptureError.noDisplay.localizedDescription
                return
            }
            let display = selected == nil ? displays.first : displays.first { $0.id == selected }
            guard let display else {
                status = "The selected display is no longer available: pick another one."
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

        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputFolder.path, isDirectory: &isFolder), isFolder.boolValue else {
            status = "The save folder \"\(outputFolder.lastPathComponent)\" no longer exists: choose another one."
            return
        }

        let size = target.videoSize
        let source = makeVideoSource(target: target, fps: fps, legacy: Self.usesLegacyVideo)
        source.onError = { [weak self] error in
            Task { @MainActor in self?.interrupt(error) }
        }
        engine.onWriterFailure = { [weak self] error in
            Task { @MainActor in self?.interrupt(error) }
        }

        do {
            try engine.prepare(url: makeOutputURL(), width: size.width, height: size.height,
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

    private func performStop() async {
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

    /// The video source or the file writer failed mid-recording: stop and save what we have (if possible).
    private func interrupt(_ error: Error) {
        guard isRecording else { return }
        interruption = "Recording interrupted (\(error.localizedDescription))."
        Task { await stop() }
    }

    /// Called when the app quits: waits for an in-flight start/stop and finalizes the recording.
    func shutdown() async {
        isShuttingDown = true
        micGeneration += 1 // cancels inputs still starting
        systemGeneration += 1
        removeObservers()
        repeat {
            while let operation { await operation.value }
            await stop()
        } while isRecording || operation != nil
        await systemInput?.stop()
        await micInput?.stop()
        OutputRouter.shared.restore()
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save recordings"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputFolder = url
        UserDefaults.standard.set(url.path, forKey: Self.outputFolderKey)
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

    private static let outputFolderKey = "OutputFolder"

    private static var defaultOutputFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }

    private static func storedOutputFolder() -> URL {
        guard let path = UserDefaults.standard.string(forKey: outputFolderKey) else { return defaultOutputFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        // Fixed Gregorian/Latin format, whatever the user's locale or calendar.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return outputFolder.appendingPathComponent("AudioMac \(formatter.string(from: Date())).mov")
    }
}

/// Picks the microphone: the system default input, but never the AudioMac Loopback driver
/// (it can become the default input on Macs without a built-in mic and would record the Mac audio).
private enum MicrophoneSelection {
    static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: 0) // kAudioObjectPropertyElementMain, only available under that name since macOS 12

    static func device() -> AVCaptureDevice? {
        // A CoreAudio device UID equals the AVCaptureDevice uniqueID.
        if let uid = defaultInputUID() {
            if uid != LoopbackDriver.deviceUID, let device = AVCaptureDevice(uniqueID: uid) { return device }
        } else if let device = AVCaptureDevice.default(for: .audio), device.uniqueID != LoopbackDriver.deviceUID {
            return device
        }
        // The default is the loopback (or unusable): any other audio input.
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown],
                                                       mediaType: .audio, position: .unspecified)
        return session.devices.first { $0.uniqueID != LoopbackDriver.deviceUID }
    }

    private static func defaultInputUID() -> String? {
        var address = defaultInputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return CoreAudioDevices.uid(of: device)
    }
}
