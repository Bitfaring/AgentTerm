import Foundation
import XCTest

/// TEST-12 (#309): a run of UI tests in which nothing was checked is not
/// reported as passed by the scripts that run them.
final class TestScriptLogTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let library = repository.appendingPathComponent("scripts/lib-test-log.sh").path

    /// What `nothing_checked` says of a log: its words when nothing was
    /// checked, nil when something was.
    private func nothingChecked(_ log: String) throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("test-log-\(UUID().uuidString).log")
        try log.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$1\"; nothing_checked \"$2\"", "bash", Self.library, file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let words = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? words.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The end of a log of `swift test`, as XCTest writes it, with
    /// `executed` tests of which `skipped` skipped themselves.
    private func log(executed: Int, skipped: Int, reason: String = "run through scripts/screenshots.sh") -> String {
        var lines: [String] = []
        for index in 0..<executed {
            if index < skipped {
                lines.append("/tmp/Tests/X.swift:3: -[AgentTermMacUITests.X test\(index)] : Test skipped - \(reason)")
                lines.append("Test Case '-[AgentTermMacUITests.X test\(index)]' skipped (0.002 seconds).")
            } else {
                lines.append("Test Case '-[AgentTermMacUITests.X test\(index)]' passed (1.204 seconds).")
            }
        }
        let count = "\(executed) test\(executed == 1 ? "" : "s")"
        let with = skipped > 0 ? "with \(skipped) test\(skipped == 1 ? "" : "s") skipped and 0 failures" : "with 0 failures"
        for suite in ["X", "AgentTermPackageTests.xctest", "All tests"] {
            lines.append("Test Suite '\(suite)' passed at 2026-11-22 23:55:56.385.")
            lines.append("\t Executed \(count), \(with) (0 unexpected) in 0.002 (0.002) seconds")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What `swift test --filter` prints: each test bundle run on its own,
    /// in its own "Selected tests", the one with the test among bundles
    /// with none (as `test-both.sh` saw it on 2026-11-23).
    private func bundles(_ counts: [(name: String, executed: Int, skipped: Int)]) -> String {
        var lines: [String] = []
        for bundle in counts {
            let with = bundle.skipped > 0 ? "with \(bundle.skipped) tests skipped and 0 failures" : "with 0 failures"
            lines.append("Test Suite 'Selected tests' started at 2026-11-23 08:42:58.056.")
            lines.append("Test Suite '\(bundle.name).xctest' started at 2026-11-23 08:42:58.057.")
            if bundle.executed > 0 {
                lines.append("Test Suite 'CrossTests' passed at 2026-11-23 08:43:03.360.")
                lines.append("\t Executed \(bundle.executed) tests, \(with) (0 unexpected) in 5.084 (5.084) seconds")
            }
            lines.append("Test Suite '\(bundle.name).xctest' passed at 2026-11-23 08:43:03.360.")
            lines.append("\t Executed \(bundle.executed) tests, \(with) (0 unexpected) in 5.084 (5.084) seconds")
            lines.append("Test Suite 'Selected tests' passed at 2026-11-23 08:43:03.360.")
            lines.append("\t Executed \(bundle.executed) tests, \(with) (0 unexpected) in 5.084 (5.085) seconds")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// TEST-12: the bundles are added up, not the last one taken.
    func testEveryBundleOfARunIsCounted() throws {
        XCTAssertNil(try nothingChecked(bundles([("AgentTermTerminalTests", 0, 0), ("AgentTermMacUITests", 1, 0), ("AgentTermEditorTests", 0, 0)])))
        XCTAssertEqual(
            try nothingChecked(bundles([("AgentTermTerminalTests", 0, 0), ("AgentTermEditorTests", 0, 0)])), "no test was run")
        XCTAssertEqual(
            try nothingChecked(bundles([("AgentTermMacUITests", 2, 2), ("AgentTermEditorTests", 0, 0)])), "every test that was run skipped itself (2 of 2)")
    }

    func testARunWhereEveryTestSkippedItselfCheckedNothing() throws {
        XCTAssertEqual(try nothingChecked(log(executed: 3, skipped: 3)), "every test that was run skipped itself (3 of 3)")
        XCTAssertEqual(try nothingChecked(log(executed: 1, skipped: 1)), "every test that was run skipped itself (1 of 1)")
    }

    func testARunWithoutAccessibilityCheckedNothing() throws {
        let reason = "allow this terminal under System Settings > Privacy & Security > Accessibility"
        let words = try nothingChecked(log(executed: 5, skipped: 2, reason: reason))
        XCTAssertNotNil(words)
        XCTAssertTrue(words?.contains("Accessibility") ?? false, words ?? "")
    }

    func testARunOfNoTestCheckedNothing() throws {
        XCTAssertEqual(try nothingChecked("Build complete!\n"), "no test was run")
        XCTAssertEqual(try nothingChecked(log(executed: 0, skipped: 0)), "no test was run")
    }

    func testARunWhereSomeTestsPassedCheckedSomething() throws {
        XCTAssertNil(try nothingChecked(log(executed: 3, skipped: 0)))
        // The pictures' tests skip themselves when not run by their script:
        // the others of the run were checked all the same.
        XCTAssertNil(try nothingChecked(log(executed: 4, skipped: 1)))
        XCTAssertNil(try nothingChecked(log(executed: 1, skipped: 0)))
    }

    /// Each script that runs UI tests asks `nothing_checked` of every run it
    /// reports as passed. Before the fix `test-mac.sh` asked only whether a
    /// test was executed, `test-both.sh` and `screenshots.sh` nothing, and
    /// the modes of `test-ios.sh` that run one step nothing (#319).
    func testEveryScriptThatRunsUITestsAsksWhetherSomethingWasChecked() throws {
        for script in ["test-mac.sh", "test-both.sh", "screenshots.sh", "test-ios.sh"] {
            let text = try String(contentsOf: Self.repository.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
            XCTAssertTrue(text.contains("source scripts/lib-test-log.sh"), "\(script) does not source lib-test-log.sh")
            XCTAssertTrue(text.contains("nothing_checked \"$LOG\""), "\(script) does not ask nothing_checked of its log")
        }
    }

    /// TEST-15 (#319): `NARROW=only` narrows an iPad's window; on an iPhone
    /// the test returns at once, having checked nothing, so the script
    /// refuses it before building anything.
    func testNarrowOnlyOnAnIPhoneIsRefused() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let script = Self.repository.appendingPathComponent("scripts/test-ios.sh").path
        // Only the lines up to the refusal are run: past them the script builds.
        process.arguments = ["-c", "SIM_NAME='iPhone Air'; NARROW=only; eval \"$(sed -n '/^# NARROW=only is for an iPad/,/^fi$/p' \"$1\")\"; echo went-on", "bash", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let words = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0, words)
        XCTAssertFalse(words.contains("went-on"), words)
        XCTAssertTrue(words.contains("NARROW=only narrows an iPad's window"), words)
    }
}
