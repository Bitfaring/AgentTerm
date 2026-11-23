import AgentTermProtocol
import Darwin
import XCTest

@testable import AgentTermHost

/// #275 (review of 2026-11-22): a shell that has ended keeps the number of
/// its terminal's descriptor, which the system gives to the next thing
/// opened. What is still written to the ended shell, or asked of it, then
/// goes to that other thing.
final class ReviewCorePTYTests: XCTestCase {
    private let queue = DispatchQueue(label: "review.pty")

    private func start(_ script: String, output: @escaping (Data) -> Void = { _ in }, exit: @escaping () -> Void = {}) throws -> PTYProcess {
        var environment = OwnEnvironment.withoutAgentTerms
        environment["LC_ALL"] = "en_US.UTF-8"
        let process = try PTYProcess(executable: "/bin/sh", arguments: ["sh", "-c", script], environment: environment, cwd: "/tmp", size: .default, queue: queue)
        queue.sync {
            process.onOutput = output
            process.onExit = { _ in exit() }
        }
        return process
    }

    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(20_000) }
        return condition()
    }

    /// One shell ends; another is started, as the next session is; then
    /// something is written to the first, as the host's delayed steps of an
    /// answer or a paste still queued are. None of it reaches the second.
    func testWhatIsWrittenToAShellThatEndedNeverReachesAnotherShell() throws {
        var ended = false
        let first = try start("exit 0", exit: { ended = true })
        XCTAssertTrue(wait { self.queue.sync { ended } }, "the first shell did not end")
        // Its descriptor is closed once its reader is cancelled, on the queue.
        queue.sync {}
        usleep(100_000)
        var shown = Data()
        let second = try start("stty -echo; cat", output: { shown.append($0) })
        defer { kill(second.pid, SIGKILL) }
        usleep(300_000)
        let stray = "stray-275-typed-into-the-first"
        first.write(Data((stray + "\n").utf8))
        _ = wait(2) { self.queue.sync { String(decoding: shown, as: UTF8.self).contains(stray) } }
        let text = queue.sync { String(decoding: shown, as: UTF8.self) }
        XCTAssertFalse(text.contains(stray), "what was written to the shell that had ended was typed into the one started after it")
    }

    /// A shell that has ended has no program in front: it is never told the
    /// one of another shell that got its descriptor's number.
    func testAShellThatEndedSaysNoProgramIsInFront() throws {
        var ended = false
        let first = try start("exit 0", exit: { ended = true })
        XCTAssertTrue(wait { self.queue.sync { ended } }, "the first shell did not end")
        queue.sync {}
        usleep(100_000)
        let second = try start("exec sleep 600")
        defer { kill(second.pid, SIGKILL) }
        usleep(300_000)
        XCTAssertNil(first.foregroundCommand, "the shell that ended says the program in front of it is the other shell's")
    }
}
