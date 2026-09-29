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
/// Everything is restored when the app quits.
final class OutputRouter {
    static let shared = OutputRouter()

    private static let aggregateUID = "com.rikdev.audiomac.multioutput"
    private static let previousOutputKey = "PreviousOutputUID"
    private let lock = NSLock()
    private var aggregateID: AudioObjectID?
    private var previousOutput: AudioDeviceID?

    func route() throws {
        lock.lock()
        defer { lock.unlock() }
        guard aggregateID == nil else { return }
        removeLeftover()

        guard let loopback = LoopbackDriver.deviceID,
              let current = CoreAudioDevices.defaultOutput else { throw CaptureError.noAudioDevice }
        // If the output already is the loopback, audio reaches the driver anyway (but not the speakers).
        guard current != loopback, let speakerUID = CoreAudioDevices.uid(of: current) else { return }

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
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw CaptureError.noAudioDevice }

        UserDefaults.standard.set(speakerUID, forKey: Self.previousOutputKey)
        CoreAudioDevices.defaultOutput = aggregate
        aggregateID = aggregate
        previousOutput = current
    }

    func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let aggregate = aggregateID else { return }
        if let previousOutput, CoreAudioDevices.defaultOutput == aggregate {
            CoreAudioDevices.defaultOutput = previousOutput
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        aggregateID = nil
        previousOutput = nil
        UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
    }

    /// Removes a Multi-Output Device left over from a run that didn't quit cleanly.
    func cleanupLeftovers() {
        lock.lock()
        defer { lock.unlock() }
        removeLeftover()
    }

    private func removeLeftover() {
        guard aggregateID == nil, let leftover = CoreAudioDevices.device(withUID: Self.aggregateUID) else { return }
        if CoreAudioDevices.defaultOutput == leftover,
           let uid = UserDefaults.standard.string(forKey: Self.previousOutputKey),
           let previous = CoreAudioDevices.device(withUID: uid) {
            CoreAudioDevices.defaultOutput = previous
        }
        AudioHardwareDestroyAggregateDevice(leftover)
        UserDefaults.standard.removeObject(forKey: Self.previousOutputKey)
    }
}
