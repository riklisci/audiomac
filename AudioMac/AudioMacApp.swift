import SwiftUI

@main
struct AudioMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder.shared

    var body: some Scene {
        WindowGroup("AudioMac") {
            ContentView()
                .environmentObject(recorder)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                    recorder.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Properly closes the file being recorded and restores the audio output before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await Recorder.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        OutputRouter.shared.restore()
    }
}
