import SwiftUI

// Only SwiftUI APIs available since macOS 11.

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            videoSection
                .disabled(recorder.isRecording || recorder.isBusy)
            Divider()
            audioSection
            Divider()
            controls
            Text(recorder.status)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            Task { await recorder.setup() }
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video").font(.headline)

            Picker("", selection: $recorder.mode) {
                ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(SegmentedPickerStyle())
            .labelsHidden()

            switch recorder.mode {
            case .display:
                Picker("Display:", selection: $recorder.selectedDisplayID) {
                    ForEach(recorder.displays) { display in
                        Text("\(display.name) — \(display.pixelWidth)×\(display.pixelHeight)")
                            .tag(Optional(display.id))
                    }
                }
            case .window:
                HStack {
                    Picker("Window:", selection: $recorder.selectedWindowID) {
                        ForEach(recorder.windows) { window in
                            Text(window.label).tag(Optional(window.id))
                        }
                    }
                    Button {
                        recorder.refreshSources()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh the window list")
                }
            }

            HStack(spacing: 20) {
                Picker("Codec:", selection: $recorder.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Frame rate:", selection: $recorder.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }

            HStack {
                Text("Save to:")
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(recorder.outputFolder.abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(recorder.outputFolder.path)
                Spacer(minLength: 8)
                Button("Choose…", action: recorder.chooseOutputFolder)
            }
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio").font(.headline)

            ChannelStrip(title: "Mac Audio",
                         icon: "speaker.wave.2.fill", mutedIcon: "speaker.slash.fill",
                         level: \.system, muted: $recorder.systemMuted)
                .disabled(recorder.systemAudio != .active)
            systemAudioNote

            ChannelStrip(title: "Microphone",
                         icon: "mic.fill", mutedIcon: "mic.slash.fill",
                         level: \.mic, muted: $recorder.micMuted)
                .disabled(!recorder.micAvailable)
            if !recorder.micAvailable {
                note("Microphone access denied: Privacy & Security → Microphone.")
            }
        }
    }

    @ViewBuilder
    private var systemAudioNote: some View {
        switch recorder.systemAudio {
        case .needsDriver:
            VStack(alignment: .leading, spacing: 6) {
                note("On this version of macOS, internal audio is captured with the AudioMac Loopback driver (requires an administrator password).")
                Button("Install Audio Driver…") {
                    Task { await recorder.installDriver() }
                }
            }
        case .installing:
            note("Installing the driver…")
        case .failed(let message):
            note("Mac audio unavailable: \(message)")
        case .active where Recorder.usesDriverAudio:
            HStack {
                note("While AudioMac is open, audio is routed through \"AudioMac (Speakers + Recording)\": the volume keys are unavailable.")
                Button("Uninstall Driver") {
                    Task { await recorder.uninstallDriver() }
                }
                .disabled(recorder.isRecording)
            }
        default:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        HStack {
            Button(action: recorder.toggle) {
                Label(recorder.isRecording ? "Stop" : "Record",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundColor(recorder.isRecording ? .red : nil)
                    .frame(minWidth: 110)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(recorder.isBusy)

            if recorder.isRecording {
                Text(recorder.elapsedText)
                    .font(Font.body.monospacedDigit())
                    .foregroundColor(.red)
            }
            Spacer()
            if recorder.lastFile != nil, !recorder.isRecording {
                Button("Show in Finder", action: recorder.revealLastFile)
            }
        }
    }
}

private extension URL {
    var abbreviatingWithTildeInPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Row with a mute button and a level meter. The meter always shows the incoming signal,
/// even when the source is muted (then it's dimmed and silence goes into the file).
struct ChannelStrip: View {
    @EnvironmentObject private var recorder: Recorder
    let title: String
    let icon: String
    let mutedIcon: String
    let level: KeyPath<Levels, Float>
    @Binding var muted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                muted.toggle()
            } label: {
                Image(systemName: muted ? mutedIcon : icon)
                    .foregroundColor(muted ? .red : .primary)
                    .frame(width: 20)
            }
            .buttonStyle(BorderlessButtonStyle())
            .help(muted ? "Unmute \(title)" : "Mute \(title)")

            Text(title)
                .frame(width: 110, alignment: .leading)

            LevelMeterView(levels: recorder.levels, level: level)
                .opacity(muted ? 0.35 : 1)
        }
    }
}

struct LevelMeterView: View {
    @ObservedObject var levels: Levels
    let level: KeyPath<Levels, Float>

    var body: some View {
        let db = levels[keyPath: level]
        let fraction = CGFloat((db - Levels.floor) / -Levels.floor)
        return HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    LinearGradient(gradient: Gradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.7),
                        .init(color: .yellow, location: 0.85),
                        .init(color: .red, location: 1),
                    ]), startPoint: .leading, endPoint: .trailing)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: geo.size.width * fraction)
                            Spacer(minLength: 0)
                        }
                    )
                    .clipShape(Capsule())
                }
            }
            .frame(height: 8)

            Text(db <= Levels.floor ? "−∞" : String(format: "%.0f dB", db))
                .font(Font.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
