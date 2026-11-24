import AgentTermClient
import AgentTermProtocol
import Network
import XCTest

/// REMOTE-33 (#292): a message from the host that a client cannot read is
/// said, once a connection, rather than dropped without a word; what comes
/// after it is read as ever.
final class ClientUnreadableTests: XCTestCase {
    func testAMessageThatCannotBeReadIsSaidOnce() throws {
        let webSocket = NWProtocolWebSocket.Options()
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "unreadable.host")
        func send(_ connection: NWConnection, _ data: Data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            connection.send(content: data, contentContext: .init(identifier: "m", metadata: [metadata]), completion: .idempotent)
        }
        // A host that sends two messages no client can read, then one it can.
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            send(connection, Data(#"{"aMessageOfNoKind":{}}"#.utf8))
            send(connection, Data("not even JSON".utf8))
            send(connection, MessageCoding.encode(ServerMessage.error("after")))
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token("t"), clientName: "phone")
        var errors: [String] = []
        client.onMessage = { if case .error(let text, _) = $0 { errors.append(text) } }
        client.connect()
        defer { client.close() }
        let deadline = Date().addingTimeInterval(5)
        while !errors.contains("after"), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(errors, [HostErrorWords.unreadableMessage, "after"])
        XCTAssertEqual(HostErrorWords.words(for: HostErrorWords.unreadableMessage), HostErrorWords.unreadable)
    }
}
