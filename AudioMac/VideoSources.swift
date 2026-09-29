import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Sorgente di fotogrammi: consegna i pixel buffer a `engine.appendVideo` sulla coda del motore.
protocol VideoSource: AnyObject {
    /// Chiamato su una coda qualsiasi se la cattura si interrompe da sola (es. finestra chiusa).
    var onError: ((Error) -> Void)? { get set }
    func start(engine: CaptureEngine) async throws
    func stop() async
}

func makeVideoSource(target: CaptureTarget, fps: Int, legacy: Bool) -> VideoSource {
    if !legacy, #available(macOS 12.3, *) {
        return SCKVideoSource(target: target, fps: fps)
    }
    switch target {
    case .display(let display):
        return DisplayStreamSource(display: display, fps: fps)
    case .window(let window):
        return WindowSnapshotSource(window: window, fps: fps)
    }
}

// MARK: - macOS 12.3+: ScreenCaptureKit

@available(macOS 12.3, *)
final class SCKVideoSource: NSObject, VideoSource, SCStreamOutput, SCStreamDelegate {
    var onError: ((Error) -> Void)?
    private let target: CaptureTarget
    private let fps: Int
    private var stream: SCStream?
    private var engine: CaptureEngine?

    init(target: CaptureTarget, fps: Int) {
        self.target = target
        self.fps = fps
    }

    func start(engine: CaptureEngine) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let filter: SCContentFilter
        switch target {
        case .display(let info):
            guard let display = content.displays.first(where: { $0.displayID == info.id }) else { throw CaptureError.targetGone }
            // La finestra di AudioMac non compare nel video.
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .window(let info):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else { throw CaptureError.targetGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let size = target.videoSize
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: engine.queue)
        self.engine = engine
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        engine?.appendVideo(pixelBuffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

// MARK: - macOS 11–12.2: schermo intero con CGDisplayStream

final class DisplayStreamSource: VideoSource {
    var onError: ((Error) -> Void)?
    private let display: DisplayInfo
    private let fps: Int
    private var stream: CGDisplayStream?
    private var pool: CVPixelBufferPool?

    init(display: DisplayInfo, fps: Int) {
        self.display = display
        self.fps = fps
    }

    func start(engine: CaptureEngine) async throws {
        let size = CaptureTarget.display(display).videoSize
        pool = makePixelBufferPool(width: size.width, height: size.height)

        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1.0 / Double(fps),
            CGDisplayStream.showCursor: true,
        ]
        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: display.id,
            outputWidth: size.width,
            outputHeight: size.height,
            pixelFormat: Int32(bitPattern: kCVPixelFormatType_32BGRA),
            properties: properties as CFDictionary,
            queue: engine.queue,
            handler: { [weak self, weak engine] status, displayTime, surface, _ in
                guard status == .frameComplete, let surface, let self, let engine,
                      let pixelBuffer = self.copy(surface) else { return }
                engine.appendVideo(pixelBuffer, at: CMClockMakeHostTimeFromSystemUnits(displayTime))
            }),
            stream.start() == .success else { throw CaptureError.videoStart }
        self.stream = stream
    }

    func stop() async {
        stream?.stop()
        stream = nil
    }

    /// Le IOSurface di CGDisplayStream vengono riutilizzate: copia il fotogramma in un buffer nostro
    /// prima di passarlo all'encoder.
    private func copy(_ surface: IOSurfaceRef) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        IOSurfaceLock(surface, .readOnly, nil)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        guard let destination = CVPixelBufferGetBaseAddress(out) else { return nil }
        let source = IOSurfaceGetBaseAddress(surface)
        let sourceStride = IOSurfaceGetBytesPerRow(surface)
        let destinationStride = CVPixelBufferGetBytesPerRow(out)
        let rows = min(IOSurfaceGetHeight(surface), CVPixelBufferGetHeight(out))
        let rowBytes = min(sourceStride, destinationStride)
        for row in 0..<rows {
            memcpy(destination + row * destinationStride, source + row * sourceStride, rowBytes)
        }
        return out
    }
}

// MARK: - macOS 11–12.2: singola finestra con istantanee periodiche

/// CGWindowListCreateImage non è più disponibile negli SDK recenti: viene risolta a runtime
/// (esiste su tutte le versioni di macOS e si usa solo dove ScreenCaptureKit manca).
private typealias CreateWindowImage = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
private let createWindowImage: CreateWindowImage? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil } // RTLD_DEFAULT
    return unsafeBitCast(symbol, to: CreateWindowImage.self)
}()

final class WindowSnapshotSource: VideoSource {
    var onError: ((Error) -> Void)?
    private let window: WindowInfo
    private let fps: Int
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var ticks = 0

    init(window: WindowInfo, fps: Int) {
        self.window = window
        self.fps = fps
    }

    func start(engine: CaptureEngine) async throws {
        guard createWindowImage != nil, SourceCatalog.windowExists(window.id) else { throw CaptureError.targetGone }
        let size = CaptureTarget.window(window).videoSize
        pool = makePixelBufferPool(width: size.width, height: size.height)

        let timer = DispatchSource.makeTimerSource(queue: engine.queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.captureFrame(into: engine, width: size.width, height: size.height)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() async {
        timer?.cancel()
        timer = nil
    }

    private func captureFrame(into engine: CaptureEngine, width: Int, height: Int) {
        ticks += 1
        // Circa una volta al secondo controlla che la finestra esista ancora.
        if ticks % fps == 0, !SourceCatalog.windowExists(window.id) {
            timer?.cancel()
            timer = nil
            onError?(CaptureError.targetGone)
            return
        }

        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        guard let createWindowImage,
              let image = createWindowImage(.null, CGWindowListOption.optionIncludingWindow.rawValue, window.id, options)?
                .takeRetainedValue(),
              let pool else { return }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pixelBuffer = out else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }

        // Sfondo nero e immagine adattata mantenendo le proporzioni (la finestra può essere ridimensionata).
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawSize.width) / 2,
                                       y: (CGFloat(height) - drawSize.height) / 2,
                                       width: drawSize.width, height: drawSize.height))

        engine.appendVideo(pixelBuffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

private func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    return pool
}
