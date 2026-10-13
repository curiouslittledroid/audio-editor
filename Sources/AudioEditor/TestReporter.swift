import Foundation

/// Minimal pass/fail reporter shared by the self test and the UI check.
final class TestReporter {
    private(set) var failures = 0
    private var checks = 0

    func section(_ title: String) {
        print("\n=== \(title) ===")
    }

    func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        checks += 1
        let suffix = detail.isEmpty ? "" : "  — \(detail)"
        if condition {
            print("  ok    \(label)\(suffix)")
        } else {
            failures += 1
            print("  FAIL  \(label)\(suffix)")
        }
    }

    /// Prints the summary and returns the process exit code.
    func finish() -> Int32 {
        print("")
        if failures == 0 {
            print("ALL \(checks) CHECKS PASSED")
            return 0
        }
        print("\(failures) OF \(checks) CHECKS FAILED")
        return 1
    }
}

/// Parses `0.5-1.5,3.0-3.4` into time ranges.
func parseRanges(_ raw: String) -> [(Double, Double)] {
    raw.split(separator: ",").compactMap { piece in
        let parts = piece.split(separator: "-").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > parts[0] else { return nil }
        return (parts[0], parts[1])
    }
}
