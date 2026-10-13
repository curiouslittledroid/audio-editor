import SwiftUI

/// Timeline geometry shared by the renderer and the hit-testing logic.
private struct WaveGeometry {
    let size: CGSize
    let inset: CGFloat = 12
    let rulerHeight: CGFloat = 24
    let bottomPadding: CGFloat = 12

    var canvasRect: CGRect { CGRect(origin: .zero, size: size) }

    var plotRect: CGRect {
        CGRect(x: inset,
               y: rulerHeight,
               width: max(1, size.width - inset * 2),
               height: max(1, size.height - rulerHeight - bottomPadding))
    }

    func x(forTime time: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return plotRect.minX }
        return plotRect.minX + CGFloat(time / duration) * plotRect.width
    }

    func time(forX x: CGFloat, duration: Double) -> Double {
        guard plotRect.width > 0, duration > 0 else { return 0 }
        return Double((x - plotRect.minX) / plotRect.width) * duration
    }
}

private enum WavePalette {
    static let background = Color(red: 0.075, green: 0.080, blue: 0.098)
    static let plotBackground = Color(red: 0.055, green: 0.059, blue: 0.075)
    static let waveform = Color(red: 0.36, green: 0.40, blue: 0.48)
    static let waveformSelected = Color(red: 0.36, green: 0.78, blue: 1.0)
    static let centerLine = Color.white.opacity(0.08)
    static let rulerText = Color.white.opacity(0.38)
    static let rulerTick = Color.white.opacity(0.14)
    static let excluded = Color.black.opacity(0.45)
    static let excludedEdge = Color(red: 1.0, green: 0.42, blue: 0.38).opacity(0.75)
    static let handle = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let playhead = Color.white
    static let label = Color.white.opacity(0.85)
}

struct WaveformView: View {
    let peaks: WaveformPeaks
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playhead: Double
    let isPlaying: Bool

    let onTrimStartChanged: (Double) -> Void
    let onTrimEndChanged: (Double) -> Void
    let onTrimCommitted: () -> Void
    let onSeek: (Double) -> Void

    private enum DragMode {
        case none, trimStart, trimEnd, seek
    }

    @State private var dragMode: DragMode = .none
    @State private var pointerLocation: CGPoint?

