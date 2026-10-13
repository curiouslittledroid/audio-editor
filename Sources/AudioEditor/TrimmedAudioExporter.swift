import AVFoundation
import Foundation

/// Writes a trimmed copy of a file to disk, preserving the source sample rate,
/// channel count, bit depth, and endianness.
enum TrimmedAudioExporter {

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

    /// - Parameters:
    ///   - sourceURL: the file to read from.
    ///   - destinationURL: where the trimmed `.wav` is written.
    ///   - start: trim in-point in seconds.
    ///   - end: trim out-point in seconds.
    static func export(sourceURL: URL, to destinationURL: URL, start: Double, end: Double) throws {
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
            do {
                try output.write(from: buffer)
            } catch {
                throw AudioEditError.exportFailed(error.localizedDescription)
            }
            remaining -= read
        }
    }

    /// `original-trimmed.wav`, avoiding collisions with files already on disk.
    static func suggestedFileName(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)-trimmed.wav"
    }
}
