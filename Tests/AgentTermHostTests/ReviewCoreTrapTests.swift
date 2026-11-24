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
