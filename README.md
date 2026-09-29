<p align="center">
  <img src="icon/AppIcon-1024.png" width="160" alt="AudioMac icon">
</p>

<h1 align="center">AudioMac</h1>

<p align="center">
  Record your Mac's screen <b>with internal audio</b> and your microphone.<br>
  The thing ⌘⇧5 can't do.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-11%20Big%20Sur%2B-black?logo=apple" alt="macOS 11+">
  <img src="https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white" alt="Swift 5">
  <img src="https://img.shields.io/badge/Intel%20%2B%20Apple%20Silicon-universal-555" alt="Universal">
  <img src="https://img.shields.io/badge/license-Unlicense%20(public%20domain)-blue" alt="Unlicense">
</p>

---

## Why

macOS's built-in recorder (⌘⇧5, QuickTime) records the screen with your **microphone**, but not with the sound
your Mac is playing: videos, calls, music, games. Getting that usually means installing a virtual audio driver and
setting up a Multi-Output Device by hand.

AudioMac does it for you, in a minimal app:

- 🖥️ **Full screen or a single window**
- 🔊 **Mac audio** and 🎙️ **microphone**, on two separate tracks in the same file
- 🔇 **Live mute** for each source, even while recording, without losing sync
- 📊 **Audio level meters** for both inputs, always visible, even before you start recording
- 🎞️ **H.264 or HEVC**, 30 or 60 fps, `.mov` files saved to `~/Movies`
- ⌨️ **⇧⌘R** to start/stop

## Compatibility

AudioMac runs on **macOS 11 Big Sur** and later, and picks the best capture method for the system it's running on:

| macOS | Video | Mac audio | Microphone |
|---|---|---|---|
| **13 Ventura and later** | ScreenCaptureKit | ScreenCaptureKit, no driver | AVFoundation |
| **12.3 – 12.x Monterey** | ScreenCaptureKit | AudioMac Loopback driver | AVFoundation |
| **11 Big Sur – 12.2** | CGDisplayStream / window snapshots | AudioMac Loopback driver | AVFoundation |

From macOS 13 on there is nothing to install. Earlier versions of macOS have no API to capture system audio, so
AudioMac ships with a small virtual audio driver.

## Installation

1. Build the app (see below) or download a build.
2. Open **AudioMac** and grant the requested permissions in *System Settings → Privacy & Security*:
   - **Screen Recording** (on macOS 15: *Screen & System Audio Recording*)
   - **Microphone**
3. Reopen the app after granting Screen Recording.

> The app is ad-hoc signed: the first time, right-click it → **Open**. After every rebuild macOS may ask for the
> Screen Recording permission again.

### On macOS 11 and 12: the AudioMac Loopback driver

The *Audio* section shows an **Install Audio Driver…** button. It copies the driver to
`/Library/Audio/Plug-Ins/HAL` (administrator password required) and restarts the audio service.

While AudioMac is open, sound is routed through a Multi-Output Device called
**"AudioMac (Speakers + Recording)"**: you keep hearing everything as usual, and the driver receives a copy of the
audio to record. When you quit the app, your previous output is restored. In the meantime the volume keys don't
work: that's a limitation of macOS Multi-Output Devices.

Remove the driver with the **Uninstall Driver** button in the app, or by hand:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/AudioMacLoopback.driver && sudo killall coreaudiod
```

## Building

Requires Xcode (tested with Xcode 26). The build is universal (Intel + Apple Silicon) with a macOS 11 deployment target.

```bash
./build.sh
```

The app ends up in `build/Release/AudioMac.app`. Alternatively, open `AudioMac.xcodeproj` and press ⌘R.

To try the Big Sur/Monterey code path (driver + older video APIs) on a recent Mac:

```bash
defaults write com.rikdev.audiomac ForceLegacyCapture -bool YES   # enable
defaults delete com.rikdev.audiomac ForceLegacyCapture            # back to normal
```

## How it works

```
            ┌────────────── Video ───────────────┐
 screen ───►│ ScreenCaptureKit / CGDisplayStream │──┐
            └────────────────────────────────────┘  │     ┌───────────────┐
            ┌──────────── Mac audio ─────────────┐  ├────►│ AVAssetWriter │──► .mov
 system ───►│ ScreenCaptureKit / loopback driver │──┤     │ 1 video       │    (H.264/HEVC,
            └────────────────────────────────────┘  │     │ 2 AAC audio   │     2 AAC tracks)
            ┌──────────── Microphone ────────────┐  │     └───────────────┘
 mic ──────►│ AVCaptureSession                   │──┘
            └────────────────────────────────────┘
```

- Every source delivers samples on a single queue, timestamped on the host clock, so video and audio tracks stay
  in sync.
- **Mute** replaces samples with silence instead of cutting the track; gaps in the audio stream (e.g. nothing is
  playing) are filled with silence too.
- In *single window* mode the recorded audio is still **the whole Mac's** (on its own, ScreenCaptureKit would only
  capture the app that owns the window).
- AudioMac's own window is excluded from the video in *full screen* mode (macOS 12.3+).

## Project structure

```
AudioMac/                 App (SwiftUI, macOS 11+)
├── AudioMacApp.swift     Entry point, commands, clean shutdown
├── ContentView.swift     UI: video source, audio channels with meters and mute
├── Recorder.swift        App state and capture method selection per macOS version
├── CaptureEngine.swift   File writing, levels, mute, silence filling
├── VideoSources.swift    ScreenCaptureKit, CGDisplayStream, window snapshots
├── AudioSources.swift    System audio (ScreenCaptureKit / loopback) and microphone
├── LoopbackDriver.swift  Driver installation and Multi-Output routing
└── SourceCatalog.swift   Display and window lists
AudioMacDriver/           "AudioMac Loopback" AudioServerPlugIn driver (C)
icon/                     Icon source (Affinity) and exports (the app uses AudioMac/Assets.xcassets)
```

## Known limitations

- On macOS 11–12.2, in *full screen* mode AudioMac's window shows up in the video, and *single window* mode uses
  periodic snapshots (more CPU).
- The driver supports 44.1 and 48 kHz: if your Mac's audio output runs at a different sample rate, the
  Multi-Output Device may not work.
- Mac audio and microphone are on two separate tracks: QuickTime and video editors read both.

## License

Public domain ([The Unlicense](LICENSE)): you may use, copy, modify, distribute and sell AudioMac, including in
commercial and closed-source projects, without asking for permission and without having to credit anyone.
