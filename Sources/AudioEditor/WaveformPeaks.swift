import AVFoundation
import Foundation

/// A downsampled min/max representation of an audio file, used to draw the waveform.
struct WaveformPeaks {
    /// Per-bucket minimum sample value in -1...1.
    let minima: [Float]
    /// Per-bucket maximum sample value in -1...1.
    let maxima: [Float]

    var bucketCount: Int { minima.count }

    static let empty = WaveformPeaks(minima: [], maxima: [])

    /// Reads the whole file and reduces it to `bucketCount` min/max pairs.
    ///
    /// Stereo (and multichannel) audio is mixed down to a single lane for display.
    /// Opens its own `AVAudioFile` so it can run off the main thread without
    /// contending with the playback file.
    static func analyze(url: URL, bucketCount requestedBuckets: Int = 12_000) throws -> WaveformPeaks {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw AudioEditError.unreadable(url.lastPathComponent)
        }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0, channels > 0 else {
            throw AudioEditError.emptyAudio
        }

        let buckets = max(1, min(requestedBuckets, Int(totalFrames)))
        let framesPerBucket = max(1, Int((Double(totalFrames) / Double(buckets)).rounded(.up)))

        var minima = [Float](repeating: 0, count: buckets)
        var maxima = [Float](repeating: 0, count: buckets)

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioEditError.emptyAudio
        }

        var bucket = 0
        var framesInBucket = 0
        var runningMin: Float = 0
        var runningMax: Float = 0
        var started = false

        // `AVAudioFile.read` throws a generic error when asked to read at EOF
        // rather than returning an empty buffer, so never over-request.
        var framesRemaining = totalFrames

        while framesRemaining > 0, bucket < buckets {
            let request = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), framesRemaining))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: request)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            framesRemaining -= AVAudioFramePosition(frames)
            guard let channelData = buffer.floatChannelData else {
                throw AudioEditError.unreadable(url.lastPathComponent)
            }

            for frame in 0..<frames {
                var mix: Float = 0
                for channel in 0..<channels {
                    mix += channelData[channel][frame]
                }
                mix /= Float(channels)

                if !started {
                    runningMin = mix
                    runningMax = mix
                    started = true
                } else {
                    if mix < runningMin { runningMin = mix }
                    if mix > runningMax { runningMax = mix }
                }

                framesInBucket += 1
                if framesInBucket >= framesPerBucket {
                    minima[bucket] = runningMin
                    maxima[bucket] = runningMax
                    bucket += 1
                    framesInBucket = 0
                    started = false
                    if bucket >= buckets { break }
                }
            }
        }

        // Flush any partially filled trailing bucket.
        if bucket < buckets, started {
            minima[bucket] = runningMin
            maxima[bucket] = runningMax
            bucket += 1
        }

        // If the file was shorter than expected, shrink to what we actually produced.
        if bucket < buckets {
            minima.removeLast(buckets - bucket)
            maxima.removeLast(buckets - bucket)
        }
        if bucket == 0 {
            minima = [0]
            maxima = [0]
        }

        // Guarantee a visible hairline for silent passages.
        for index in minima.indices where maxima[index] - minima[index] < 0.0015 {
            maxima[index] += 0.0008
            minima[index] -= 0.0008
        }

        return WaveformPeaks(minima: minima, maxima: maxima)
    }
}
