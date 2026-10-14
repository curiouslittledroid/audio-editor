import AVFoundation
import Foundation

/// `--selftest <file.wav>` exercises the whole pipeline (read → analyse → export)
/// without any UI, so the audio path can be verified independently of the views.
enum SelfTest {

    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--selftest"), arguments.count > index + 1 else {
            print("usage: AudioEditor --selftest <file.wav> [more.wav ...]")
            print("   or: AUDIOEDIT_SELFTEST=<file.wav>[:<more.wav>...] AudioEditor")
            return 2
        }
        return run(paths: arguments[(index + 1)...].filter { !$0.hasPrefix("--") })
    }

    static func run(paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            print("selftest: no input files given")
            return 2
        }
        let reporter = TestReporter()
        for path in paths {
            test(url: URL(fileURLWithPath: path), reporter: reporter)
        }

        // Cross-file behaviour: things that only make sense with a document
        // already open. Run once, anchored on the first fixture.
        let first = URL(fileURLWithPath: paths[0])
        let second = paths.count > 1 ? URL(fileURLWithPath: paths[1]) : nil
        let invalidDir = first.deletingLastPathComponent().appendingPathComponent("invalid")
        let corruptWAV = invalidDir.appendingPathComponent("corrupt.wav")
        let notAudio = invalidDir.appendingPathComponent("notes.txt")

        testFades(source: first, reporter: reporter)
        testFadeModelState(good: first, second: second, reporter: reporter)
        testFadePreview(source: first, reporter: reporter)

        if FileManager.default.fileExists(atPath: corruptWAV.path) {
            testFailedLoadPreservesEngine(good: first, invalid: corruptWAV, reporter: reporter)
            testRefusedOpenPreservesDocument(good: first, second: second,
                                             corruptWAV: corruptWAV, notAudio: notAudio,
                                             reporter: reporter)
        } else {
            reporter.section("refused-open behaviour")
            reporter.check("invalid fixtures present", false,
                           "run: swift tools/make-test-audio.swift")
        }

        return reporter.finish()
    }

    /// Pumps the run loop until `condition` holds or the timeout expires. Needed
    /// for checks that depend on work the app dispatches to other queues.
    private static func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// docs/specs/SPEC.md G5: the engine must keep the current file when a new one cannot be
    /// opened, and must still be able to play it.
    private static func testFailedLoadPreservesEngine(good: URL, invalid: URL, reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section("failed load preserves the engine (G5)")

        let engine = AudioEngineController()
        do {
            try engine.load(url: good)
        } catch {
            check("fixture loads", false, "\(error)")
            return
        }

        let duration = engine.duration
        let channels = engine.channelCount
        let rate = engine.sampleRate

        var rejected = false
        do {
            try engine.load(url: invalid)
        } catch {
            rejected = true
        }
        check("undecodable file is rejected", rejected)
        check("duration preserved", engine.duration == duration,
              "\(engine.duration) vs \(duration)")
        check("channel count preserved", engine.channelCount == channels)
        check("sample rate preserved", engine.sampleRate == rate)
        check("still holds a file", engine.hasFile)

        // The real proof: it can still play.
        engine.play(from: 0, to: min(0.2, duration), looping: false)
        check("still plays", engine.isPlaying)
        engine.stop()
        check("currentTime is available while playing", waitUntil(timeout: 2) {
            engine.play(from: 0, to: min(0.2, duration), looping: false)
            let has = engine.currentTime != nil
            engine.stop()
            return has
        })
    }

    /// docs/specs/SPEC.md G4: refusing a file must leave the document exactly as it was —
    /// same file, selection, playhead and waveform — and a successful open must
    /// still fully replace it.
    private static func testRefusedOpenPreservesDocument(good: URL, second: URL?,
                                                        corruptWAV: URL, notAudio: URL,
                                                        reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section("refused open preserves the document (G4)")

        let model = AudioDocumentModel()
        model.load(url: good)
        check("fixture loads", waitUntil { !model.isAnalyzing && model.hasFile },
              model.errorMessage ?? "")
        guard model.hasFile else { return }

        // Put the document into a distinctive state that a failure must not erase.
        model.setTrimStart(model.duration * 0.25)
        model.setTrimEnd(model.duration * 0.75)
        model.seek(to: model.duration * 0.4)
        let baseline = (url: model.fileURL,
                        name: model.displayName,
                        duration: model.duration,
                        peaks: model.peaks.bucketCount,
                        trimStart: model.trimStart,
                        trimEnd: model.trimEnd,
                        playhead: model.playhead)

        func assertUnchanged(_ label: String) {
            check("\(label): error reported", model.errorMessage != nil,
                  model.errorMessage ?? "(no error)")
            check("\(label): file unchanged", model.fileURL == baseline.url,
                  model.displayName)
            check("\(label): waveform retained", model.peaks.bucketCount == baseline.peaks,
                  "\(model.peaks.bucketCount) vs \(baseline.peaks)")
            check("\(label): selection retained",
                  model.trimStart == baseline.trimStart && model.trimEnd == baseline.trimEnd)
            check("\(label): playhead retained", model.playhead == baseline.playhead)
            check("\(label): transport untouched", !model.isPlaying)
            model.errorMessage = nil
        }

        // (a) wrong extension
        model.load(url: notAudio)
        assertUnchanged("unsupported extension")

        // (b) right extension, undecodable content — the case that used to wipe it
        model.load(url: corruptWAV)
        assertUnchanged("undecodable .wav")

        // (c) a successful open must still fully replace the document
        if let second {
            model.load(url: second)
            check("successful open replaces the document",
                  waitUntil { !model.isAnalyzing } && model.fileURL == second,
                  model.displayName)
            check("successful open resets the selection",
                  model.trimStart == 0 && abs(model.trimEnd - model.duration) < 0.0001)
            check("successful open clears the error", model.errorMessage == nil)
            check("successful open resets the playhead", model.playhead == 0)
        }
    }

    /// Reads an entire file into per-channel float arrays.
    private static func readAllSamples(_ url: URL) throws -> (frames: Int, channels: [[Float]]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(file.length)
        let channelCount = Int(file.processingFormat.channelCount)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(frames)) else {
            return (0, [])
        }
        try file.read(into: buffer)
        var channels = [[Float]]()
        if let data = buffer.floatChannelData {
            for channel in 0..<channelCount {
                channels.append(Array(UnsafeBufferPointer(start: data[channel],
                                                          count: Int(buffer.frameLength))))
            }
        }
        return (Int(buffer.frameLength), channels)
    }

    /// docs/specs/001-fade-in-out.md G41–G46 — the envelope, its clamping, and the
    /// guarantee that no fades means no change at all.
    private static func testFades(source: URL, reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section("fade in / out (G41–G46)")

        guard let header = try? AVAudioFile(forReading: source) else {
            check("fixture opens", false)
            return
        }
        let rate = header.fileFormat.sampleRate
        let total = header.length

        // A tenth of the file: small enough to stay cheap even on the long
        // fixture, long enough to give thousands of frames to check.
        let startSeconds = Double(total / 4) / rate
        let endSeconds = Double(total * 35 / 100) / rate
        let range = TrimmedAudioExporter.frameRange(forStart: startSeconds, end: endSeconds,
                                                    sampleRate: rate, totalFrames: total)
        let selection = range.end - range.start
        guard selection > 100 else {
            check("selection has frames", false, "\(selection)")
            return
        }

        let fadeSeconds = Double(selection / 10) / rate
        let spec = TrimmedAudioExporter.FadeSpec(fadeIn: fadeSeconds, fadeOut: fadeSeconds)
        let counts = TrimmedAudioExporter.fadeFrameCounts(spec, sampleRate: rate,
                                                          selectionFrames: selection)

        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-plain-\(UUID().uuidString).wav")
        let faded = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-faded-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: faded)
        }

        do {
            try TrimmedAudioExporter.export(sourceURL: source, to: plain,
                                            start: startSeconds, end: endSeconds)
            try TrimmedAudioExporter.export(sourceURL: source, to: faded,
                                            start: startSeconds, end: endSeconds, fade: spec)
        } catch {
            check("fade export", false, "\(error)")
            return
        }

        guard let reference = try? readAllSamples(plain),
              let actual = try? readAllSamples(faded) else {
            check("fade exports readable", false, "could not re-read the exports")
            return
        }
        // The exporter works in Int64 frames; the checks index Swift arrays, so
        // narrow once here rather than at every use.
        let frames = Int(selection)
        let fadeInFrames = Int(counts.fadeIn)
        let fadeOutFrames = Int(counts.fadeOut)
        guard reference.frames == frames, actual.frames == frames,
              !reference.channels.isEmpty, !actual.channels.isEmpty else {
            check("fade exports readable", false,
                  "frames \(reference.frames)/\(actual.frames) vs \(frames)")
            return
        }
        check("faded export keeps the frame count", actual.frames == frames,
              "\(actual.frames) vs \(frames)")
        check("faded export keeps the channel count",
              actual.channels.count == reference.channels.count,
              "\(actual.channels.count) vs \(reference.channels.count)")

        // --- G41: the analytic envelope --------------------------------------
        func gain(_ offset: Int) -> Float {
            TrimmedAudioExporter.fadeGain(atOffset: AVAudioFramePosition(offset),
                                          fadeInFrames: counts.fadeIn,
                                          fadeOutFrames: counts.fadeOut,
                                          totalFrames: selection)
        }
        // Both endpoints inclusive: exactly 0 at each end of each fade.
        check("fade-in starts at exactly 0 gain", gain(0) == 0, "gain \(gain(0))")
        check("fade-in reaches exactly 1 gain",
              gain(fadeInFrames - 1) == 1, "gain \(gain(fadeInFrames - 1))")
        check("fade-out starts at exactly 1 gain",
              gain(frames - fadeOutFrames) == 1, "gain \(gain(frames - fadeOutFrames))")
        check("fade-out ends at exactly 0 gain", gain(frames - 1) == 0,
              "gain \(gain(frames - 1))")
        check("midpoint between the fades is untouched",
              gain(frames / 2) == 1, "gain \(gain(frames / 2))")

        // Monotone up across the fade-in, monotone down across the fade-out.
        var rises = true
        for offset in 1..<fadeInFrames where gain(offset) < gain(offset - 1) { rises = false }
        var falls = true
        for offset in (frames - fadeOutFrames + 1)..<frames
        where gain(offset) > gain(offset - 1) { falls = false }
        check("fade-in rises monotonically", rises)
        check("fade-out falls monotonically", falls)

        // Linearity, which is what distinguishes this from an equal-power curve:
        // an equal-power ramp reads ~0.71 at the midpoint instead of 0.5.
        let halfFade = fadeInFrames / 2
        let quarterFade = fadeInFrames / 4
        if fadeInFrames > 8 {
            check("fade-in is linear at 50%", abs(gain(halfFade) - 0.5) < 0.01,
                  "gain \(gain(halfFade))")
            check("fade-in is linear at 25%", abs(gain(quarterFade) - 0.25) < 0.02,
                  "gain \(gain(quarterFade))")
        }

        // --- G41/G45: the exported samples -----------------------------------
        var maxRelativeError: Double = 0
        var comparedFrames = 0
        for offset in 0..<frames {
            let source0 = Double(reference.channels[0][offset])
            guard abs(source0) > 0.01 else { continue }
            comparedFrames += 1
            let expected = source0 * Double(gain(offset))
            maxRelativeError = max(maxRelativeError, abs(Double(actual.channels[0][offset]) - expected))
        }
        check("enough signal to compare", comparedFrames > 50, "\(comparedFrames) frames")
        // Tolerance is one 16-bit quantisation step: the reference is quantised
        // to disk, so an exact float comparison would fail for the wrong reason.
        check("envelope matches the exported samples", maxRelativeError < 6.2e-5,
              "max deviation \(String(format: "%.7f", maxRelativeError)) over \(comparedFrames) frames")

        check("first exported sample is exactly silent", actual.channels[0][0] == 0,
              "\(actual.channels[0][0])")
        check("last exported sample is exactly silent",
              actual.channels[0][frames - 1] == 0, "\(actual.channels[0][frames - 1])")

        // G45: outside the fades the two exports must agree bit-for-bit. This is
        // the check that catches an off-by-one in the frame maths.
        var untouched = true
        var firstChanged = -1
        for offset in fadeInFrames..<(frames - fadeOutFrames)
        where actual.channels[0][offset] != reference.channels[0][offset] {
            untouched = false
            if firstChanged < 0 { firstChanged = offset }
        }
        check("samples outside the fades are bit-identical", untouched,
              firstChanged < 0 ? "" : "first difference at frame \(firstChanged)")

        var channelsMatch = true
        for channel in 1..<min(actual.channels.count, reference.channels.count) {
            if actual.channels[channel] != reference.channels[channel] { channelsMatch = false }
        }
        check("every channel gets the same gain", channelsMatch)

        // --- G42: clamping ----------------------------------------------------
        let greedy = TrimmedAudioExporter.FadeSpec(fadeIn: Double(selection) / rate,
                                                   fadeOut: Double(selection) / rate)
        let clamped = TrimmedAudioExporter.fadeFrameCounts(greedy, sampleRate: rate,
                                                          selectionFrames: selection)
        let half = selection / 2
        check("oversized fades clamp to half the selection",
              clamped.fadeIn == half && clamped.fadeOut == half,
              "\(clamped.fadeIn)+\(clamped.fadeOut) vs \(half) each")
        check("clamped fades cannot overlap",
              clamped.fadeIn + clamped.fadeOut <= selection,
              "\(clamped.fadeIn)+\(clamped.fadeOut) > \(selection)")
        let zero = TrimmedAudioExporter.fadeFrameCounts(.none, sampleRate: rate,
                                                        selectionFrames: selection)
        check("no fades resolve to no frames", zero.fadeIn == 0 && zero.fadeOut == 0)

        // --- single-frame fade ------------------------------------------------
        check("a one-frame fade silences exactly one sample",
              TrimmedAudioExporter.fadeGain(atOffset: 0, fadeInFrames: 1, fadeOutFrames: 0,
                                            totalFrames: selection) == 0
                && TrimmedAudioExporter.fadeGain(atOffset: 1, fadeInFrames: 1, fadeOutFrames: 0,
                                                 totalFrames: selection) == 1)

        // --- G46: no fades means no change -----------------------------------
        // Compared against the source rather than against another export, so this
        // actually proves the default path is still a pure copy.
        var maxCopyError: Double = 0
        if let original = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                          interleaved: false),
           let buffer = AVAudioPCMBuffer(pcmFormat: original.processingFormat,
                                         frameCapacity: AVAudioFrameCount(selection)) {
            original.framePosition = range.start
            try? original.read(into: buffer)
            if let data = buffer.floatChannelData {
                for offset in 0..<min(Int(buffer.frameLength), frames) {
                    let delta = abs(Double(data[0][offset]) - Double(reference.channels[0][offset]))
                    maxCopyError = max(maxCopyError, delta)
                }
            }
        }
        check("an unfaded export still copies the source closely", maxCopyError < 1e-4,
              "max deviation \(String(format: "%.7f", maxCopyError))")
    }

    /// docs/specs/SPEC.md G30 and G43 — the model-side fade state: clamping as the
    /// selection shrinks, and Reset clearing fades.
    ///
    /// The exporter clamps too (G42), but that is invisible to the user. These
    /// checks are about the value the field displays, which is the one that must
    /// never overstate what will be applied.
    private static func testFadeModelState(good: URL, second: URL?, reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section("fade model state (G30, G43)")

        let model = AudioDocumentModel()
        model.load(url: good)
        check("fixture loads", waitUntil { !model.isAnalyzing && model.hasFile },
              model.errorMessage ?? "")
        guard model.hasFile else { return }

        model.resetTrim()
        let ceiling = model.maxFadeDuration
        model.setFadeIn(ceiling * 4)
        check("an oversized fade clamps to half the selection",
              abs(model.fadeInDuration - ceiling) < 1e-9,
              "\(model.fadeInDuration) vs \(ceiling)")

        // Shrink the selection to 5% of the file. The stored fade must come down
        // with it, because the field displays the stored value (G43).
        model.setTrimStart(model.duration * 0.475)
        model.setTrimEnd(model.duration * 0.525)
        let shrunk = model.maxFadeDuration
        check("shrinking the selection re-clamps the stored fade",
              model.fadeInDuration <= shrunk + 1e-9 && model.fadeOutDuration <= shrunk + 1e-9,
              "fades \(model.fadeInDuration) vs ceiling \(shrunk)")
        check("the stored fade never exceeds what will be applied",
              model.fadeSpec.fadeIn <= model.maxFadeDuration + 1e-9,
              "\(model.fadeSpec.fadeIn) vs \(model.maxFadeDuration)")

        model.setFadeIn(0)
        model.setFadeOut(0.001)
        check("a fade alone counts as an edit", model.hasFades && model.isEdited)

        model.resetTrim()
        check("Reset clears the fades",
              !model.hasFades && model.fadeInDuration == 0 && model.fadeOutDuration == 0)
        check("Reset also restores the whole selection",
              model.trimStart == 0 && model.trimEnd == model.duration)
        check("Reset leaves nothing edited", !model.isEdited)

        if let second {
            model.setFadeIn(0.001)
            model.load(url: second)
            check("loading a new file clears the fades",
                  waitUntil { !model.isAnalyzing && model.fileURL == second } && !model.hasFades,
                  "fade-in \(model.fadeInDuration)")
        }
    }

    /// docs/specs/001-fade-in-out.md — audible preview (Phase 2).
    ///
    /// Verifies the exact audio a playback pass will emit, without an output
    /// device: `playbackItems` is the same function `AudioEngineController.play`
    /// schedules from, so checking it is checking the preview. The faded parts
    /// must be envelopes of the source, must cover the selection exactly with no
    /// gap or overlap, and the no-fade case must compose to one segment.
    private static func testFadePreview(source: URL, reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section("fade preview scheduling (G41, G46)")

        guard let file = try? AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32,
                                          interleaved: false) else {
            check("fixture opens", false)
            return
        }
        let rate = file.processingFormat.sampleRate
        let total = file.length
        let range = TrimmedAudioExporter.frameRange(forStart: Double(total / 4) / rate,
                                                    end: Double(total * 45 / 100) / rate,
                                                    sampleRate: rate, totalFrames: total)
        let frameCount = range.end - range.start
        guard frameCount > 100 else {
            check("selection has frames", false, "\(frameCount)")
            return
        }

        // Read the selection *before* playbackItems moves the file pointer.
        var original: [Float] = []
        if let selection = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(frameCount)) {
            file.framePosition = range.start
            try? file.read(into: selection, frameCount: AVAudioFrameCount(frameCount))
            if let channel = selection.floatChannelData?[0] {
                original = Array(UnsafeBufferPointer(start: channel, count: Int(selection.frameLength)))
            }
        }
        guard original.count == Int(frameCount) else {
            check("selection re-readable for comparison", false, "\(original.count) vs \(frameCount)")
            return
        }

        let fadeSeconds = Double(frameCount / 10) / rate
        let spec = TrimmedAudioExporter.FadeSpec(fadeIn: fadeSeconds, fadeOut: fadeSeconds)
        let counts = TrimmedAudioExporter.fadeFrameCounts(spec, sampleRate: rate,
                                                          selectionFrames: frameCount)
        let fadeInFrames = Int(counts.fadeIn)
        let fadeOutFrames = Int(counts.fadeOut)

        // --- structural: head + middle + tail covers the selection exactly ---
        let items = AudioEngineController.playbackItems(file: file, startFrame: range.start,
                                                        frameCount: frameCount, fade: spec)
        check("a faded pass is head + middle + tail", items.count == 3, "\(items.count) items")
        guard items.count == 3 else { return }

        guard case .buffer(let head) = items[0],
              case .segment(let middleStart, let middleCount) = items[1],
              case .buffer(let tail) = items[2] else {
            check("pass order is buffer, segment, buffer", false)
            return
        }

        check("head buffer is the fade-in length", Int(head.frameLength) == fadeInFrames,
              "\(head.frameLength) vs \(fadeInFrames)")
        check("tail buffer is the fade-out length", Int(tail.frameLength) == fadeOutFrames,
              "\(tail.frameLength) vs \(fadeOutFrames)")
        check("middle segment starts after the fade-in",
              middleStart == range.start + counts.fadeIn,
              "\(middleStart) vs \(range.start + counts.fadeIn)")
        let covered = Int(head.frameLength) + Int(middleCount) + Int(tail.frameLength)
        check("the pass covers the selection exactly, with no gap or overlap",
              covered == Int(frameCount), "\(covered) vs \(frameCount)")

        // --- the envelope is actually applied in the preview -----------------
        guard let headSamples = head.floatChannelData?[0],
              let tailSamples = tail.floatChannelData?[0] else {
            check("faded buffers have samples", false)
            return
        }
        check("preview fade-in starts at exactly silent", headSamples[0] == 0,
              "\(headSamples[0])")
        check("preview fade-out ends at exactly silent",
              tailSamples[fadeOutFrames - 1] == 0, "\(tailSamples[fadeOutFrames - 1])")

        func gain(_ offset: Int) -> Float {
            TrimmedAudioExporter.fadeGain(atOffset: AVAudioFramePosition(offset),
                                          fadeInFrames: counts.fadeIn,
                                          fadeOutFrames: counts.fadeOut,
                                          totalFrames: frameCount)
        }
        var maxHeadError: Float = 0
        for offset in 0..<fadeInFrames {
            maxHeadError = max(maxHeadError,
                               abs(headSamples[offset] - original[offset] * gain(offset)))
        }
        var maxTailError: Float = 0
        for offset in 0..<fadeOutFrames {
            let absolute = Int(frameCount) - fadeOutFrames + offset
            maxTailError = max(maxTailError,
                               abs(tailSamples[offset] - original[absolute] * gain(absolute)))
        }
        // Tolerance is a 16-bit quantisation step: the fixture is quantised to disk.
        check("preview fade-in applies the analytic envelope", maxHeadError < 6.2e-5,
              "max deviation \(maxHeadError)")
        check("preview fade-out applies the analytic envelope", maxTailError < 6.2e-5,
              "max deviation \(maxTailError)")

        // The attenuation must be real: at the fade-in midpoint the preview is
        // about half the source, not a copy of it. This is the check that fails
        // if the fade is silently dropped from the preview path.
        let midpoint = fadeInFrames / 2
        if abs(original[midpoint]) > 0.05 {
            let ratio = abs(headSamples[midpoint] / original[midpoint])
            check("preview fade-in midpoint is attenuated to ~0.5",
                  abs(ratio - 0.5) < 0.02, "ratio \(ratio)")
        } else {
            check("midpoint has signal to measure attenuation", false,
                  "source \(original[midpoint])")
        }

        // Endpoints are inclusive, so the interior edge of each buffer is unattenuated.
        check("the fade-in reaches full gain at its last sample",
              headSamples[fadeInFrames - 1] == original[fadeInFrames - 1])
        check("the fade-out starts at full gain",
              tailSamples[0] == original[Int(frameCount) - fadeOutFrames])

        // --- G46: no fades still composes to the original single segment ----
        let plain = AudioEngineController.playbackItems(file: file, startFrame: range.start,
                                                        frameCount: frameCount, fade: .none)
        check("an unfaded pass is a single segment", plain.count == 1, "\(plain.count) items")
        if plain.count == 1, case .segment(let plainStart, let plainCount) = plain[0] {
            check("the unfaded segment is the whole selection",
                  plainStart == range.start && plainCount == AVAudioFrameCount(frameCount),
                  "\(plainStart)+\(plainCount) vs \(range.start)+\(frameCount)")
        }

        // One-sided fades stay one-sided: no zero-length buffer is manufactured.
        let inOnly = AudioEngineController.playbackItems(
            file: file, startFrame: range.start, frameCount: frameCount,
            fade: TrimmedAudioExporter.FadeSpec(fadeIn: fadeSeconds))
        check("a fade-in alone is head + middle", inOnly.count == 2, "\(inOnly.count) items")

        // --- clamping carries through to the preview -------------------------
        let greedy = TrimmedAudioExporter.FadeSpec(fadeIn: Double(frameCount) / rate,
                                                   fadeOut: Double(frameCount) / rate)
        let greedyItems = AudioEngineController.playbackItems(file: file, startFrame: range.start,
                                                              frameCount: frameCount, fade: greedy)
        var greedyCovered = 0
        var greedyMiddle = 0
        for item in greedyItems {
            switch item {
            case .buffer(let buffer): greedyCovered += Int(buffer.frameLength)
            case .segment(_, let count): greedyCovered += Int(count); greedyMiddle += Int(count)
            }
        }
        // Each fade clamps to floor(L/2), so an odd selection can leave a single
        // frame between them — but never a substantive middle.
        check("a fully faded pass has no substantive middle", greedyMiddle <= 1,
              "\(greedyMiddle) middle frames across \(greedyItems.count) items")
        check("a fully faded pass still covers the selection exactly",
              greedyCovered == Int(frameCount), "\(greedyCovered) vs \(frameCount)")

        // --- a pass that resumes part-way through the selection -------------
        // This is what a looping resume or a mid-loop fade edit builds. It must
        // cover exactly the remainder, with the segment starting where the
        // previous item ended, and the envelope computed against the *whole*
        // selection rather than the remainder.
        func contiguous(_ items: [AudioEngineController.PlaybackItem],
                        from expectedStart: AVAudioFramePosition) -> Bool {
            var position = expectedStart
            for item in items {
                switch item {
                case .segment(let segmentStart, let count):
                    if segmentStart != position { return false }
                    position += AVAudioFramePosition(count)
                case .buffer(let buffer):
                    position += AVAudioFramePosition(buffer.frameLength)
                }
            }
            return position == range.start + frameCount
        }

        let middleOffset = AVAudioFramePosition(frameCount / 2) - counts.fadeIn
        let middleItems = AudioEngineController.playbackItems(file: file,
                                                              selectionStart: range.start,
                                                              selectionFrames: frameCount,
                                                              beginOffset: middleOffset,
                                                              fade: spec)
        check("a mid-selection pass covers exactly the remainder",
              contiguous(middleItems, from: range.start + middleOffset),
              "\(middleItems.count) items")
        // Starting past the fade-in, so the first item is the untouched middle
        // and the only buffer is the fade-out tail (no fade-in buffer is emitted).
        var middleBufferCount = 0
        for item in middleItems { if case .buffer = item { middleBufferCount += 1 } }
        var startsWithSegment = false
        if let firstItem = middleItems.first, case .segment = firstItem {
            startsWithSegment = true
        }
        check("a pass resumed past the fade-in emits no fade-in buffer",
              startsWithSegment && middleBufferCount == 1,
              "\(middleItems.count) items, \(middleBufferCount) buffers, first is segment: \(startsWithSegment)")

        // Resume inside the fade-out: the first item is a shortened tail whose
        // envelope continues from the right offset, not one that restarts at 1.
        let tailOffset = AVAudioFramePosition(frameCount) - counts.fadeOut / 2
        let tailItems = AudioEngineController.playbackItems(file: file,
                                                            selectionStart: range.start,
                                                            selectionFrames: frameCount,
                                                            beginOffset: tailOffset,
                                                            fade: spec)
        check("a pass resumed inside the fade-out is a single tail remainder",
              tailItems.count == 1, "\(tailItems.count) items")
        if tailItems.count == 1, case .buffer(let remainder) = tailItems[0] {
            check("the tail remainder is the part still ahead",
                  Int(remainder.frameLength) == Int(frameCount - tailOffset),
                  "\(remainder.frameLength) vs \(frameCount - tailOffset)")
            let expectedGain = gain(Int(tailOffset))
            let expectedSample = original[Int(tailOffset)] * expectedGain
            if let samples = remainder.floatChannelData?[0], abs(expectedSample) > 0.01 {
                check("the resumed tail continues the envelope rather than restarting it",
                      abs(samples[0] - expectedSample) < 6.2e-5,
                      "\(samples[0]) vs \(expectedSample) (gain \(expectedGain))")
            } else {
                check("resumed tail has signal to check the envelope", false,
                      "source \(original[Int(tailOffset)])")
            }
        }

        // --- the composite pass is schedulable against a real engine ---------
        // Composing the items correctly means nothing if the player rejects the
        // mixed buffer/segment schedule, so drive the real scheduling path once.
        let controller = AudioEngineController()
        let selectionStartSeconds = Double(range.start) / rate
        let selectionEndSeconds = Double(range.end) / rate
        do {
            try controller.load(url: source)
            controller.play(from: selectionStartSeconds, to: selectionEndSeconds,
                            looping: false, fade: spec)
            check("a faded pass starts playing", controller.isPlaying)
            check("a non-looping pass reports no loop range", controller.loopRangeFrames == nil)
            controller.stop()
            check("stopping ends a faded pass", !controller.isPlaying)

            controller.play(from: selectionStartSeconds, to: selectionEndSeconds,
                            looping: true, fade: spec)
            check("a looping faded pass starts playing", controller.isPlaying)
            check("a loop begun at the selection start spans the selection",
                  controller.loopRangeFrames == range.start...range.end,
                  "\(String(describing: controller.loopRangeFrames)) vs \(range.start)...\(range.end)")
            controller.stop()

            // G17: resuming part-way through a loop must not shrink the loop.
            let resumeSeconds = selectionStartSeconds
                + (selectionEndSeconds - selectionStartSeconds) * 0.6
            controller.play(from: resumeSeconds, to: selectionEndSeconds,
                            looping: true, loopStart: selectionStartSeconds, fade: spec)
            check("a looping resume keeps the full loop range (G17)",
                  controller.loopRangeFrames == range.start...range.end,
                  "\(String(describing: controller.loopRangeFrames)) vs \(range.start)...\(range.end)")
            controller.stop()
        } catch {
            check("faded preview is schedulable", false, "\(error)")
        }
    }

    private static func test(url: URL, reporter: TestReporter) {
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            reporter.check(label, condition, detail)
        }
        reporter.section(url.lastPathComponent)

        // --- Read the on-disk format -----------------------------------------
        var onDiskFrames: AVAudioFramePosition = 0
        var onDiskRate: Double = 0
        var onDiskChannels: AVAudioChannelCount = 0
        do {
            let file = try AVAudioFile(forReading: url)
            onDiskFrames = file.length
            onDiskRate = file.fileFormat.sampleRate
            onDiskChannels = file.fileFormat.channelCount
            let depth = file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
            let isFloat = file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool ?? false
            print("  format: \(onDiskChannels) ch, \(onDiskRate) Hz, \(depth)-bit\(isFloat ? " float" : ""), \(onDiskFrames) frames (\(TimeFormat.duration(Double(onDiskFrames) / onDiskRate)))")
        } catch {
            check("open for reading", false, "\(error)")
            return
        }
        check("has samples", onDiskFrames > 0)

        // --- Waveform analysis ----------------------------------------------
        let started = Date()
        do {
            let peaks = try WaveformPeaks.analyze(url: url, bucketCount: 8_000)
            let elapsed = Date().timeIntervalSince(started)
            check("waveform analysis", peaks.bucketCount > 1,
                  "\(peaks.bucketCount) buckets in \(String(format: "%.3f", elapsed))s")

            let loudest = peaks.maxima.max() ?? 0
            let quietest = peaks.maxima.min() ?? 0
            check("peak energy detected", loudest > 0.1, "max \(String(format: "%.3f", loudest))")
            check("silence present", quietest < 0.1, "min-of-maxima \(String(format: "%.3f", quietest))")

            // Buckets above the silence floor tell us where the loud parts are.
            let loudBuckets = peaks.maxima.enumerated()
                .filter { $0.element > 0.1 }
                .map(\.offset)
            if let first = loudBuckets.first, let last = loudBuckets.last {
                let secondsPerBucket = Double(onDiskFrames) / onDiskRate / Double(peaks.bucketCount)
                print("  loud content spans \(TimeFormat.duration(Double(first) * secondsPerBucket)) – \(TimeFormat.duration(Double(last + 1) * secondsPerBucket))")
            }
        } catch {
            check("waveform analysis", false, "\(error)  [\(type(of: error))]")
        }

        // --- Export round trip ----------------------------------------------
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: output) }

        let duration = Double(onDiskFrames) / onDiskRate
        let trimStart = duration * 0.25
        let trimEnd = duration * 0.75

        do {
            try TrimmedAudioExporter.export(sourceURL: url, to: output,
                                            start: trimStart, end: trimEnd)
            let exported = try AVAudioFile(forReading: output)
            let range = TrimmedAudioExporter.frameRange(forStart: trimStart, end: trimEnd,
                                                        sampleRate: onDiskRate,
                                                        totalFrames: onDiskFrames)
            let expectedFrames = range.end - range.start
            let actualFrames = exported.length

            check("export produced a file", actualFrames > 0,
                  "\(actualFrames) frames")
            check("exported duration matches",
                  abs(actualFrames - expectedFrames) <= 2,
                  "expected \(expectedFrames), got \(actualFrames), trim \(TimeFormat.duration(trimStart))–\(TimeFormat.duration(trimEnd))")
            check("exported sample rate preserved",
                  exported.fileFormat.sampleRate == onDiskRate,
                  "\(exported.fileFormat.sampleRate) Hz")
            check("exported channels preserved",
                  exported.fileFormat.channelCount == onDiskChannels,
                  "\(exported.fileFormat.channelCount) ch")

            let inDepth = try AVAudioFile(forReading: url).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
            let outDepth = exported.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
            check("exported bit depth preserved", inDepth == outDepth, "\(inDepth) -> \(outDepth)")

            // The exported audio must match the source over the same time range.
            if let source = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
               let slice = try? AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false),
               let a = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 512),
               let b = AVAudioPCMBuffer(pcmFormat: slice.processingFormat, frameCapacity: 512) {
                source.framePosition = range.start
                try source.read(into: a, frameCount: 512)
                try slice.read(into: b, frameCount: 512)
                var maxDelta: Float = 0
                if let da = a.floatChannelData, let db = b.floatChannelData {
                    for frame in 0..<Int(min(a.frameLength, b.frameLength)) {
                        maxDelta = max(maxDelta, abs(da[0][frame] - db[0][frame]))
                    }
                }
                check("exported samples match source", maxDelta < 0.001,
                      "max delta \(String(format: "%.6f", maxDelta))")
            }
        } catch {
            check("export round trip", false, "\(error)  [\(type(of: error))]")
        }
    }
}
