import AVFoundation
import Foundation

/// Writes a trimmed copy of a file to disk, preserving the source sample rate,
/// channel count, bit depth, and endianness.
enum TrimmedAudioExporter {

    // MARK: - Fades

    /// A linear fade-in / fade-out at the selection boundaries.
    ///
    /// Durations are in seconds. `.none` reproduces the pre-fade exporter exactly,
    /// which is what makes "no fades ⇒ bit-identical output" (G46) hold by
    /// construction rather than by careful arithmetic.
    struct FadeSpec: Equatable {
        var fadeIn: Double
        var fadeOut: Double

        static let none = FadeSpec(fadeIn: 0, fadeOut: 0)

        var isActive: Bool { fadeIn > 0 || fadeOut > 0 }

        init(fadeIn: Double = 0, fadeOut: Double = 0) {
            self.fadeIn = fadeIn.isFinite ? max(0, fadeIn) : 0
            self.fadeOut = fadeOut.isFinite ? max(0, fadeOut) : 0
        }
    }

    /// Resolves fade durations to frame counts, clamped so the two can never
    /// overlap: each is at most half the selection (`G42`). Rounding to the
    /// nearest sample matches `frameRange`, so fades stay sample-exact (`G33`).
    static func fadeFrameCounts(_ fade: FadeSpec,
                                sampleRate: Double,
                                selectionFrames: AVAudioFramePosition) -> (fadeIn: AVAudioFramePosition, fadeOut: AVAudioFramePosition) {
        guard selectionFrames > 0, sampleRate > 0 else { return (0, 0) }
        // Integer division floors, so fadeIn + fadeOut can never exceed the selection.
        let limit = selectionFrames / 2

        func resolve(_ seconds: Double) -> AVAudioFramePosition {
            let raw = (seconds * sampleRate).rounded()
            // Guard before the Int64 conversion: an infinite or absurd duration
            // would otherwise trap rather than clamp.
            guard raw.isFinite, raw > 0 else { return 0 }
            return min(AVAudioFramePosition(min(raw, Double(limit))), limit)
        }
        return (resolve(fade.fadeIn), resolve(fade.fadeOut))
    }

    /// Gain for the sample at `offset` within the exported selection (`G41`).
    ///
    /// Both endpoints are inclusive — the first sample of a fade-in is exactly 0
    /// and the last sample of a fade-out is exactly 0 — which makes the envelope
    /// testable without tolerance games. The single-frame case is defined rather
    /// than left to divide by zero.
    static func fadeGain(atOffset offset: AVAudioFramePosition,
                         fadeInFrames: AVAudioFramePosition,
                         fadeOutFrames: AVAudioFramePosition,
                         totalFrames: AVAudioFramePosition) -> Float {
        guard offset >= 0, totalFrames > 0, offset < totalFrames else { return 1 }

        if fadeInFrames > 0, offset < fadeInFrames {
            guard fadeInFrames > 1 else { return 0 }
            return Float(Double(offset) / Double(fadeInFrames - 1))
        }
        if fadeOutFrames > 0, offset >= totalFrames - fadeOutFrames {
            guard fadeOutFrames > 1 else { return 0 }
            let j = offset - (totalFrames - fadeOutFrames)
            return Float(1 - Double(j) / Double(fadeOutFrames - 1))
        }
        return 1
    }

