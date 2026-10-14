import CoreAudio
import Foundation

/// Minimal access to the CoreAudio properties we need.
enum CoreAudioDevices {
    /// kAudioObjectPropertyElementMain (= 0), only available under that name since macOS 12.
    private static let elementMain: AudioObjectPropertyElement = 0

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: elementMain)
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func device(withUID uid: String) -> AudioDeviceID? {
        allDevices().first { self.uid(of: $0) == uid }
    }

    static var defaultOutput: AudioDeviceID? {
        get {
            var address = address(kAudioHardwarePropertyDefaultOutputDevice)
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown else { return nil }
            return device
        }
        set {
            guard var device = newValue else { return }
            var address = address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        }
    }

    /// Calls `block` (on `queue`) whenever the default output device changes.
    @discardableResult
    static func addDefaultOutputListener(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) -> Bool {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr
    }

    /// `block` must be the same object passed to `addDefaultOutputListener`.
    static func removeDefaultOutputListener(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
}

/// The AudioMac Loopback driver bundled with the app (only used on macOS 11–12).
enum LoopbackDriver {
    static let deviceUID = "AudioMacLoopback_UID"
    private static let bundleName = "AudioMacLoopback.driver"
    private static let installPath = "/Library/Audio/Plug-Ins/HAL/AudioMacLoopback.driver"

    /// The device is loaded by CoreAudio.
    static var deviceID: AudioDeviceID? { CoreAudioDevices.device(withUID: deviceUID) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installPath) }

    static func install() async throws {
        guard let source = Bundle.main.url(forResource: "AudioMacLoopback", withExtension: "driver") else {
            throw CaptureError.driverInstall("the driver isn't bundled with the app.")
        }
        try await runAsAdministrator([
            "mkdir -p /Library/Audio/Plug-Ins/HAL",
            "rm -rf \(shellQuoted(installPath))",
            "cp -R \(shellQuoted(source.path)) \(shellQuoted(installPath))",
            "chown -R root:wheel \(shellQuoted(installPath))",
            "killall coreaudiod",
        ].joined(separator: " && "))

        // launchd restarts coreaudiod, which loads the driver.
        for _ in 0..<40 {
            if deviceID != nil { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CaptureError.driverInstall("the device didn't show up. Restart your Mac and try again.")
    }

    static func uninstall() async throws {
        try await runAsAdministrator("rm -rf \(shellQuoted(installPath)) && killall coreaudiod")
    }

    /// Runs a shell command with administrator privileges (macOS asks for the password).
    private static func runAsAdministrator(_ command: String) async throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if message.contains("-128") { throw CaptureError.driverInstall("cancelled.") }
            throw CaptureError.driverInstall(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// While AudioMac is open (macOS 11–12 only), the default output becomes a Multi-Output Device
/// "speakers + AudioMac Loopback": you keep hearing the audio and the loopback receives it for recording.
/// If the user picks another output meanwhile (headphones, AirPods...), the Multi-Output Device is rebuilt
/// around it. Everything is restored when the app quits.
final class OutputRouter {
    static let shared = OutputRouter()

    private static let aggregateUID = "com.rikdev.audiomac.multioutput"
    private static let previousOutputKey = "PreviousOutputUID"
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "audiomac.output-router")
    // Everything below is protected by `lock`.
    private var routing = false
    private var aggregateID: AudioObjectID?
    private var previousOutput: AudioDeviceID?
    private var listener: AudioObjectPropertyListenerBlock?

    func route() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !routing else { return }
        removeLeftover()

        guard let loopback = LoopbackDriver.deviceID,
              let current = CoreAudioDevices.defaultOutput else { throw CaptureError.noAudioDevice }
        // If the output already is the loopback, audio reaches the driver anyway (but not the speakers).
        if current != loopback {
            guard rebuildAggregate(around: current) else {
                previousOutput = nil
                UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
                throw CaptureError.noAudioDevice
            }
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultOutputChanged(retries: 2) }
        listener = block
        routing = true
        CoreAudioDevices.addDefaultOutputListener(queue: listenerQueue, block: block)
    }

    func restore() {
        lock.lock()
        guard routing else {
            lock.unlock()
            return
        }
        routing = false
        let block = listener
        listener = nil
        if let aggregate = aggregateID {
            if let previousOutput, CoreAudioDevices.defaultOutput == aggregate {
                CoreAudioDevices.defaultOutput = previousOutput
            }
            destroyAggregate()
        }
        previousOutput = nil
        UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
        lock.unlock()
        // Outside the lock: a notification being delivered right now waits for it. It then sees `routing == false`.
        if let block { CoreAudioDevices.removeDefaultOutputListener(queue: listenerQueue, block: block) }
    }

    /// Removes a Multi-Output Device left over from a run that didn't quit cleanly.
    func cleanupLeftovers() {
        lock.lock()
        defer { lock.unlock() }
        removeLeftover()
    }

    /// Runs on `listenerQueue` when the default output changes. The loopback capture itself doesn't need to
    /// restart: the loopback device is the same, it just receives audio from a new Multi-Output Device.
    private func defaultOutputChanged(retries: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard routing, let loopback = LoopbackDriver.deviceID, let current = CoreAudioDevices.defaultOutput else { return }
        // Our own change (or nothing to do).
        if current == aggregateID { return }
        if current == loopback {
            // The user chose the loopback itself: audio reaches it anyway, the Multi-Output Device isn't needed.
            destroyAggregate()
            UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
            return
        }
        if !rebuildAggregate(around: current), retries > 0 {
            // The new device may not be ready yet (e.g. Bluetooth just connected).
            listenerQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.defaultOutputChanged(retries: retries - 1) }
        }
    }

    /// Creates the Multi-Output Device with `device` as main sub-device and makes it the default output,
    /// replacing the previous one. `device` is what the user chose, so it's what we restore at the end.
    /// Must be called with `lock` held.
    private func rebuildAggregate(around device: AudioDeviceID) -> Bool {
        guard let speakerUID = CoreAudioDevices.uid(of: device) else { return false }
        previousOutput = device
        UserDefaults.standard.set(speakerUID, forKey: Self.previousOutputKey)
        // The UID must be free: the old one is not the default output at this point, it's safe to remove.
        destroyAggregate()

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceNameKey: "AudioMac (Speakers + Recording)",
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
            "master": speakerUID, // kAudioAggregateDeviceMainSubDeviceKey
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: speakerUID],
                [kAudioSubDeviceUIDKey: LoopbackDriver.deviceUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var aggregate = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate) == noErr else { return false }
        aggregateID = aggregate
        CoreAudioDevices.defaultOutput = aggregate
        return true
    }

    /// Must be called with `lock` held.
    private func destroyAggregate() {
        guard let aggregate = aggregateID else { return }
        aggregateID = nil
        AudioHardwareDestroyAggregateDevice(aggregate)
    }

    private func removeLeftover() {
        guard !routing, let leftover = CoreAudioDevices.device(withUID: Self.aggregateUID) else { return }
        if CoreAudioDevices.defaultOutput == leftover,
           let uid = UserDefaults.standard.string(forKey: Self.previousOutputKey),
           let previous = CoreAudioDevices.device(withUID: uid) {
            CoreAudioDevices.defaultOutput = previous
        }
        AudioHardwareDestroyAggregateDevice(leftover)
        UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
    }
}
