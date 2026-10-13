import AVFoundation
import Foundation

/// Wraps `AVAudioEngine` + `AVAudioPlayerNode` for sample-accurate playback of a
/// sub-range of a file, with optional looping of that range.
///
/// Only one file is loaded at a time; loading a new file tears the engine down and
/// rebuilds it so stale hardware formats can never leak between files.
final class AudioEngineController {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var file: AVAudioFile?

    private var segmentStartFrame: AVAudioFramePosition = 0
    private var segmentEndFrame: AVAudioFramePosition = 0
    private var isLooping = false

    /// Incremented on every stop/start so late completion callbacks from a
    /// previous segment are ignored.
    private var generation = 0

    /// Number of full playback passes currently queued for looping. Used to keep
    /// two passes in flight so the loop stays gapless when a pass is a composite
    /// of buffers and segments. Reset on every stop/start.
    private var loopQueuedPasses = 0

    /// Called on the main queue when a non-looping segment reaches its end.
    var onReachedEnd: (() -> Void)?

    private(set) var duration: Double = 0
    private(set) var sampleRate: Double = 44_100
    private(set) var channelCount: Int = 0

    var hasFile: Bool { file != nil }

    // MARK: - Loading

    /// Loads `url`, replacing the current file **only if the new one is fully
    /// readable and playable**.
    ///
    /// Everything is prepared into locals first and committed at the end, so a
    /// file that fails to open leaves the previously loaded file untouched —
    /// still loaded, still at its position, and still playing if it was. A bad
    /// open must not be able to destroy the user's work.
    func load(url: URL) throws {
        // ---- prepare: nothing here touches existing state -------------------
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url,
                                        commonFormat: .pcmFormatFloat32,
                                        interleaved: false)
        } catch {
            throw AudioEditError.unreadable(url.lastPathComponent)
        }

        let format = audioFile.processingFormat
        guard audioFile.length > 0, format.channelCount > 0 else {
            throw AudioEditError.emptyAudio
        }

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)

        do {
            try newEngine.start()
        } catch {
            // Discard the half-built replacement; the current file is unaffected.
            newEngine.stop()
            newEngine.detach(newPlayer)
            throw AudioEditError.unreadable(url.lastPathComponent)
        }

        // ---- commit: the replacement is known-good --------------------------
        teardownEngine()
        engine = newEngine
        player = newPlayer
        file = audioFile
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        duration = Double(audioFile.length) / format.sampleRate
    }

    func unload() {
        teardownEngine()
        duration = 0
        channelCount = 0
    }

    /// Stops and releases the current engine, invalidating any pending completion
    /// handlers via the generation token.
    private func teardownEngine() {
        generation += 1
        loopQueuedPasses = 0
        player?.stop()
        engine?.stop()
        if let player, let engine {
            engine.detach(player)
        }
        player = nil
        engine = nil
        file = nil
    }

    // MARK: - Transport

    // MARK: - Scheduling a pass

    /// One element of a playback pass. A pass with no fades is a single
    /// `segment`; a faded pass is `[buffer head][segment middle][buffer tail]`.
    ///
    /// Exposed (rather than private) so the self test can inspect the exact
    /// audio that preview will play, which is the only way to verify an audible
    /// fade without an output device.
    enum PlaybackItem {
        case buffer(AVAudioPCMBuffer)
        case segment(startFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount)
    }

    /// Builds the ordered items for one pass of `[startFrame, startFrame + frameCount)`.
    ///
    /// With both fades at zero this is a single segment — the pre-fade path, which
    /// `G46` holds in place. When a fade is active the head and/or tail are read
    /// into PCM buffers and the envelope applied there, so memory is proportional
    /// to the *fade length*, not the selection.
    static func playbackItems(file: AVAudioFile,
                              startFrame: AVAudioFramePosition,
                              frameCount: AVAudioFramePosition,
                              fade: TrimmedAudioExporter.FadeSpec) -> [PlaybackItem] {
        guard frameCount > 0 else { return [] }

        let fades = TrimmedAudioExporter.fadeFrameCounts(fade,
                                                         sampleRate: file.processingFormat.sampleRate,
                                                         selectionFrames: frameCount)
        // No fades ⇒ exactly the old single-segment schedule. Not a segment of
        // equal size: the same call, so nothing about playback changes.
        guard fades.fadeIn > 0 || fades.fadeOut > 0 else {
            return [.segment(startFrame: startFrame, frameCount: AVAudioFrameCount(frameCount))]
        }

        var items: [PlaybackItem] = []
        if fades.fadeIn > 0,
           let head = fadedBuffer(file: file,
                                  readFrom: startFrame,
                                  bufferFrames: fades.fadeIn,
                                  selectionOffset: 0,
                                  fadeInFrames: fades.fadeIn,
                                  fadeOutFrames: fades.fadeOut,
                                  totalFrames: frameCount) {
            items.append(.buffer(head))
        }

        let middleFrames = frameCount - fades.fadeIn - fades.fadeOut
        if middleFrames > 0 {
            items.append(.segment(startFrame: startFrame + fades.fadeIn,
                                  frameCount: AVAudioFrameCount(middleFrames)))
        }

        if fades.fadeOut > 0,
           let tail = fadedBuffer(file: file,
                                  readFrom: startFrame + frameCount - fades.fadeOut,
                                  bufferFrames: fades.fadeOut,
                                  selectionOffset: frameCount - fades.fadeOut,
                                  fadeInFrames: fades.fadeIn,
                                  fadeOutFrames: fades.fadeOut,
                                  totalFrames: frameCount) {
            items.append(.buffer(tail))
        }

        // A failed read must not silently play an unfaded pass; fall back to the
        // plain segment so the audio is at least correct in extent.
        guard !items.isEmpty else {
            return [.segment(startFrame: startFrame, frameCount: AVAudioFrameCount(frameCount))]
        }
        return items
    }

    /// Reads `bufferFrames` frames and scales them by the shared envelope.
    private static func fadedBuffer(file: AVAudioFile,
                                    readFrom startFrame: AVAudioFramePosition,
                                    bufferFrames: AVAudioFramePosition,
                                    selectionOffset: AVAudioFramePosition,
                                    fadeInFrames: AVAudioFramePosition,
                                    fadeOutFrames: AVAudioFramePosition,
                                    totalFrames: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard bufferFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(bufferFrames)) else {
            return nil
        }
        file.framePosition = startFrame
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(bufferFrames))
        } catch {
            return nil
        }
        guard buffer.frameLength > 0 else { return nil }
        TrimmedAudioExporter.applyFade(to: buffer,
                                       offset: selectionOffset,
                                       fadeInFrames: fadeInFrames,
                                       fadeOutFrames: fadeOutFrames,
                                       totalFrames: totalFrames)
        return buffer
    }

    /// Starts playback of `start...end`, optionally looping the range.
    ///
    /// `fade` is applied to the *preview* audio. With both fades at zero this is
    /// byte-for-byte the original single-segment schedule.
    func play(from start: Double, to end: Double, looping: Bool,
              fade: TrimmedAudioExporter.FadeSpec = .none) {
        guard let player, let file else { return }

        generation += 1
        let token = generation
        loopQueuedPasses = 0

        player.stop()

        let startFrame = AVAudioFramePosition((max(0, start) * sampleRate).rounded())
        let endFrame = AVAudioFramePosition((max(start, end) * sampleRate).rounded())
        let frameCount = endFrame - startFrame
        guard frameCount > 0, startFrame < file.length else { return }

        segmentStartFrame = startFrame
        segmentEndFrame = endFrame
        isLooping = looping

        let items = Self.playbackItems(file: file,
                                       startFrame: startFrame,
                                       frameCount: frameCount,
                                       fade: fade)
        guard !items.isEmpty else { return }

        if looping {
            // Queue two passes and top the queue back up from each completed
            // pass, so the loop never drains even when a pass is short because
            // both fades are large fractions of the selection.
            schedulePass(token: token, items: items, looping: true)
            schedulePass(token: token, items: items, looping: true)
        } else {
            schedulePass(token: token, items: items, looping: false)
        }

        player.play()
    }

    /// Schedules every item of one pass. Only the last item carries a completion
    /// handler: it either re-arms the loop or reports the end of playback.
    private func schedulePass(token: Int, items: [PlaybackItem], looping: Bool) {
        guard let player, let file, generation == token, !items.isEmpty else { return }
        loopQueuedPasses += 1

        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            let callbackType: AVAudioPlayerNodeCompletionCallbackType =
                looping ? .dataRendered : .dataPlayedBack

            let handler: AVAudioPlayerNodeCompletionHandler? = isLast
                ? { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.loopQueuedPasses = max(0, self.loopQueuedPasses - 1)
                        if looping {
                            // Top the queue back up so two passes stay in flight.
                            if self.loopQueuedPasses < 2 {
                                self.schedulePass(token: token, items: items, looping: true)
                            }
                        } else {
                            self.onReachedEnd?()
                        }
                    }
                }
                : nil

            switch item {
            case .buffer(let buffer):
                if isLast {
                    player.scheduleBuffer(buffer,
                                          completionCallbackType: callbackType,
                                          completionHandler: handler)
                } else {
                    player.scheduleBuffer(buffer)
                }
            case .segment(let startFrame, let frameCount):
                if isLast {
                    player.scheduleSegment(file,
                                           startingFrame: startFrame,
                                           frameCount: frameCount,
                                           at: nil,
                                           completionCallbackType: callbackType,
                                           completionHandler: handler)
                } else {
                    player.scheduleSegment(file,
                                           startingFrame: startFrame,
                                           frameCount: frameCount,
                                           at: nil)
                }
            }
        }
    }

    func pause() {
        generation += 1
        loopQueuedPasses = 0
        player?.pause()
    }

    func stop() {
        generation += 1
        loopQueuedPasses = 0
        player?.stop()
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Current playback head in seconds, or `nil` when not playing.
    var currentTime: Double? {
        guard let player, player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }

        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let startTime = Double(segmentStartFrame) / sampleRate

        guard isLooping else { return startTime + elapsed }

        let segmentDuration = Double(segmentEndFrame - segmentStartFrame) / sampleRate
        guard segmentDuration > 0 else { return startTime }
        return startTime + elapsed.truncatingRemainder(dividingBy: segmentDuration)
    }
}
