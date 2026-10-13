import AppKit
import Foundation

func aeLog(_ message: String) {
    FileHandle.standardError.write(Data("[ae] \(message)\n".utf8))
}

/// Headless-ish verification helper: loads a file, waits for the waveform to be
/// analysed, renders the real window content to a PNG, then exits.
///
/// Used by `tools/capture.sh` so the UI can be inspected without needing Screen
/// Recording permission (the app captures its own window).
///
///   AudioEditor --snapshot out.png --file x.wav [--trim 1.0 4.0]
///               [--playhead 2.0] [--loop] [--size 1000 580]
///               [--banner error|info <text>] [--settle 1.0]
struct SnapshotOptions {
    var outputPath: String
    var filePath: String?
    var trimStart: Double?
    var trimEnd: Double?
    var playhead: Double?
    var loop = false
    var size = CGSize(width: 1000, height: 580)
    var banner: (kind: String, text: String)?
    var settle: Double = 1.0

    // --uicheck spec
    var runUICheck = false
    var loudRanges: [(Double, Double)] = []
    var quietRanges: [(Double, Double)] = []

    /// Configuration arrives through the environment, never through argv.
    ///
    /// AppKit parses `-flag value` pairs out of the argument list and treats any
    /// leftover token as "open this document", which puts the process into a
    /// launch mode where SwiftUI's `WindowGroup` never creates a window — so
    /// `onAppear` (and therefore this whole harness) would never run. The
    /// environment is not touched by that machinery, so it is always safe.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> SnapshotOptions? {
        guard let output = env["AUDIOEDIT_SNAPSHOT"], !output.isEmpty else { return nil }

        var options = SnapshotOptions(outputPath: output)
        options.filePath = env["AUDIOEDIT_FILE"]

        if let raw = env["AUDIOEDIT_TRIM"] {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                options.trimStart = parts[0]
                options.trimEnd = parts[1]
            }
        }
        if let raw = env["AUDIOEDIT_PLAYHEAD"], let value = Double(raw) { options.playhead = value }
        if let raw = env["AUDIOEDIT_SETTLE"], let value = Double(raw) { options.settle = value }
        if let raw = env["AUDIOEDIT_LOUD"] { options.loudRanges = parseRanges(raw) }
        if let raw = env["AUDIOEDIT_QUIET"] { options.quietRanges = parseRanges(raw) }
        if let raw = env["AUDIOEDIT_BANNER"] {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { options.banner = (parts[0], parts[1]) }
        }
        if let raw = env["AUDIOEDIT_SIZE"] {
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { options.size = CGSize(width: parts[0], height: parts[1]) }
        }

        options.loop = env["AUDIOEDIT_LOOP"] == "1"
        options.runUICheck = env["AUDIOEDIT_UICHECK"] == "1"
        return options
    }

}

@MainActor
final class SnapshotController {
    private let options: SnapshotOptions
    private var model: AudioDocumentModel?
    private var deadline: Date?

    init(options: SnapshotOptions) {
        self.options = options
    }

    func attach(model: AudioDocumentModel) {
        aeLog("SnapshotController.attach file=\(options.filePath ?? "nil") check=\(options.runUICheck)")
        self.model = model

        if let window = NSApp.windows.first {
            window.setContentSize(options.size)
            window.center()
        }

        if let path = options.filePath {
            model.load(url: URL(fileURLWithPath: path))
        }
        if let start = options.trimStart { model.setTrimStart(start) }
        if let end = options.trimEnd { model.setTrimEnd(end) }
        if let playhead = options.playhead { model.playhead = playhead }
        if options.loop { model.setLooping(true) }

        if let banner = options.banner {
            if banner.kind == "error" { model.errorMessage = banner.text }
            else { model.infoMessage = banner.text }
        }

        deadline = Date().addingTimeInterval(12)
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.tick(timer: timer)
            }
        }
    }

    private func tick(timer: Timer) {
        guard let model else { timer.invalidate(); return }

        let analysing = model.isAnalyzing
        let timedOut = deadline.map { Date() > $0 } ?? false
        guard (!analysing && model.hasFile) || timedOut || !model.hasFile else { return }

        timer.invalidate()
        // Give SwiftUI a beat to lay out with the final data before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + options.settle) { [weak self] in
            self?.captureAndExit()
        }
    }

    private func captureAndExit() {
        aeLog("captureAndExit windows=\(NSApp.windows.count)")
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
              let view = window.contentView else {
            FileHandle.standardError.write(Data("snapshot: no window available\n".utf8))
            exit(2)
        }

        // Bring the window forward so it renders as a key window: macOS greys out
        // prominent buttons and tint colours in inactive windows, which would make
        // the snapshot unrepresentative of what the user actually sees.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()

        // Render the whole window frame when available, so the title bar is
        // included and the picture matches the real app.
        let target = view.superview ?? view
        target.layoutSubtreeIfNeeded()
        let image = Self.render(view: target, window: window)
        guard let image,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(3)
        }

        do {
            try data.write(to: URL(fileURLWithPath: options.outputPath))
            print("snapshot: wrote \(options.outputPath) (\(image.width)x\(image.height))")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            exit(4)
        }

        guard options.runUICheck else { exit(0) }

        guard let bitmap = Self.rgbaBitmap(from: image) else {
            FileHandle.standardError.write(Data("uicheck: could not read pixels\n".utf8))
            exit(5)
        }
        var spec = UICheck.Spec()
        spec.loudRanges = options.loudRanges
        spec.quietRanges = options.quietRanges
        spec.checkTrimHandles = options.trimStart != nil
        spec.checkPlayhead = options.playhead != nil
        spec.trimStart = options.trimStart ?? 0
        spec.trimEnd = options.trimEnd ?? 0
        spec.playhead = options.playhead ?? 0
        spec.duration = model?.duration ?? 0

        exit(UICheck.run(bitmap: bitmap, spec: spec, reporter: TestReporter()))
    }

    /// Re-reads a rendered `CGImage` into tightly packed RGBA bytes.
    private static func rgbaBitmap(from image: CGImage) -> UICheck.Bitmap? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return UICheck.Bitmap(width: width, height: height, pixels: pixels)
    }

    /// Captures the layer tree directly, which works for SwiftUI's layer-backed
    /// views without Screen Recording permission.
    private static func render(view: NSView, window: NSWindow) -> CGImage? {
        let scale = window.backingScaleFactor
        let width = Int((view.bounds.width * scale).rounded())
        let height = Int((view.bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }

        // Paint an opaque base first: the layer tree leaves window chrome
        // uncovered, and a transparent capture reads back as pure black.
        context.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: view.bounds.width, height: view.bounds.height))

        // AppKit views can be flipped (top-left origin, like SwiftUI's hosting
        // view) or not (bottom-left, like the window's theme frame), while a
        // CGContext is always bottom-left origin. Only compensate when needed,
        // otherwise the capture comes out vertically mirrored.
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        view.layer?.render(in: context)
        return context.makeImage()
    }
}
