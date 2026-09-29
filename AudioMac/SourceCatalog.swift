import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
}

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let label: String
    let pixelWidth: Int
    let pixelHeight: Int
}

enum CaptureTarget {
    case display(DisplayInfo)
    case window(WindowInfo)

    /// Video size (even, as the encoders require).
    var videoSize: (width: Int, height: Int) {
        switch self {
        case .display(let d): return (d.pixelWidth & ~1, d.pixelHeight & ~1)
        case .window(let w): return (w.pixelWidth & ~1, w.pixelHeight & ~1)
        }
    }
}

/// Display and window lists via CoreGraphics: works on every supported macOS version.
enum SourceCatalog {
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let scale = screen.backingScaleFactor
            return DisplayInfo(id: id,
                               name: screen.localizedName,
                               pixelWidth: Int(screen.frame.width * scale),
                               pixelHeight: Int(screen.frame.height * scale))
        }
    }

    static func windows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        return list.compactMap { info -> WindowInfo? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 80,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }

            let app = info[kCGWindowOwnerName as String] as? String ?? "?"
            let title = info[kCGWindowName as String] as? String ?? ""
            return WindowInfo(id: number,
                              label: title.isEmpty ? app : "\(app) — \(title)",
                              pixelWidth: Int(bounds.width * scale),
                              pixelHeight: Int(bounds.height * scale))
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func windowExists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return !list.isEmpty
    }
}
