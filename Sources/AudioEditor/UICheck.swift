import AppKit
import Foundation

/// Deterministic visual regression checks performed directly on the rendered
/// window bitmap. No vision model involved — every assertion is arithmetic on
/// pixels, so results are reproducible and can gate a change.
///
/// Deliberately geometry-independent: the waveform's own pixels are used to
/// discover where the plot area is, so the checks cannot silently pass when the
/// layout shifts.
struct UICheck {

    /// RGBA bitmap read straight out of the rendered window.
    struct Bitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let index = (y * width + x) * 4
            return (Double(pixels[index]) / 255.0,
                    Double(pixels[index + 1]) / 255.0,
                    Double(pixels[index + 2]) / 255.0)
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let (r, g, b) = rgb(x, y)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
    }

    /// Ink classifiers. These are relative to the palette rather than absolute,
    /// because the waveform is painted in three brightnesses — accent (kept),
    /// muted (trimmed away), and muted-then-dimmed (under the excluded-region
    /// overlay) — and all three have to be recognised.
    private enum Ink {
        /// Amber: trim handles and the In/Out readouts.
        static func isAmber(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            r > 0.72 && g > 0.42 && g < 0.90 && b < 0.55 && (r - b) > 0.35
        }
        /// Fully white: the playhead marker triangle, and chrome label text.
        static func isWhite(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            r > 0.85 && g > 0.85 && b > 0.85
        }
        /// Anything blue-shifted and brighter than the plot background. Covers
        /// accent, muted and dimmed-muted waveform alike; neutral chrome text and
        /// the grey idle playhead line are excluded.
        static func isWaveform(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.13
                && (b - r) > 0.03
                && Swift.min(r, g, b) < 0.50
                && !isAmber(r, g, b)
        }
        /// The waveform panel's dark blue-grey background (plot and surround).
        static func isPanelBackground(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return luminance > 0.02 && luminance < 0.115 && (b - r) > 0.008
        }
    }

    struct Spec {
        var loudRanges: [(Double, Double)] = []
        var quietRanges: [(Double, Double)] = []
        var checkTrimHandles = false
        var checkPlayhead = false
        var trimStart: Double = 0
        var trimEnd: Double = 0
        var playhead: Double = 0
        var duration: Double = 0
    }

    static func run(bitmap: Bitmap, spec: Spec, reporter: TestReporter) -> Int32 {
        reporter.section("rendered window \(bitmap.width)x\(bitmap.height)")

        // ---------------------------------------------------------------- plot
        var waveformInkPerRow = [Int](repeating: 0, count: bitmap.height)
        var waveformInkPerColumn = [Int](repeating: 0, count: bitmap.width)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isWaveform(r, g, b) {
                    waveformInkPerRow[y] += 1
                    waveformInkPerColumn[x] += 1
                }
            }
        }

        // -------------------------------------------------------------- handles
        // Detect the trim handles first, and independently of the plot band, so
        // they can never contaminate the waveform measurements. A handle is the
        // only element with a very long contiguous amber run; the amber In/Out
        // readouts in the transport bar are only a few pixels tall.
        var longestAmberRun = [Int](repeating: 0, count: bitmap.width)
        for x in 0..<bitmap.width {
            var run = 0
            for y in 0..<bitmap.height {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isAmber(r, g, b) {
                    run += 1
                    longestAmberRun[x] = max(longestAmberRun[x], run)
                } else {
                    run = 0
                }
            }
        }
        let handleColumns = (0..<bitmap.width).filter { longestAmberRun[$0] > bitmap.height / 5 }
        let handleCentres = cluster(handleColumns)

        // Handle bars span the whole plot rect, which is taller than the waveform
        // envelope, so they reach into the regions above and below the plot. They
        // must be excluded when measuring chrome ink in those regions.
        var excludedColumns = Set<Int>()
        for centre in handleCentres {
            for offset in -9...9 where centre + offset >= 0 && centre + offset < bitmap.width {
                excludedColumns.insert(centre + offset)
            }
        }

        // The playhead is a light, full-height column. Left alone it would read as
        // a full-height waveform bar and inflate the measured envelope, so locate
        // it up front — via its opaque white marker — and keep its columns out of
        // the waveform measurements. The same result is reused by the assertion
        // further down.
        let playheadX = playheadColumn(bitmap: bitmap)
        if let playheadX {
            for offset in -4...4 where playheadX + offset >= 0 && playheadX + offset < bitmap.width {
                excludedColumns.insert(playheadX + offset)
            }
        }

        // The waveform is drawn symmetric about the plot's vertical centre, and
        // every column is guaranteed at least a hairline there, so the row
        // carrying the most ink is that centre. Anchoring on it matters: measuring
        // a column's full ink extent instead would be inflated by the horizontal
        // ruler baseline near the top of the plot.
        guard let midY = (0..<bitmap.height).max(by: {
                  waveformInkPerRow[$0] < waveformInkPerRow[$1]
              }),
              waveformInkPerRow[midY] > 0 else {
            reporter.check("waveform midline found", false, "no row carries waveform ink")
            return reporter.finish()
        }

        func isInk(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = bitmap.rgb(x, y)
            return Ink.isWaveform(r, g, b)
        }

        // ------------------------------------------------------------ amplitude
        // Walk outwards from the midline while ink continues, giving the true bar
        // height for the column. Loud audio is tall; silence collapses to the
        // hairline.
        var profile = [Double](repeating: 0, count: bitmap.width)
        var barTop = [Int](repeating: -1, count: bitmap.width)
        var barBottom = [Int](repeating: -1, count: bitmap.width)
        for x in 0..<bitmap.width {
            // Handles are opaque amber at the midline and the playhead is a light
            // full-height line, so both drop out here.
            guard !excludedColumns.contains(x), isInk(x, midY) else { continue }
            var top = midY
            var bottom = midY
            while top > 0, isInk(x, top - 1) { top -= 1 }
            while bottom < bitmap.height - 1, isInk(x, bottom + 1) { bottom += 1 }
            barTop[x] = top
            barBottom[x] = bottom
            profile[x] = Double(bottom - top + 1)
        }

        let activeColumns = (0..<bitmap.width).filter { profile[$0] > 0 }
        guard let plotLeft = activeColumns.first, let plotRight = activeColumns.last,
              plotRight - plotLeft > 40 else {
            reporter.check("plot width detected", false, "waveform ink too narrow")
            return reporter.finish()
        }
        let plotWidth = Double(plotRight - plotLeft + 1)
        let plotTop = activeColumns.compactMap { barTop[$0] >= 0 ? barTop[$0] : nil }.min() ?? midY
        let plotBottom = activeColumns.compactMap { barBottom[$0] >= 0 ? barBottom[$0] : nil }.max() ?? midY
        let plotHeight = Double(plotBottom - plotTop + 1)

        reporter.check("plot area detected", true,
                       "rows \(plotTop)…\(plotBottom), height \(Int(plotHeight)), midline \(midY)")
        reporter.check("plot width detected", true,
                       "columns \(plotLeft)…\(plotRight), width \(Int(plotWidth))")

        func time(atColumn x: Int) -> Double {
            Double(Double(x - plotLeft) / plotWidth) * spec.duration
        }
        func column(atTime t: Double) -> Int {
            plotLeft + Int((t / max(spec.duration, 0.0001)) * plotWidth)
        }

        func medianProfile(_ range: (Double, Double)) -> Double {
            let lo = column(atTime: range.0)
            let hi = column(atTime: range.1)
            guard hi > lo else { return 0 }
            let slice = profile[lo...hi].sorted()
            return slice[slice.count / 2]
        }

        for (index, range) in spec.loudRanges.enumerated() {
            let fraction = medianProfile(range) / plotHeight
            reporter.check("loud region \(index + 1) drawn (\(spot(range)))",
                           fraction > 0.20,
                           "waveform fills \(Int(fraction * 100))% of plot height")
        }
        for (index, range) in spec.quietRanges.enumerated() {
            let fraction = medianProfile(range) / plotHeight
            reporter.check("quiet region \(index + 1) flat (\(spot(range)))",
                           fraction < 0.10,
                           "waveform fills \(Int(fraction * 100))% of plot height")
        }

        if spec.checkTrimHandles {
            reporter.check("two trim handles rendered", handleCentres.count == 2,
                           "found \(handleCentres.count) full-height amber bars")
            if handleCentres.count == 2 {
                let tolerance = max(0.03, spec.duration * 0.02)
                let renderedStart = time(atColumn: handleCentres[0])
                let renderedEnd = time(atColumn: handleCentres[1])
                reporter.check("in-point handle at \(spot(spec.trimStart))",
                               abs(renderedStart - spec.trimStart) < tolerance,
                               "rendered at \(spot(renderedStart))")
                reporter.check("out-point handle at \(spot(spec.trimEnd))",
                               abs(renderedEnd - spec.trimEnd) < tolerance,
                               "rendered at \(spot(renderedEnd))")
            }
        }

        // ------------------------------------------------------------- playhead
        // The idle playhead line is only 55% white, so it cannot be found by
        // colour alone. Its marker triangle, however, is fully opaque white and is
        // the only such element inside the waveform panel — so locate the panel,
        // then find the one white cluster within it.
        if spec.checkPlayhead {
            if let centre = playheadX {
                let rendered = time(atColumn: centre)
                let tolerance = max(0.03, spec.duration * 0.02)
                reporter.check("playhead at \(spot(spec.playhead))",
                               abs(rendered - spec.playhead) < tolerance,
                               "marker rendered at \(spot(rendered))")
            } else {
                reporter.check("playhead marker rendered", false,
                               "no fully-white cluster found inside the waveform panel")
            }
        }

        // ------------------------------------------------------------ orientation
        // The transport bar below the plot carries the amber In/Out readouts; the
        // header above it has no amber. A vertically mirrored capture swaps them,
        // so comparing amber ink either side of the plot detects a flip without
        // depending on reading text or on the window being key.
        func count(_ predicate: (Double, Double, Double) -> Bool, rows: Range<Int>) -> Int {
            guard rows.lowerBound >= 0, rows.upperBound <= bitmap.height else { return 0 }
            var total = 0
            for y in rows {
                for x in 0..<bitmap.width where !excludedColumns.contains(x) {
                    let (r, g, b) = bitmap.rgb(x, y)
                    if predicate(r, g, b) { total += 1 }
                }
            }
            return total
        }
        func litFraction(rows: Range<Int>) -> Double {
            guard rows.lowerBound >= 0, rows.upperBound <= bitmap.height,
                  !rows.isEmpty else { return 0 }
            var lit = 0
            var total = 0
            for y in rows {
                for x in 0..<bitmap.width {
                    total += 1
                    if bitmap.luminance(x, y) > 0.35 { lit += 1 }
                }
            }
            return total == 0 ? 0 : Double(lit) / Double(total)
        }

        let abovePlot = 0..<max(0, plotTop)
        let belowPlot = min(bitmap.height, plotBottom + 1)..<bitmap.height

        let amberAbove = count(Ink.isAmber, rows: abovePlot)
        let amberBelow = count(Ink.isAmber, rows: belowPlot)
        reporter.check("image is not vertically mirrored",
                       amberBelow > 500 && amberBelow > amberAbove * 2,
                       "amber ink above plot=\(amberAbove), below plot=\(amberBelow)")

        // ---------------------------------------------------------------- chrome
        let headerFraction = litFraction(rows: abovePlot)
        let transportFraction = litFraction(rows: belowPlot)
        reporter.check("header bar has content", headerFraction > 0.005,
                       "\(Int(headerFraction * 100))% lit pixels above the plot")
        reporter.check("transport bar has content", transportFraction > 0.005,
                       "\(Int(transportFraction * 100))% lit pixels below the plot")

        return reporter.finish()
    }

    /// Finds the playhead by locating the waveform panel and then the single
    /// fully-white cluster (the playhead marker triangle) inside it.
    private static func playheadColumn(bitmap: Bitmap) -> Int? {
        var panelRows: [Int] = []
        for y in 0..<bitmap.height {
            var panelPixels = 0
            for x in stride(from: 0, to: bitmap.width, by: 2) {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isPanelBackground(r, g, b) { panelPixels += 1 }
            }
            if panelPixels > bitmap.width / 20 { panelRows.append(y) }
        }
        guard let panelTop = panelRows.first, let panelBottom = panelRows.last,
              panelBottom > panelTop else { return nil }

        var whitePerColumn = [Int](repeating: 0, count: bitmap.width)
        for y in panelTop...panelBottom {
            for x in 0..<bitmap.width {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isWhite(r, g, b) { whitePerColumn[x] += 1 }
            }
        }

        let columns = whitePerColumn.enumerated().filter { $0.element > 0 }.map(\.offset)
        guard !columns.isEmpty else { return nil }

        // Group into clusters and keep the one with the most white pixels: the
        // marker triangle is far denser than any antialiasing speckle.
        var groups: [[Int]] = [[columns[0]]]
        for x in columns.dropFirst() {
            if x - groups[groups.count - 1].last! <= 4 {
                groups[groups.count - 1].append(x)
            } else {
                groups.append([x])
            }
        }
        let best = groups.max { lhs, rhs in
            lhs.reduce(0) { $0 + whitePerColumn[$1] } < rhs.reduce(0) { $0 + whitePerColumn[$1] }
        }
        guard let best, !best.isEmpty else { return nil }
        return best.reduce(0, +) / best.count
    }

    /// Groups adjacent columns into cluster centres.
    private static func cluster(_ columns: [Int], gap: Int = 3, minimumWidth: Int = 2) -> [Int] {
        guard !columns.isEmpty else { return [] }
        var groups: [[Int]] = [[columns[0]]]
        for x in columns.dropFirst() {
            if x - groups[groups.count - 1].last! <= gap {
                groups[groups.count - 1].append(x)
            } else {
                groups.append([x])
            }
        }
        return groups.filter { $0.count >= minimumWidth }
            .map { $0.reduce(0, +) / $0.count }
    }

    private static func spot(_ t: Double) -> String {
        String(format: "%.3fs", t)
    }

    private static func spot(_ range: (Double, Double)) -> String {
        String(format: "%.3f–%.3fs", range.0, range.1)
    }
}