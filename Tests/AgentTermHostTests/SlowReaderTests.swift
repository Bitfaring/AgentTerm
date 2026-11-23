import AgentTermProtocol
import Network
import XCTest

@testable import AgentTermHost

/// REMOTE-35 (#270): a client that signed in and does not read, as an
/// iPhone suspended with its connection open, does not make the host keep
/// without bound what it sends it; once it reads again it gets all it
/// missed of the session, nothing twice.
final class SlowReaderTests: XCTestCase {
    private let token = "test-token-0123456789abcdef0123456789"

    func testAClientThatDoesNotReadIsNotKeptForWithoutBoundAndGetsAllOnceItReads() throws {
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] })
        // All of what is printed stays in the scrollback, so that what is
        // missed is sent as it was, and can be counted.
        configuration.scrollbackLimit = 64 * 1024 * 1024
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = 4 * 1024 * 1024
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
        let queue = DispatchQueue(label: "slow.reader")
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        connection.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        defer { connection.cancel() }
        func send(_ message: ClientMessage) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            connection.send(content: MessageCoding.encode(message), contentContext: .init(identifier: "m", metadata: [metadata]), completion: .idempotent)
        }
        // 30 MB of lines, numbered, then an end: what the client must get,
        // whole and once.
        let lines = 400_000
        send(.hello(token: token, client: "sleeper"))
        send(.create(CreateRequest(command: "seq -f 'line %08g of a program that prints a great deal' \(lines); echo THE-END; exec sleep 60", size: TermSize(cols: 200, rows: 50))))

        // Not read for a while: the host keeps at most its limit for it.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertLessThanOrEqual(server.largestUnsent, HostServer.mostUnsent + 1024 * 1024, "the host kept \(server.largestUnsent / 1024 / 1024) MB for a client that does not read")

        // Read: every output byte of the session, in the order it comes.
        let lock = NSLock()
        var output = Data()
        func receive() {
            connection.receiveMessage { data, context, _, error in
                guard error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .binary, let data, let frame = DataFrame(decoding: data), frame.kind == .output {
                    lock.lock()
                    output.append(frame.payload)
                    lock.unlock()
                }
                receive()
            }
        }
        receive()
        let deadline = Date().addingTimeInterval(60)
        func text() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: output, as: UTF8.self)
        }
        while !text().contains("THE-END"), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        // The numbers, wherever they stand: the first line follows the
        // terminal's own bytes.
        let whole = text()
        let pattern = try NSRegularExpression(pattern: "line [0-9]{8}")
        let got = pattern.matches(in: whole, range: NSRange(whole.startIndex..., in: whole)).compactMap { Range($0.range, in: whole).map { String(whole[$0]) } }
        XCTAssertEqual(got.count, lines, "lines missed or twice")
        XCTAssertEqual(Set(got).count, lines, "a line twice")
        XCTAssertTrue(got.first?.hasPrefix("line 00000001") ?? false)
        XCTAssertTrue(got.last?.hasPrefix("line 00400000") ?? false)
    }
}
