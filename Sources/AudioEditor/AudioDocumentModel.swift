import AppKit
import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Single source of truth for the window: the loaded file, its waveform, the
/// transport position, and the current trim selection.
final class AudioDocumentModel: ObservableObject {

    // MARK: - Loaded file

    @Published private(set) var fileURL: URL?
    @Published private(set) var displayName: String = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var channelCount: Int = 0
    @Published private(set) var bitDepth: Int?
    @Published private(set) var isFloatFormat = false
    @Published private(set) var byteSize: Int64 = 0
    @Published private(set) var peaks: WaveformPeaks = .empty

    // MARK: - Status

    @Published private(set) var isAnalyzing = false
    @Published private(set) var isExporting = false
    @Published var isDropTargeted = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var lastExportURL: URL?

    // MARK: - Transport

    @Published var playhead: Double = 0
    @Published private(set) var isPlaying = false
    @Published var isLooping = false

    // MARK: - Trim

    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0

    /// Linear fades at the selection boundaries, in seconds. Fades count as
    /// edits, so they survive until Reset and they enable the Reset button.
    @Published private(set) var fadeInDuration: Double = 0
    @Published private(set) var fadeOutDuration: Double = 0

    /// Shortest allowed selection, roughly 5 ms.
    let minimumSelection: Double = 0.005

    var hasFile: Bool { fileURL != nil }
    var hasFades: Bool { fadeInDuration > 0 || fadeOutDuration > 0 }
    var isEdited: Bool {
        trimStart > 0.0005 || trimEnd < duration - 0.0005 || hasFades
    }
    var trimmedDuration: Double { max(0, trimEnd - trimStart) }

    /// A fade may occupy at most half the selection, so the two can never
    /// overlap (G42).
    var maxFadeDuration: Double { trimmedDuration / 2 }

    var fadeSpec: TrimmedAudioExporter.FadeSpec {
        TrimmedAudioExporter.FadeSpec(fadeIn: fadeInDuration, fadeOut: fadeOutDuration)
    }

