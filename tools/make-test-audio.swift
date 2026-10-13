// Generates .wav fixtures used to exercise the editor by hand.
// Build & run:  swift tools/make-test-audio.swift
import AVFoundation
import Foundation

func writeWAV(path: String, sampleRate: Double, channels: AVAudioChannelCount,
              bitDepth: Int, duration: Double,
              sample: (Int, Double) -> [Float]) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channels),
        AVLinearPCMBitDepthKey: bitDepth,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat

    let total = Int(sampleRate * duration)
    let chunk = 4096
    var frame = 0
    while frame < total {
        let count = min(chunk, total - frame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(count)) else { break }
        buffer.frameLength = AVAudioFrameCount(count)
        guard let data = buffer.floatChannelData else { break }
        for i in 0..<count {
            let values = sample(frame + i, sampleRate)
            for channel in 0..<Int(channels) {
                data[channel][i] = values[min(channel, values.count - 1)]
            }
        }
        try file.write(from: buffer)
        frame += count
    }
    print("wrote \(path)  (\(TimeFormat.durationLike(duration)))")
}

enum TimeFormat {
    static func durationLike(_ s: Double) -> String { String(format: "%.2fs", s) }
}

let outDir = "TestAudio"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// 1. Three short bursts separated by silence — makes trim points obvious.
try writeWAV(path: "\(outDir)/bursts-44100-stereo16.wav", sampleRate: 44_100, channels: 2,
             bitDepth: 16, duration: 6.0) { frame, sr in
    let t = Double(frame) / sr
    let inBurst: Bool
    switch t {
    case 0.5..<1.5: inBurst = true      // first burst
    case 3.0..<3.4: inBurst = true      // short middle burst
    case 4.5..<5.8: inBurst = true      // long final burst
    default: inBurst = false
    }
    guard inBurst else { return [0, 0] }
    let envelope = 0.6
    let left = Float(sin(2 * .pi * 440 * t) * envelope)
    let right = Float(sin(2 * .pi * 660 * t) * envelope)
    return [left, right]
}

// 2. Continuous sweep — good for checking the ruler and playhead.
try writeWAV(path: "\(outDir)/sweep-48000-mono24.wav", sampleRate: 48_000, channels: 1,
             bitDepth: 24, duration: 12.0) { frame, sr in
    let t = Double(frame) / sr
    let freq = 200 + (t / 12.0) * 3000
    let amplitude = 0.7 * (1.0 - t / 24.0)
    return [Float(sin(2 * .pi * freq * t) * amplitude)]
}

// 3. Very short file — edge case for handle spacing and ruler ticks.
try writeWAV(path: "\(outDir)/blip-44100-mono16.wav", sampleRate: 44_100, channels: 1,
             bitDepth: 16, duration: 0.35) { frame, sr in
    let t = Double(frame) / sr
    return [Float(sin(2 * .pi * 1000 * t) * 0.8)]
}

// 4. Longer stereo file — checks waveform analysis speed and zoomed-out detail.
try writeWAV(path: "\(outDir)/long-44100-stereo16.wav", sampleRate: 44_100, channels: 2,
             bitDepth: 16, duration: 180.0) { frame, sr in
    let t = Double(frame) / sr
    let beat = 0.5 + 0.5 * sin(2 * .pi * 2.0 * t)
    let tone = sin(2 * .pi * 220 * t)
    let value = Float(tone * beat * 0.7)
    return [value, value * 0.85]
}

// ---------------------------------------------------------------------------
// Intentionally invalid inputs, used to prove that a refused open leaves the
// current document untouched (docs/specs/SPEC.md G4). These live in a subdirectory so the
// `TestAudio/*.wav` glob in selftest.sh never feeds them to the analyser.
// ---------------------------------------------------------------------------

let invalidDir = "\(outDir)/invalid"
try? FileManager.default.createDirectory(atPath: invalidDir, withIntermediateDirectories: true)

// Right extension, undecodable content.
let corrupt = "\(invalidDir)/corrupt.wav"
try? Data(String(repeating: "this is not audio\n", count: 200).utf8).write(to: URL(fileURLWithPath: corrupt))
print("wrote \(corrupt)  (intentionally undecodable)")

// Wrong extension entirely.
let notAudio = "\(invalidDir)/notes.txt"
try? Data("plain text, not audio\n".utf8).write(to: URL(fileURLWithPath: notAudio))
print("wrote \(notAudio)  (unsupported extension)")
