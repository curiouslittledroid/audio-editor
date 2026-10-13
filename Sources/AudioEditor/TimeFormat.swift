import Foundation

enum TimeFormat {
    /// `0:04.312` / `1:02:07.500` — used for transport readouts and trim fields.
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.000" }
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, mins, secs, milliseconds)
        }
        return String(format: "%d:%02d.%03d", mins, secs, milliseconds)
    }

    /// `4.31s` / `1:02.1` — used for durations where millisecond precision is noise.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0.00s" }
        if seconds < 60 {
            return String(format: "%.2fs", seconds)
        }
        let totalTenths = Int((seconds * 10).rounded())
        let tenths = totalTenths % 10
        let totalSeconds = totalTenths / 10
        let secs = totalSeconds % 60
        let mins = totalSeconds / 60
        return String(format: "%d:%02d.%d", mins, secs, tenths)
    }

    /// Compact label for ruler ticks.
    static func rulerLabel(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    /// Byte count such as `4.2 MB`.
    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
