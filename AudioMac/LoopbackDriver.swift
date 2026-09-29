import CoreAudio
import Foundation

/// Accesso minimo alle proprietà CoreAudio necessarie.
enum CoreAudioDevices {
    /// kAudioObjectPropertyElementMain (= 0), disponibile con quel nome solo da macOS 12.
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

/// Il driver AudioMac Loopback incluso nell'app (usato solo su macOS 11–12).
enum LoopbackDriver {
    static let deviceUID = "AudioMacLoopback_UID"
    private static let bundleName = "AudioMacLoopback.driver"
    private static let installPath = "/Library/Audio/Plug-Ins/HAL/AudioMacLoopback.driver"

    /// Il dispositivo è caricato da CoreAudio.
    static var deviceID: AudioDeviceID? { CoreAudioDevices.device(withUID: deviceUID) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installPath) }

    static func install() async throws {
        guard let source = Bundle.main.url(forResource: "AudioMacLoopback", withExtension: "driver") else {
            throw CaptureError.driverInstall("il driver non è incluso nell'app.")
        }
        try await runAsAdministrator([
            "mkdir -p /Library/Audio/Plug-Ins/HAL",
            "rm -rf \(shellQuoted(installPath))",
            "cp -R \(shellQuoted(source.path)) \(shellQuoted(installPath))",
            "chown -R root:wheel \(shellQuoted(installPath))",
            "killall coreaudiod",
        ].joined(separator: " && "))

        // coreaudiod viene riavviato da launchd e carica il driver.
        for _ in 0..<40 {
            if deviceID != nil { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CaptureError.driverInstall("il dispositivo non è comparso. Riavvia il Mac e riprova.")
    }

    static func uninstall() async throws {
        try await runAsAdministrator("rm -rf \(shellQuoted(installPath)) && killall coreaudiod")
    }

    /// Esegue un comando shell con i privilegi di amministratore (macOS chiede la password).
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
            if message.contains("-128") { throw CaptureError.driverInstall("operazione annullata.") }
            throw CaptureError.driverInstall(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Mentre AudioMac è aperta (solo macOS 11–12), l'uscita predefinita diventa un dispositivo multi-uscita
/// "altoparlanti + AudioMac Loopback": continui a sentire l'audio e il loopback lo riceve per la registrazione.
/// All'uscita dall'app tutto torna com'era.
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
        // Se l'uscita è già il loopback l'audio arriva comunque al driver (ma non agli altoparlanti).
        guard current != loopback, let speakerUID = CoreAudioDevices.uid(of: current) else { return }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: Self.aggregateUID,
            kAudioAggregateDeviceNameKey: "AudioMac (altoparlanti + registrazione)",
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

    /// Rimuove il dispositivo multi-uscita rimasto da un'esecuzione terminata in modo anomalo.
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