    private let hitTolerance: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let geometry = WaveGeometry(size: proxy.size)

            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, geometry: WaveGeometry(size: size))
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geometry: geometry))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    pointerLocation = point
                    updateCursor(for: point, geometry: geometry)
                case .ended:
                    pointerLocation = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }

    // MARK: - Interaction

    private func dragGesture(geometry: WaveGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == .none {
                    dragMode = mode(for: value.startLocation, geometry: geometry)
                }
                let time = max(0, min(duration, geometry.time(forX: value.location.x, duration: duration)))

                switch dragMode {
                case .trimStart: onTrimStartChanged(time)
                case .trimEnd: onTrimEndChanged(time)
                case .seek: onSeek(time)
                case .none: break
                }
            }
            .onEnded { _ in
                if dragMode != .seek { onTrimCommitted() }
                dragMode = .none
            }
    }

    private func mode(for point: CGPoint, geometry: WaveGeometry) -> DragMode {
        let startX = geometry.x(forTime: trimStart, duration: duration)
        let endX = geometry.x(forTime: trimEnd, duration: duration)

        let distanceToStart = abs(point.x - startX)
        let distanceToEnd = abs(point.x - endX)

        if distanceToStart <= hitTolerance, distanceToStart <= distanceToEnd {
            return .trimStart
        }
        if distanceToEnd <= hitTolerance {
            return .trimEnd
        }
        return .seek
    }

    private func updateCursor(for point: CGPoint, geometry: WaveGeometry) {
        let startX = geometry.x(forTime: trimStart, duration: duration)
        let endX = geometry.x(forTime: trimEnd, duration: duration)
        if abs(point.x - startX) <= hitTolerance || abs(point.x - endX) <= hitTolerance {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Rendering

    private func draw(in context: inout GraphicsContext, geometry: WaveGeometry) {
        let plot = geometry.plotRect
        let startX = geometry.x(forTime: trimStart, duration: duration)
        let endX = geometry.x(forTime: trimEnd, duration: duration)

        // Panel background and plot area.
        context.fill(Path(roundedRect: geometry.canvasRect, cornerRadius: 12),
                     with: .color(WavePalette.background))
        context.fill(Path(roundedRect: plot, cornerRadius: 6),
                     with: .color(WavePalette.plotBackground))

        drawRuler(in: &context, geometry: geometry)

        // Faint tint marking the region that will be kept.
        let keptRect = CGRect(x: startX, y: plot.minY, width: max(0, endX - startX), height: plot.height)
        if keptRect.width > 0 {
            context.fill(Path(roundedRect: keptRect, cornerRadius: 4),
                         with: .color(WavePalette.waveformSelected.opacity(0.07)))
        }

        drawCenterLine(in: &context, plot: plot)
        drawWaveform(in: &context, geometry: geometry, keptRect: keptRect)
        drawExcludedRegions(in: &context, geometry: geometry, startX: startX, endX: endX)
        drawSelectionLabels(in: &context, geometry: geometry, startX: startX, endX: endX)
        drawHandles(in: &context, geometry: geometry, startX: startX, endX: endX)
        drawPlayhead(in: &context, geometry: geometry)
    }

    private func drawRuler(in context: inout GraphicsContext, geometry: WaveGeometry) {
        let plot = geometry.plotRect
        let interval = Self.niceTickInterval(for: duration, width: plot.width)
        guard interval > 0, duration > 0 else { return }

        var time: Double = 0
        while time <= duration + 0.0001 {
            let x = geometry.x(forTime: time, duration: duration)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plot.minY - 5))
            tick.addLine(to: CGPoint(x: x, y: plot.minY))
            context.stroke(tick, with: .color(WavePalette.rulerTick), lineWidth: 1)

            context.draw(
                Text(TimeFormat.rulerLabel(time))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(WavePalette.rulerText),
                at: CGPoint(x: x, y: 7),
                anchor: .top
            )
            time += interval
        }

        // Baseline separating ruler from waveform.
        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.minY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        context.stroke(baseline, with: .color(WavePalette.rulerTick), lineWidth: 1)
    }

    private func drawCenterLine(in context: inout GraphicsContext, plot: CGRect) {
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: plot.midY))
        line.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        context.stroke(line, with: .color(WavePalette.centerLine), lineWidth: 1)
    }

    private func drawWaveform(in context: inout GraphicsContext, geometry: WaveGeometry, keptRect: CGRect) {
        let plot = geometry.plotRect
        let bucketCount = peaks.bucketCount
        guard bucketCount > 0, duration > 0 else {
            context.draw(
                Text("No waveform data")
                    .font(.system(size: 11))
                    .foregroundColor(WavePalette.rulerText),
                at: CGPoint(x: plot.midX, y: plot.midY)
            )
            return
        }

        let columnWidth: CGFloat = 1
        let columnCount = Int(plot.width / columnWidth)
        guard columnCount > 0 else { return }

        let amplitude = plot.height / 2 * 0.92
        let minimumBar: CGFloat = 1

        var path = Path()

        for column in 0..<columnCount {
            let x = plot.minX + CGFloat(column) * columnWidth
            let t0 = geometry.time(forX: x, duration: duration)
            let t1 = geometry.time(forX: x + columnWidth, duration: duration)

            var lower = Int((t0 / duration) * Double(bucketCount))
            var upper = Int((t1 / duration) * Double(bucketCount)) + 1
            lower = min(max(lower, 0), bucketCount - 1)
            upper = min(max(upper, lower + 1), bucketCount)

            var minimum: Float = .greatestFiniteMagnitude
            var maximum: Float = -.greatestFiniteMagnitude
            for bucket in lower..<upper {
                minimum = Swift.min(minimum, peaks.minima[bucket])
                maximum = Swift.max(maximum, peaks.maxima[bucket])
            }
            guard minimum <= maximum else { continue }

            let top = plot.midY - CGFloat(maximum) * amplitude
            let bottom = plot.midY - CGFloat(minimum) * amplitude
            let height = Swift.max(minimumBar, bottom - top)

            path.addRect(CGRect(x: x, y: top, width: columnWidth, height: height))
        }

        // Everything drawn in the muted colour, then the kept region repainted
        // brighter through a clip — one path built, two fills.
        context.fill(path, with: .color(WavePalette.waveform))

        if keptRect.width > 0.5 {
            context.drawLayer { layer in
                layer.clip(to: Path(keptRect))
                layer.fill(path, with: .color(WavePalette.waveformSelected))
            }
        }
    }

    private func drawExcludedRegions(in context: inout GraphicsContext, geometry: WaveGeometry, startX: CGFloat, endX: CGFloat) {
        let plot = geometry.plotRect

        func shade(from x0: CGFloat, to x1: CGFloat, edgeAt xEdge: CGFloat) {
            let width = x1 - x0
            guard width > 0.5 else { return }
            let rect = CGRect(x: x0, y: plot.minY, width: width, height: plot.height)
            context.fill(Path(rect), with: .color(WavePalette.excluded))

            var edge = Path()
            edge.move(to: CGPoint(x: xEdge, y: plot.minY))
            edge.addLine(to: CGPoint(x: xEdge, y: plot.maxY))
            context.stroke(edge, with: .color(WavePalette.excludedEdge), lineWidth: 1.5)
        }

        shade(from: plot.minX, to: startX, edgeAt: startX)
        shade(from: endX, to: plot.maxX, edgeAt: endX)
    }

    private func drawSelectionLabels(in context: inout GraphicsContext, geometry: WaveGeometry, startX: CGFloat, endX: CGFloat) {
        let plot = geometry.plotRect
        let selectionWidth = endX - startX
        guard selectionWidth > 4 else { return }

        let font = Font.system(size: 9.5, weight: .semibold, design: .monospaced)

        if selectionWidth > 150 {
            // Room for both handles: label each one inward of its handle.
            context.draw(
                Text(TimeFormat.timestamp(trimStart)).font(font).foregroundColor(WavePalette.handle),
                at: CGPoint(x: startX + 6, y: plot.maxY - 6),
                anchor: .bottomLeading
            )
            context.draw(
                Text(TimeFormat.timestamp(trimEnd)).font(font).foregroundColor(WavePalette.handle),
                at: CGPoint(x: endX - 6, y: plot.maxY - 6),
                anchor: .bottomTrailing
            )
        } else {
            context.draw(
                Text(TimeFormat.duration(trimEnd - trimStart)).font(font).foregroundColor(WavePalette.handle),
                at: CGPoint(x: plot.midX, y: plot.maxY - 6),
                anchor: .bottom
            )
        }
    }

    private func drawHandles(in context: inout GraphicsContext, geometry: WaveGeometry, startX: CGFloat, endX: CGFloat) {
        let plot = geometry.plotRect

        func handle(at x: CGFloat, active: Bool) {
            let barWidth: CGFloat = active ? 3.5 : 2.5
            let rect = CGRect(x: x - barWidth / 2, y: plot.minY, width: barWidth, height: plot.height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(WavePalette.handle))

            // Grip cap so the handle reads as draggable.
            let capWidth: CGFloat = 9
            let capHeight: CGFloat = 4
            let cap = CGRect(x: x - capWidth / 2,
                             y: plot.minY + 2,
                             width: capWidth,
                             height: capHeight)
            context.fill(Path(roundedRect: cap, cornerRadius: 2), with: .color(WavePalette.handle))
        }

        let hoveringStart = pointerLocation.map { abs($0.x - startX) <= hitTolerance } ?? false
        let hoveringEnd = pointerLocation.map { abs($0.x - endX) <= hitTolerance } ?? false

        handle(at: startX, active: dragMode == .trimStart || hoveringStart)
        handle(at: endX, active: dragMode == .trimEnd || hoveringEnd)
    }

    private func drawPlayhead(in context: inout GraphicsContext, geometry: WaveGeometry) {
        let plot = geometry.plotRect
        guard duration > 0 else { return }
        let x = geometry.x(forTime: playhead, duration: duration)
        guard x >= plot.minX - 1, x <= plot.maxX + 1 else { return }

        var line = Path()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        context.stroke(line,
                       with: .color(isPlaying ? WavePalette.playhead : WavePalette.playhead.opacity(0.55)),
                       lineWidth: 1.5)

        // Downward-pointing marker at the head of the line.
        var marker = Path()
        marker.move(to: CGPoint(x: x - 5, y: plot.minY))
        marker.addLine(to: CGPoint(x: x + 5, y: plot.minY))
        marker.addLine(to: CGPoint(x: x, y: plot.minY + 7))
        marker.closeSubpath()
        context.fill(marker, with: .color(WavePalette.playhead))
    }

    // MARK: - Ticks

    static func niceTickInterval(for duration: Double, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 1 }
        let targetTicks = max(2.0, Double(width / 95))
        let raw = duration / targetTicks
        let candidates: [Double] = [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30,
                                    60, 120, 300, 600, 900, 1800, 3600, 7200]
        for candidate in candidates where candidate >= raw {
            return candidate
        }
        return candidates.last ?? 1
    }
}
