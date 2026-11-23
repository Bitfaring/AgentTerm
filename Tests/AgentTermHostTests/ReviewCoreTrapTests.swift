import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// #271 (review of 2026-11-22): a number out of range in a message from a
/// client that signed in. The host answers or refuses; it never stops, and
/// every session with it. Each case runs in a process of its own
/// (`ReviewCoreTrapCases`), since the fault stops the process it happens in.
final class ReviewCoreTrapTests: XCTestCase {
    private func survives(_ test: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try ReviewCore.runAlone(test, in: ReviewCoreTrapCases.self)
        XCTAssertFalse(run.crashed, "the host's process was stopped (signal \(run.status)):\n\(ReviewCore.crashLines(run.said))", file: file, line: line)
        XCTAssertEqual(run.status, 0, ReviewCore.crashLines(run.said), file: file, line: line)
    }

    func testAttachingWithACountOutOfRangeDoesNotStopTheHost() throws { try survives("testAttachingWithACountOutOfRange") }
    func testAskingForAMinusNumberOfLinesOfACommandDoesNotStopTheHost() throws { try survives("testAskingForAMinusNumberOfLinesOfACommand") }
    func testAskingForARunsOutputAtADateOutOfRangeDoesNotStopTheHost() throws { try survives("testAskingForARunsOutputAtADateOutOfRange") }
}

/// The cases themselves, each run alone by a test above or by hand with
/// `AGENTTERM_REVIEW_TRAPS=1`; skipped otherwise, so that the rest of the
/// tests still run (#271, #249).
final class ReviewCoreTrapCases: XCTestCase {
    private var folder: ReviewCore.Folder!
    private var server: HostServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        try XCTSkipUnless(ReviewCore.runsTraps, "stops the process: #271 and #249, run alone with \(ReviewCore.trapsVariable)=1")
        folder = try ReviewCore.Folder("trap")
    }

    override func tearDown() {
        server?.stop()
        folder?.remove()
    }

    private func start(_ configuration: HostServer.Configuration) throws -> ReviewCore.Client {
        server = HostServer(configuration: configuration)
        port = try server.start()
        let client = ReviewCore.Client(port: port, name: "mac")
        XCTAssertTrue(ReviewCore.spin { client.welcomed }, "the client was not welcomed")
        return client
    }

    /// Whether the host still answers: it is asked for its sessions again.
    private func stillAnswers(_ client: ReviewCore.Client) -> Bool {
        let before = client.messages.filter { if case .sessions = $0 { return true } else { return false } }.count
        client.connection.send(.list)
        return ReviewCore.spin(5) { client.messages.filter { if case .sessions = $0 { return true } else { return false } }.count > before }
    }

    func testAttachingWithACountOutOfRange() throws {
        let client = try start(folder.configuration())
        defer { client.connection.close() }
        client.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: folder.root.path, title: "kept")))
        XCTAssertTrue(ReviewCore.spin { client.attached != nil }, "no session")
        let session = try XCTUnwrap(client.attached).id
        client.connection.send(.attach(session: session, size: .default, have: Int.min))
        XCTAssertTrue(stillAnswers(client), "the host no longer answers")
        client.connection.send(.kill(session: session))
    }

    func testAskingForAMinusNumberOfLinesOfACommand() throws {
        // A stand-in agent that says what its session's key is.
        let agents = folder.root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let key = folder.root.appendingPathComponent("key")
        try "#!/bin/sh\nprintf '%s' \"$AGENTTERM_MCP\" > '\(key.path).new'; mv '\(key.path).new' '\(key.path)'\nexec sleep 600\n".write(
            to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        var configuration = folder.configuration()
        configuration.detectAgents = { AgentDetector.detect(in: agents.path) }
        configuration.agentsDirectory = agents.path
        let client = try start(configuration)
        defer { client.connection.close() }
        client.connection.send(.create(CreateRequest(command: "claude", cwd: folder.root.path)))
        XCTAssertTrue(ReviewCore.spin(15) { FileManager.default.fileExists(atPath: key.path) }, "the agent's session did not start")
        let agent = try XCTUnwrap(AgentShellsMCP.Session(variable: try String(contentsOf: key, encoding: .utf8)))
        client.connection.send(.agentShell(id: 1, key: agent.key, request: .open(command: nil, title: "its shell")))
        var shell: SessionID?
        XCTAssertTrue(
            ReviewCore.spin(15) {
                shell = client.messages.compactMap { if case .agentShellResult(1, .opened(let info)) = $0 { return info.id } else { return nil } }.last
                return shell != nil
            }, "the agent's shell was not opened: \(client.messages.compactMap { if case .agentShellResult(_, let result) = $0 { return result } else { return nil } })")
        // A command is run in it first: only a shell that has printed
        // something has lines to count.
        let id = try XCTUnwrap(shell)
        var ran = false
        for attempt in 0..<20 where !ran {
            client.connection.send(.agentShell(id: 100 + attempt, key: agent.key, request: .run(session: id, command: "echo review-271")))
            ReviewCore.spin(1) { client.messages.contains { if case .agentShellResult(100 + attempt, _) = $0 { return true } else { return false } } }
            ran = client.messages.contains { if case .agentShellResult(100 + attempt, .ran) = $0 { return true } else { return false } }
        }
        XCTAssertTrue(ran, "the command was not typed: \(client.messages.compactMap { if case .agentShellResult(_, let result) = $0 { return result } else { return nil } }.suffix(2))")
        var printed = false
        for attempt in 0..<20 where !printed {
            client.connection.send(.agentShell(id: 200 + attempt, key: agent.key, request: .command(session: id, lines: 5)))
            ReviewCore.spin(1) { client.messages.contains { if case .agentShellResult(200 + attempt, _) = $0 { return true } else { return false } } }
            printed = client.messages.contains { if case .agentShellResult(200 + attempt, .command(let state)) = $0 { return state.output.contains("review-271") } else { return false } }
        }
        XCTAssertTrue(printed, "the shell's command printed nothing the host kept")
        client.connection.send(.agentShell(id: 2, key: agent.key, request: .command(session: id, lines: -1)))
        XCTAssertTrue(ReviewCore.spin(5) { client.messages.contains { if case .agentShellResult(2, _) = $0 { return true } else { return false } } }, "no answer")
        XCTAssertTrue(stillAnswers(client), "the host no longer answers")
    }

    func testAskingForARunsOutputAtADateOutOfRange() throws {
        let client = try start(folder.configuration())
        defer { client.connection.close() }
        client.connection.send(.scheduleRunOutput(id: "no-such-schedule", at: Date(timeIntervalSince1970: 1e300)))
        XCTAssertTrue(stillAnswers(client), "the host no longer answers")
    }

    /// #249: the request `browser_emulate` makes of a width no screen has.
    func testEmulatingAWidthOutOfRange() {
        switch AgentShellsMCP.browserRequest("browser_emulate", ["tab": "1", "width": 1e30, "height": 800]) {
        case .failure(let refusal): XCTAssertFalse(refusal.text.isEmpty)
        case .success(let request): XCTFail("neither refused nor stopped: \(request)")
        }
    }
}
