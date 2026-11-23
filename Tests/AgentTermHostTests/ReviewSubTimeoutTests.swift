import XCTest

@testable import AgentTermHost

/// #261 (review of 2026-11-22): the time limit of a command the host runs
/// holds, whatever the command does with the signal and whoever else holds
/// its output. Every command here ends by itself within 12 seconds, so a
/// test that fails leaves nothing running.
final class ReviewSubTimeoutTests: XCTestCase {
    private let limit: TimeInterval = 5

    /// #261: a child of the command keeps the pipe open after the command
    /// itself was stopped (a hook or a startup file that leaves a program
    /// in the background).
    func testTheLimitHoldsWhenAChildKeepsTheOutputOpen() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "/bin/sleep 12 & wait"], timeout: 0.5))
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertLessThan(took, limit, "a command given half a second was waited for \(Int(took)) seconds")
    }

    /// #261: the command does not end at SIGTERM (a login shell still in
    /// its startup files does not).
    func testTheLimitHoldsWhenTheCommandDoesNotEndAtTheSignal() throws {
        let started = Date()
        let result = try XCTUnwrap(Subprocess.run("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 12"], timeout: 0.5))
        let took = Date().timeIntervalSince(started)
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertLessThan(took, limit, "a command given half a second was waited for \(Int(took)) seconds")
    }

    private func relayTakes(_ command: String) throws -> TimeInterval {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = root.appendingPathComponent("previous-status-line.json")
        try JSONSerialization.data(withJSONObject: ["type": "command", "command": command]).write(to: previous)
        let started = Date()
        _ = StatusLineRelay.run(input: Data(#"{"cwd":"/tmp"}"#.utf8), file: nil, previous: previous, home: root.path, environment: [:])
        return Date().timeIntervalSince(started)
    }

    /// #261 (the status line relay): its 5 seconds hold for a status line
    /// that is a pipeline, whose programs keep the output open after the
    /// shell was stopped. (Seen to pass on 2026-11-23: Foundation's
    /// `terminate` reaches the pipeline's programs too.)
    func testTheStatusLineRelaysLimitHoldsForAPipeline() throws {
        let took = try relayTakes("/bin/sleep 12 | /bin/cat")
        XCTAssertLessThan(took, 8, "a status line limited to 5 seconds was waited for \(Int(took)) seconds")
    }

    /// #261 (the status line relay): its 5 seconds hold for a status line
    /// that does not end at SIGTERM.
    func testTheStatusLineRelaysLimitHoldsWhenTheStatusLineDoesNotEndAtTheSignal() throws {
        let took = try relayTakes("trap '' TERM; /bin/sleep 12")
        XCTAssertLessThan(took, 8, "a status line limited to 5 seconds was waited for \(Int(took)) seconds")
    }

    /// #261 (the status line relay): and for one that leaves a program of
    /// its own session behind, holding the output.
    func testTheStatusLineRelaysLimitHoldsWhenAProgramIsLeftBehind() throws {
        let took = try relayTakes("/usr/bin/perl -e 'use POSIX; setsid(); sleep 12' & wait")
        XCTAssertLessThan(took, 8, "a status line limited to 5 seconds was waited for \(Int(took)) seconds")
    }
}
