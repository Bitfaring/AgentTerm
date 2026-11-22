import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import Network
import XCTest

/// HOST-14 (#214): right after an update the app talks to the host it found
/// running, which is of the release before. It is sent nothing it does not
/// have, so it answers no "malformed message" for the app to show.
final class EarlierHostTests: XCTestCase {
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"

    private func start(protocolVersion: Int) throws {
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] })
        configuration.protocolVersion = protocolVersion
        server = HostServer(configuration: configuration)
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Connects, sends each message once the host has greeted, then asks
    /// for the agents, whose answer says the host has read all before it.
    private func answers(to messages: [ClientMessage]) -> [ServerMessage] {
        var received: [ServerMessage] = []
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, token: token, clientName: "Mac", kind: .mac)
        connection.onMessage = { received.append($0) }
        connection.connect()
        waitUntil("welcome") { received.contains { if case .welcome = $0 { return true } else { return false } } }
        let greeted = received.count
        for message in messages { connection.send(message) }
        connection.send(.agents(refresh: false))
        waitUntil("the agents") { received.dropFirst(greeted).contains { if case .agents = $0 { return true } else { return false } } }
        connection.close()
        return Array(received.dropFirst(greeted))
    }

    func testWhatAnEarlierHostDoesNotHaveIsNotSentToIt() throws {
        try start(protocolVersion: 32)
        let answers = answers(to: [.readNotices(ids: [1]), .deviceInBackground(false)])
        XCTAssertFalse(answers.contains(.error("malformed message")), "the host of an earlier release was sent what it does not have")
    }

    /// The same messages reach a host of this release.
    func testAHostOfThisReleaseIsSentAll() throws {
        try start(protocolVersion: agenttermProtocolVersion)
        XCTAssertTrue(ClientMessage.readNotices(ids: [1]).isKnown(toHostAt: agenttermProtocolVersion))
        XCTAssertTrue(ClientMessage.deviceInBackground(false).isKnown(toHostAt: agenttermProtocolVersion))
        XCTAssertFalse(ClientMessage.readNotices(ids: [1]).isKnown(toHostAt: 32))
        XCTAssertFalse(ClientMessage.deviceInBackground(false).isKnown(toHostAt: 35))
        XCTAssertTrue(ClientMessage.agents(refresh: false).isKnown(toHostAt: 1))
        let answers = answers(to: [.readNotices(ids: [1]), .deviceInBackground(false)])
        XCTAssertFalse(answers.contains(.error("malformed message")))
    }
}
