import AgentTermClient
import AgentTermHost
import AgentTermProtocol
import XCTest

/// REMOTE-34 (#289): a message a client sends that is larger than a frame
/// may be goes in pieces and is joined by the host, as the host's own large
/// messages are (#21): a text of more than 4 MB, opened anyway and edited
/// on the iPhone, is saved, and the connection is not lost.
final class LargeMessagesTests: XCTestCase {
    private let token = "test-token-0123456789abcdef0123456789"

    private var server: HostServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        port = try server.start()
    }

    override func tearDown() { server.stop() }

    private func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    func testATextOfMoreThanFourMegabytesIsSavedFromAClient() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-large-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("big.txt").path
        try "small\n".write(toFile: path, atomically: true, encoding: .utf8)

        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
        var messages: [ServerMessage] = []
        var state: AgentTermConnection.State = .connecting
        client.onMessage = { messages.append($0) }
        client.onState = { state = $0 }
        client.connect()
        defer { client.close() }
        waitUntil("welcome") { messages.contains { if case .welcome = $0 { return true } else { return false } } }

        // 6 MB of text, more than the 4 MB a frame may be.
        let line = String(repeating: "đây là một dòng dài ", count: 4) + "\n"
        let text = String(repeating: line, count: 6 * 1024 * 1024 / line.utf8.count + 1)
        XCTAssertGreaterThan(text.utf8.count, 6 * 1024 * 1024)
        client.send(.writeFile(path: path, text: text))
        waitUntil("saved") { messages.contains(.fileSaved(path: path)) || { if case .closed = state { return true } else { return false } }() }
        if case .closed(let reason) = state { XCTFail("the connection was lost: \(reason ?? "no reason")") }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
    }

    /// A connected client and what it was sent.
    private func connect() -> (AgentTermConnection, () -> [ServerMessage], () -> Bool) {
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        var messages: [ServerMessage] = []
        var closed = false
        client.onMessage = { messages.append($0) }
        client.onState = { if case .closed = $0 { closed = true } }
        client.connect()
        waitUntil("welcome") { messages.contains { if case .welcome = $0 { return true } else { return false } } }
        return (client, { messages }, { closed })
    }

    /// A page's picture of more than 4 MB, a Mac's answer to an agent
    /// (`browserReply`), reaches the host without losing the connection.
    func testABrowserPicturesAnswerOfMoreThanFourMegabytesDoesNotCloseTheConnection() throws {
        let (client, messages, closed) = connect()
        defer { client.close() }
        client.send(.browserReply(id: 1, result: .image(png: Data(repeating: 0x89, count: 5 * 1024 * 1024), text: "a page")))
        // A question after it is answered: the connection is still there.
        client.send(.files(path: "/"))
        waitUntil("answered after it") { closed() || messages().contains { if case .files("/", _) = $0 { return true } else { return false } } }
        XCTAssertFalse(closed(), "the connection was lost")
    }

    /// A message larger than the host joins is refused in words, its
    /// pieces left, and the connection goes on.
    func testAMessageLargerThanTheHostJoinsIsRefusedInWords() throws {
        let (client, messages, closed) = connect()
        defer { client.close() }
        let text = String(repeating: "x", count: MessageParts.largestFromAClient + 1024)
        client.send(.writeFile(path: "/tmp/agentterm-never-written-\(UUID().uuidString)", text: text))
        client.send(.files(path: "/"))
        waitUntil("refused, then answered", timeout: 60) { closed() || messages().contains { if case .files("/", _) = $0 { return true } else { return false } } }
        XCTAssertFalse(closed(), "the connection was lost")
        XCTAssertTrue(messages().contains(.error(HostErrorWords.tooLargeMessage)), "not refused in words")
        XCTAssertEqual(HostErrorWords.words(for: HostErrorWords.tooLargeMessage), HostErrorWords.tooLarge)
    }
}