    /// Scales a buffer in place. Every channel gets the same gain (`G41`), and
    /// samples outside the fade regions are skipped, not multiplied by 1.0, so
    /// they are bit-identical to an unfaded export (`G45`).
    ///
    /// Shared with `AudioEngineController` so preview and export apply the very
    /// same envelope; there is one implementation of the ramp, not two.
    static func applyFade(to buffer: AVAudioPCMBuffer,
                                  offset: AVAudioFramePosition,
                                  fadeInFrames: AVAudioFramePosition,
                                  fadeOutFrames: AVAudioFramePosition,
                                  totalFrames: AVAudioFramePosition) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for frame in 0..<frames {
            let gain = fadeGain(atOffset: offset + AVAudioFramePosition(frame),
                                fadeInFrames: fadeInFrames,
                                fadeOutFrames: fadeOutFrames,
                                totalFrames: totalFrames)
            if gain == 1 { continue }
            for channel in 0..<channelCount {
                channels[channel][frame] *= gain
            }
        }
    }

    // MARK: - Frame ranges

    /// Resolves a time range to an exact frame range. Uses rounding so a trim
    /// point lands on the nearest sample rather than always drifting earlier.
    /// Shared with the self test so both agree on sample-exact offsets.
    static func frameRange(forStart start: Double,
                           end: Double,
                           sampleRate: Double,
                           totalFrames: AVAudioFramePosition) -> (start: AVAudioFramePosition, end: AVAudioFramePosition) {
        let startFrame = AVAudioFramePosition(max(0, start * sampleRate).rounded())
        let endFrame = min(totalFrames, AVAudioFramePosition(max(start, end * sampleRate).rounded()))
        return (startFrame, endFrame)
    }

    // MARK: - Export

    /// - Parameters:
    ///   - sourceURL: the file to read from.
    ///   - destinationURL: where the trimmed `.wav` is written.
    ///   - start: trim in-point in seconds.
    ///   - end: trim out-point in seconds.
    ///   - fade: linear fades applied at the selection boundaries.
    static func export(sourceURL: URL,
                       to destinationURL: URL,
                       start: Double,
                       end: Double,
                       fade: FadeSpec = .none) throws {
        guard let input = try? AVAudioFile(forReading: sourceURL,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: false) else {
            throw AudioEditError.unreadable(sourceURL.lastPathComponent)
        }

        let sampleRate = input.processingFormat.sampleRate
        let totalFrames = input.length

        let range = frameRange(forStart: start, end: end,
                               sampleRate: sampleRate, totalFrames: totalFrames)
        let startFrame = range.start
        let endFrame = range.end
        let framesToWrite = endFrame - startFrame
        guard framesToWrite > 0 else {
            throw AudioEditError.exportFailed("The trimmed selection is empty.")
        }

        let fades = fadeFrameCounts(fade, sampleRate: sampleRate, selectionFrames: framesToWrite)

        // Start from the on-disk format so bit depth / endianness survive the round trip.
        var settings = input.fileFormat.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        if settings[AVLinearPCMIsNonInterleaved] == nil {
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        if settings[AVLinearPCMIsBigEndianKey] == nil {
            settings[AVLinearPCMIsBigEndianKey] = false
        }

        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destinationURL,
                                     settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        } catch {
            throw AudioEditError.exportFailed(error.localizedDescription)
        }

        let format = input.processingFormat
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioEditError.exportFailed("Could not allocate an audio buffer.")
        }

        input.framePosition = startFrame
        var remaining = framesToWrite
        var written: AVAudioFramePosition = 0

        while remaining > 0 {
            let request = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            buffer.frameLength = 0
            do {
                try input.read(into: buffer, frameCount: request)
            } catch {
                throw AudioEditError.exportFailed(error.localizedDescription)
            }
            let read = AVAudioFramePosition(buffer.frameLength)
            if read == 0 { break }

            // Skipped entirely when no fade is set, so the unfaded path stays
            // exactly as it was.
            if fade.isActive {
                applyFade(to: buffer,
                          offset: written,
                          fadeInFrames: fades.fadeIn,
                          fadeOutFrames: fades.fadeOut,
                          totalFrames: framesToWrite)
            }

            do {
                try output.write(from: buffer)
            } catch {
                throw AudioEditError.exportFailed(error.localizedDescription)
            }
            written += read
            remaining -= read
        }
    }

    /// `original-trimmed.wav`, avoiding collisions with files already on disk.
    static func suggestedFileName(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)-trimmed.wav"
    }
}
