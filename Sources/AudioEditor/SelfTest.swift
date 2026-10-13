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