    var formatSummary: String {
        guard hasFile else { return "" }
        var parts: [String] = []
        if sampleRate > 0 {
            let khz = sampleRate / 1000
            parts.append(khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz))
        }
        if channelCount > 0 {
            switch channelCount {
            case 1: parts.append("Mono")
            case 2: parts.append("Stereo")
            default: parts.append("\(channelCount) ch")
            }
        }
        if let bitDepth {
            parts.append(isFloatFormat ? "\(bitDepth)-bit float" : "\(bitDepth)-bit")
        }
        if byteSize > 0 { parts.append(TimeFormat.fileSize(byteSize)) }
        return parts.joined(separator: " · ")
    }

    private let engine = AudioEngineController()
    private var playheadTimer: Timer?

    init() {
        engine.onReachedEnd = { [weak self] in
            self?.handleReachedEnd()
        }
    }

    // MARK: - Loading

    /// Validates the file type, loads it into the engine, then analyses the
    /// waveform off the main thread.
    ///
    /// Refusing a file — for any reason — leaves the current document exactly as
    /// it was: same file, same selection, same playhead, same waveform, and
    /// playback uninterrupted. Nothing is cleared until the new file is known to
    /// be loaded, so a bad open cannot destroy the open document.
    func load(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "wave" else {
            errorMessage = AudioEditError.unsupportedType(ext.isEmpty ? "unknown" : ext).errorDescription
            return
        }

        // Prepares and commits atomically: on failure the previous file is still
        // loaded in the engine, so return without touching any model state.
        do {
            try engine.load(url: url)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        // Only now is it safe to adopt the new file. Swapping the engine stops
        // the old playback, so the transport state is reset here rather than up
        // front where a failure would have discarded it.
        stop()
        errorMessage = nil
        infoMessage = nil
        lastExportURL = nil
        peaks = .empty

        readMetadata(from: url)

        displayName = url.lastPathComponent
        fileURL = url
        duration = engine.duration
        trimStart = 0
        trimEnd = engine.duration
        fadeInDuration = 0
        fadeOutDuration = 0
        playhead = 0
        isAnalyzing = true

        analyzeWaveform(at: url)
    }

    private func readMetadata(from url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.fileFormat
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        bitDepth = format.settings[AVLinearPCMBitDepthKey] as? Int
        isFloatFormat = (format.settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
        byteSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func analyzeWaveform(at url: URL) {
        let buckets = suggestedBucketCount(for: engine.duration)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try WaveformPeaks.analyze(url: url, bucketCount: buckets) }
            DispatchQueue.main.async {
                guard let self else { return }
                // A newer file may have been loaded while we were analysing.
                guard self.fileURL == url else { return }
                self.isAnalyzing = false
                switch result {
                case .success(let peaks):
                    self.peaks = peaks
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func suggestedBucketCount(for duration: Double) -> Int {
        // ~500 buckets per second keeps transients crisp without huge memory use.
        let target = Int(duration * 500)
        return min(max(target, 2_000), 30_000)
    }

    private func resetDocumentState() {
        fileURL = nil
        displayName = ""
        duration = 0
        sampleRate = 0
        channelCount = 0
        bitDepth = nil
        byteSize = 0
        peaks = .empty
        trimStart = 0
        trimEnd = 0
        fadeInDuration = 0
        fadeOutDuration = 0
        playhead = 0
        isAnalyzing = false
    }

    func closeFile() {
        stop()
        engine.unload()
        resetDocumentState()
        errorMessage = nil
        infoMessage = nil
    }

    // MARK: - File panels

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Audio File"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.wav]
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func presentExportPanel() {
        guard let fileURL else { return }
        let panel = NSSavePanel()
        panel.title = "Export Trimmed Audio"
        panel.prompt = "Export"
        panel.nameFieldStringValue = TrimmedAudioExporter.suggestedFileName(for: fileURL)
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url {
            exportTrimmed(to: destination)
        }
    }

    func exportTrimmed(to destination: URL) {
        guard let source = fileURL else { return }
        let start = trimStart
        let end = trimEnd
        let fade = fadeSpec
        isExporting = true
        errorMessage = nil
        infoMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try TrimmedAudioExporter.export(sourceURL: source,
                                                to: destination,
                                                start: start,
                                                end: end,
                                                fade: fade)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success:
                    self.lastExportURL = destination
                    self.infoMessage = "Saved “\(destination.lastPathComponent)” (\(TimeFormat.duration(end - start)))"
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    // MARK: - Drag and drop

    /// Pulls a file URL out of a Finder drag and loads the first supported file.
    func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var resolved: URL?
            if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolved = url
            } else if let string = item as? String {
                resolved = URL(string: string)
            }
            guard let url = resolved else { return }
            DispatchQueue.main.async { [weak self] in
                self?.load(url: url)
            }
        }
        return true
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard engine.hasFile else { return }
        if playhead < trimStart || playhead >= trimEnd - 0.001 {
            playhead = trimStart
        }
        engine.play(from: playhead, to: trimEnd, looping: isLooping, fade: fadeSpec)
        isPlaying = true
        startPlayheadTimer()
    }

    func pause() {
        // Read the position before pausing — a paused node reports no time.
        if let current = engine.currentTime {
            playhead = clampToTrim(current)
        }
        engine.pause()
        isPlaying = false
        stopPlayheadTimer()
    }

    func stop() {
        engine.stop()
        isPlaying = false
        playhead = trimStart
        stopPlayheadTimer()
    }

    func togglePlayFromSelectionStart() {
        playhead = trimStart
        play()
    }

    /// Moves the playhead, restarting audio cleanly when already playing.
    func seek(to time: Double) {
        playhead = clamp(time, 0, duration)
        guard isPlaying else { return }
        if playhead >= trimEnd - 0.001 {
            playhead = trimStart
        }
        engine.play(from: playhead, to: trimEnd, looping: isLooping, fade: fadeSpec)
        isPlaying = true
    }

    func setLooping(_ looping: Bool) {
        isLooping = looping
        guard isPlaying else { return }
        let resume = clampToTrim(playhead)
        engine.play(from: resume, to: trimEnd, looping: isLooping, fade: fadeSpec)
        isPlaying = true
    }

    private func handleReachedEnd() {
        isPlaying = false
        stopPlayheadTimer()
        playhead = isLooping ? trimStart : trimEnd
    }

    private func startPlayheadTimer() {
        stopPlayheadTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let current = self.engine.currentTime else { return }
            self.playhead = self.clampToTrim(current)
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    // MARK: - Trim editing

    func setTrimStart(_ value: Double) {
        trimStart = clamp(value, 0, max(0, trimEnd - minimumSelection))
        if playhead < trimStart { playhead = trimStart }
        clampFades()
    }

    func setTrimEnd(_ value: Double) {
        trimEnd = clamp(value, min(duration, trimStart + minimumSelection), duration)
        if playhead > trimEnd { playhead = trimEnd }
        clampFades()
    }

    /// Called when a handle drag finishes, so playback can be re-scheduled
    /// against the final selection rather than mid-drag.
    func commitTrimChangeWhilePlaying() {
        guard isPlaying else { return }
        if playhead < trimStart || playhead >= trimEnd - 0.001 {
            playhead = trimStart
        }
        engine.play(from: playhead, to: trimEnd, looping: isLooping, fade: fadeSpec)
        isPlaying = true
    }

    func setTrimStartToPlayhead() {
        setTrimStart(playhead)
        commitTrimChangeWhilePlaying()
    }

    func setTrimEndToPlayhead() {
        setTrimEnd(playhead)
        commitTrimChangeWhilePlaying()
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
        clearFades()
        playhead = clamp(playhead, 0, duration)
        commitTrimChangeWhilePlaying()
    }

    // MARK: - Fades

    func setFadeIn(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let updated = clamp(seconds, 0, maxFadeDuration)
        guard updated != fadeInDuration else { return }
        fadeInDuration = updated
        rescheduleForFadeChange()
    }

    func setFadeOut(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let updated = clamp(seconds, 0, maxFadeDuration)
        guard updated != fadeOutDuration else { return }
        fadeOutDuration = updated
        rescheduleForFadeChange()
    }

    func clearFades() {
        guard hasFades else { return }
        fadeInDuration = 0
        fadeOutDuration = 0
        rescheduleForFadeChange()
    }

    /// Fades are audible, so changing one while playing re-schedules the pass
    /// from the current position ("hear it as you set it"). The engine builds a
    /// fresh `[head][middle][tail]` pass, so the change takes effect immediately
    /// rather than on the next loop.
    private func rescheduleForFadeChange() {
        guard isPlaying else { return }
        let resume = clampToTrim(playhead)
        engine.play(from: resume, to: trimEnd, looping: isLooping, fade: fadeSpec)
        isPlaying = true
    }

    /// Re-clamps the stored durations after the selection shrinks. The stored
    /// value is what the field displays, so it must always equal what will be
    /// applied (G43) — a field that shows 500 ms while applying 100 ms would be
    /// lying about the output.
    private func clampFades() {
        let limit = maxFadeDuration
        if fadeInDuration > limit { fadeInDuration = limit }
        if fadeOutDuration > limit { fadeOutDuration = limit }
    }

    func selectAll() {
        resetTrim()
    }

    // MARK: - Helpers

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }

    private func clampToTrim(_ value: Double) -> Double {
        clamp(value, trimStart, max(trimStart, trimEnd))
    }
}
