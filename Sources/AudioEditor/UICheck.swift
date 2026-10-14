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
                && !isFade(r, g, b)
        }
        /// Magenta: the fade envelope. Its own family on purpose — the palette
        /// colour is picked to fall outside both `isWaveform` and `isAmber`, so
        /// an envelope can never be miscounted as audio or as a trim handle.
        ///
        /// The `r > 0.80 && b < r - 0.10` bounds are what separate it from the
        /// blue-purple macOS accent colour (measured at 0.65, 0.31, 0.65, which
        /// otherwise matches). The accent is user-configurable, so the envelope
        /// must never be identified by a test that an accent could satisfy.
        /// The `!isFade` guard in `isWaveform` is belt-and-braces against a
        /// future palette change quietly reintroducing that confusion.
        static func isFade(_ r: Double, _ g: Double, _ b: Double) -> Bool {
            r > 0.80 && b > 0.30 && b < r - 0.10 && g < r - 0.15 && g < b - 0.05
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
        var checkFades = false
        var fadeIn: Double = 0
        var fadeOut: Double = 0
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

        // -------------------------------------------------------- fade envelope
        // Confined to the waveform panel on purpose. The transport bar carries
        // magenta fade-field text and the header carries accent-coloured chrome,
        // so an unbounded search would find both and mistake them for an
        // envelope.
        if spec.checkFades, spec.fadeIn > 0 || spec.fadeOut > 0,
           let band = panelBand(bitmap: bitmap) {

            // Per column, how far the envelope ink reaches from the centre line.
            // The stroked edges sit at gain × full amplitude, so this offset is
            // the drawn gain.
            var envelopeOffset = [Int](repeating: -1, count: bitmap.width)
            for x in 0..<bitmap.width {
                for y in band.top...band.bottom {
                    let (r, g, b) = bitmap.rgb(x, y)
                    if Ink.isFade(r, g, b) {
                        envelopeOffset[x] = max(envelopeOffset[x], abs(y - midY))
                    }
                }
            }
            let envelopeColumns = (0..<bitmap.width).filter { envelopeOffset[$0] >= 0 }
            reporter.check("fade envelope rendered", !envelopeColumns.isEmpty,
                           "no envelope ink inside the waveform panel")

            func offsetNear(_ target: Int) -> Int? {
                let values = ((target - 2)...(target + 2))
                    .filter { $0 >= 0 && $0 < bitmap.width }
                    .compactMap { envelopeOffset[$0] >= 0 ? envelopeOffset[$0] : nil }
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / values.count
            }

            let tolerance = max(6, Int(Double(bitmap.width) * 0.008))

            // Both fades are drawn from the same ink, so each check has to accept
            // the other's region as legitimate — otherwise the fade-in check
            // reports the fade-out's columns as strays, and vice versa.
            func region(start: Double, fade: Double) -> ClosedRange<Int>? {
                guard fade > 0 else { return nil }
                return (column(atTime: start) - tolerance)...(column(atTime: start + fade) + tolerance)
            }
            let fadeInRegion = region(start: spec.trimStart, fade: spec.fadeIn)
            let fadeOutRegion = region(start: spec.trimEnd - spec.fadeOut, fade: spec.fadeOut)
            let knownRegions = [fadeInRegion, fadeOutRegion].compactMap { $0 }

            func checkFade(_ label: String, start: Double, fade: Double, rising: Bool,
                           own: ClosedRange<Int>?) {
                guard fade > 0, let own else { return }
                let inside = envelopeColumns.filter { own.contains($0) }
                let outside = envelopeColumns.filter { column in
                    !knownRegions.contains { $0.contains(column) }
                }

                reporter.check("fade-\(label) envelope spans \(spot(start))–\(spot(start + fade))",
                               inside.count >= max(4, own.count / 2),
                               "\(inside.count) envelope columns in \(own.lowerBound + tolerance)…\(own.upperBound - tolerance)")
                // Nothing in an unexpected place proves the envelope marks the
                // right region rather than merely existing somewhere.
                reporter.check("fade-\(label) envelope confined to its region",
                               outside.isEmpty,
                               "\(outside.count) envelope columns outside both fades")

                let peak = inside.compactMap { envelopeOffset[$0] >= 0 ? envelopeOffset[$0] : nil }.max() ?? 0
                guard peak > 4 else {
                    reporter.check("fade-\(label) envelope has extent", false,
                                   "peak offset \(peak)px from the centre line")
                    return
                }
                // Linear in gain, so the drawn offset is proportional to the
                // fraction through the fade. This is what separates linear from
                // equal-power, which would read ~71% at the midpoint.
                for fraction in [0.25, 0.5, 0.75] {
                    let time = rising ? start + fade * fraction : start + fade * (1 - fraction)
                    guard let measured = offsetNear(column(atTime: time)) else {
                        reporter.check("fade-\(label) \(Int(fraction * 100))% point", false,
                                       "no envelope ink at \(spot(time))")
                        continue
                    }
                    let expected = Double(peak) * fraction
                    reporter.check("fade-\(label) is linear at \(Int(fraction * 100))%",
                                   abs(Double(measured) - expected) <= Double(peak) * 0.12,
                                   "offset \(measured)px, expected \(Int(expected))px of \(peak)px")
                }
            }

            checkFade("in", start: spec.trimStart, fade: spec.fadeIn, rising: true,
                      own: fadeInRegion)
            checkFade("out", start: spec.trimEnd - spec.fadeOut, fade: spec.fadeOut, rising: false,
                      own: fadeOutRegion)
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

        // ------------------------------------------------ transport readouts fit
        // The In/Out values are amber, which is hardcoded (not the user-
        // configurable accent), so they are a stable thing to measure. Each value
        // must sit on a single text line: when the transport bar is squeezed, a
        // value wraps and its amber row-profile splits into two bands — and the
        // cluster narrows to roughly half its width. This is the regression guard
        // for the bottom bar wrapping its numbers at the minimum window width.
        checkTransportReadoutsSingleLine(bitmap: bitmap, reporter: reporter)

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
        guard let band = panelBand(bitmap: bitmap) else { return nil }

        var whitePerColumn = [Int](repeating: 0, count: bitmap.width)
        for y in band.top...band.bottom {
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

    /// Verifies the amber `IN`/`OUT` values in the transport bar each occupy one
    /// text line. A squeezed bar wraps them onto two, which is visible as two
    /// amber row-bands (and about half the horizontal span).
    ///
    /// Anchored to the waveform panel's bottom, not the waveform ink extent: the
    /// amber trim handles reach lower than the loudest waveform bar, so starting
    /// at the waveform bottom would measure the handles rather than the readouts.
    private static func checkTransportReadoutsSingleLine(bitmap: Bitmap,
                                                         reporter: TestReporter) {
        guard let panel = panelBand(bitmap: bitmap), panel.bottom + 1 < bitmap.height else {
            reporter.check("transport bar located", false, "no waveform panel found")
            return
        }
        let band = (panel.bottom + 1)..<bitmap.height

        var amberColumns: [Int] = []
        for x in 0..<bitmap.width {
            for y in band {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isAmber(r, g, b) { amberColumns.append(x); break }
            }
        }
        guard amberColumns.count > 8 else {
            reporter.check("transport readouts found", false,
                           "no amber ink below the panel")
            return
        }

        // Group amber columns into the In and Out value blocks.
        var clusters: [[Int]] = [[amberColumns[0]]]
        for x in amberColumns.dropFirst() {
            if x - clusters[clusters.count - 1].last! <= 14 {
                clusters[clusters.count - 1].append(x)
            } else {
                clusters.append([x])
            }
        }
        let blocks = clusters.filter { $0.count >= 8 }
        guard blocks.count >= 2 else {
            reporter.check("both In and Out readouts found", false,
                           "\(blocks.count) amber block(s)")
            return
        }

        var wrapped: [String] = []
        for block in blocks {
            var bands = 0
            var inBand = false
            var gap = 0
            for y in band {
                let hasAmber = block.contains { x in
                    let (r, g, b) = bitmap.rgb(x, y)
                    return Ink.isAmber(r, g, b)
                }
                if hasAmber {
                    if !inBand { bands += 1; inBand = true }
                    gap = 0
                } else if inBand {
                    gap += 1
                    if gap >= 5 { inBand = false }
                }
            }
            if bands != 1 {
                wrapped.append("x\(block.first!)–\(block.last!): \(bands) lines")
            }
        }
        reporter.check("In/Out readouts are single-line (numbers do not wrap)",
                       wrapped.isEmpty,
                       wrapped.isEmpty
                           ? "\(blocks.count) block(s) \(blocks.map { "\($0.first!)–\($0.last!)" }.joined(separator: ", ")), one line each"
                           : wrapped.joined(separator: ", "))
    }

    /// The waveform panel's vertical extent, found by its distinctive dark
    /// blue-grey background. Shared so that envelope ink can be looked for inside
    /// the panel and nowhere else.
    private static func panelBand(bitmap: Bitmap) -> (top: Int, bottom: Int)? {
        var panelRows: [Int] = []
        for y in 0..<bitmap.height {
            var panelPixels = 0
            for x in stride(from: 0, to: bitmap.width, by: 2) {
                let (r, g, b) = bitmap.rgb(x, y)
                if Ink.isPanelBackground(r, g, b) { panelPixels += 1 }
            }
            if panelPixels > bitmap.width / 20 { panelRows.append(y) }
        }
        guard let top = panelRows.first, let bottom = panelRows.last, bottom > top else { return nil }
        return (top, bottom)
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