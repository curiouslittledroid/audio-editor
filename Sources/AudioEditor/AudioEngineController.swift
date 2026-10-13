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

    /// Starts playback of `start...end`, optionally looping the range.
    func play(from start: Double, to end: Double, looping: Bool) {
        guard let player, let file else { return }

        generation += 1
        let token = generation

        player.stop()

        let startFrame = AVAudioFramePosition((max(0, start) * sampleRate).rounded())
        let endFrame = AVAudioFramePosition((max(start, end) * sampleRate).rounded())
        let frameCount = endFrame - startFrame
        guard frameCount > 0, startFrame < file.length else { return }

        segmentStartFrame = startFrame
        segmentEndFrame = endFrame
        isLooping = looping

        let frames = AVAudioFrameCount(frameCount)

        if looping {
            // `scheduleSegment` has no `.loops` option, so queue two copies and
            // top the queue back up from each completion handler. Keeping one
            // segment queued ahead makes the loop gapless.
            scheduleLoopingSegment(token: token, startFrame: startFrame, frameCount: frames)
            scheduleLoopingSegment(token: token, startFrame: startFrame, frameCount: frames)
        } else {
            player.scheduleSegment(file,
                                   startingFrame: startFrame,
                                   frameCount: frames,
                                   at: nil,
                                   completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.onReachedEnd?()
                }
            }
        }

        player.play()
    }

    /// Schedules one pass of the loop and re-arms itself once that pass is
    /// handed to the output, so the queue never drains.
    private func scheduleLoopingSegment(token: Int,
                                        startFrame: AVAudioFramePosition,
                                        frameCount: AVAudioFrameCount) {
        guard let player, let file, generation == token else { return }
        player.scheduleSegment(file,
                               startingFrame: startFrame,
                               frameCount: frameCount,
                               at: nil,
                               completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.scheduleLoopingSegment(token: token,
                                            startFrame: startFrame,
                                            frameCount: frameCount)
            }
        }
    }

    func pause() {
        generation += 1
        player?.pause()
    }

    func stop() {
        generation += 1
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
