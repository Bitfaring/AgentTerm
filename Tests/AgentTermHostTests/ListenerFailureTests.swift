import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// REMOTE-36 (#274): a Tailscale address the host cannot listen on is told
/// to every client as a failure with its reason, once, not at every try;
/// and taken back once the host listens there.
final class ListenerFailureTests: XCTestCase {
    private let token = "test-token-0123456789abcdef0123456789"

    func testAListenerThatCannotBeMadeIsToldOnceAndTakenBackWhenItListens() throws {
        // 127.0.0.2 is no address of this Mac's (lo0 has 127.0.0.1 only):
        // nothing can listen there, as on a Tailscale address another
        // program holds or one that went. Then ::1, where it can.
        let lock = NSLock()
        var address = "127.0.0.2"
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: true, detectAgents: { [] })
        configuration.tailscaleInterval = 0.3
        configuration.tailscaleAddress = {
            lock.lock()
            defer { lock.unlock() }
            return address
        }
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }

        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        var lists: [[PartFailure]] = []
        client.onMessage = { if case .failures(let list) = $0 { lists.append(list) } }
        client.connect()
        defer { client.close() }
        func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            XCTAssertTrue(condition(), "timed out waiting for: \(what)")
        }
        func listenerFailures() -> [PartFailure] { (lists.last ?? []).filter { $0.part == .listener } }

        waitUntil("the failure told") { !listenerFailures().isEmpty }
        let told = try XCTUnwrap(listenerFailures().first)
        XCTAssertEqual(told.name, "127.0.0.2")
        XCTAssertFalse((told.reason ?? "").isEmpty, "no reason")
        XCTAssertTrue(told.headline().hasPrefix("The iPhone cannot reach the host: it could not listen on its Tailscale address 127.0.0.2"), told.headline())
        // Tried again several times meanwhile: still one.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(listenerFailures().count, 1, "told again at every try")

        lock.lock()
        address = "::1"
        lock.unlock()
        waitUntil("the failure taken back") { listenerFailures().isEmpty }
    }

    /// Why a host stopped itself is kept in its marker, for the next.
    func testWhyAHostStoppedItselfIsKeptForTheNext() throws {
        var marker = HostMarker(pid: 1, sessions: [])
        marker.stopReason = "Its listener on 127.0.0.1:7717 failed: gone."
        let read = try JSONDecoder().decode(HostMarker.self, from: JSONEncoder().encode(marker))
        XCTAssertEqual(read.stopReason, marker.stopReason)
    }
}
