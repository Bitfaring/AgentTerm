import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// #272 (review of 2026-11-22): while the relay cannot be reached, each
/// notification that could not be sent takes the place of the one before
/// in the banner, but adds one more item to every Inbox. The relay is a
/// stand-in: nothing reaches the network.
final class ReviewSubPushFailureTests: XCTestCase {
    private final class Relay {
        let lock = NSLock()
        var pushes = 0
        var reachable = true

        var transport: PushCenter.Transport {
            { [weak self] url, _, done in
                guard let self else { return done(0, nil) }
                self.lock.lock()
                let reachable = self.reachable
                if url.path.hasSuffix("/v1/push") { self.pushes += 1 }
                self.lock.unlock()
                DispatchQueue.global().async {
                    guard reachable else { return done(0, Data(#"{"reason":"offline"}"#.utf8)) }
                    if url.path.hasSuffix("/v1/register") {
                        done(200, Data(#"{"ticket":"signed","expires":4102444800}"#.utf8))
                    } else {
                        done(200, Data(#"{"ok":true}"#.utf8))
                    }
                }
            }
        }

        var sent: Int {
            lock.lock()
            defer { lock.unlock() }
            return pushes
        }
    }

    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, credential: AgentTermConnection.Credential, name: String, kind: DeviceKind = .iphone) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: credential, clientName: name, kind: kind)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var pushState: PushState? { messages.compactMap { if case .pushState(let state) = $0 { return state } else { return nil } }.last }
        var token: String? { messages.compactMap { if case .paired(_, let token) = $0 { return token } else { return nil } }.first }
        var code: String? { messages.compactMap { if case .pairingCode(let code, _) = $0 { return code } else { return nil } }.last }
        var devices: [DeviceInfo]? { messages.compactMap { if case .devices(let list) = $0 { return list } else { return nil } }.last }
        var failures: [PartFailure] { messages.compactMap { if case .failures(let list) = $0 { return list } else { return nil } }.last ?? [] }
        /// The Inbox items that say a notification could not be sent.
        var pushFailureNotices: [Notice] {
            messages.compactMap { message -> Notice? in
                guard case .notice(let notice) = message, case .failure(let failure) = notice.kind, failure.part == .push else { return nil }
                return notice
            }
        }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "review-token-0123456789abcdef0123456789"
    private var relay: Relay!
    private var given: String?
    private var stateSet = false
    private var tool: URL { Bundle(for: ReviewSubPushFailureTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-push-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        relay = Relay()
        // The host's own state folder too: see #269.
        given = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
        setenv("AGENTTERM_STATE_DIR", root.appendingPathComponent("state").path, 1)
        stateSet = true
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, devicesFile: root.appendingPathComponent("devices.json"),
            statusLineTool: tool.path, usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = root.appendingPathComponent("hooks")
        configuration.home = root.path
        configuration.holdAwake = { _, _ in true }
        configuration.isOnPower = { true }
        configuration.idleSeconds = { 6 * 60 }
        configuration.refreshInterval = 0.2
        configuration.pushRelay = URL(string: "https://relay.test")
        configuration.pushesFile = root.appendingPathComponent("pushes.json")
        configuration.pushTransport = relay.transport
        configuration.alertDelay = 0.3
        server = HostServer(configuration: configuration)
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
        if stateSet { if let given { setenv("AGENTTERM_STATE_DIR", given, 1) } else { unsetenv("AGENTTERM_STATE_DIR") } }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// A stand-in for Claude Code that tells its hooks, one step for each
    /// line on its input: working, then asking permission and working
    /// again, three times over.
    private func standIn() throws -> URL {
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        let ask = """
            read line; printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}' | \(hook) PermissionRequest
            read line; printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \(hook) PostToolUse
            """
        try """
        #!/bin/sh
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | \(hook) UserPromptSubmit
        \(ask)
        \(ask)
        \(ask)
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// #272: three notifications that the relay could not take are one
    /// item in the Inbox, the newest, as they are one in the banner.
    func testNotificationsTheRelayCouldNotTakeAreOneItemInTheInbox() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        mac.connection.send(.createPairingCode)
        waitUntil("a code") { mac.code != nil }
        let pairing = Client(port: port, credential: .pairingCode(try XCTUnwrap(mac.code)), name: "iPhone")
        waitUntil("paired") { pairing.token != nil }
        let phoneToken = try XCTUnwrap(pairing.token)
        pairing.connection.close()
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("told it is off") { phone.pushState == .off }
        phone.connection.send(.pushRegister(PushRegistration(token: String(repeating: "ab", count: 32), key: PushSeal.newKey(), mac: "6B1E2C3D-mac")))
        waitUntil("registered") { phone.pushState == .on }
        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("working") { mac.sessions.first?.state?.isWorking == true }
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }

        relay.lock.lock(); relay.reachable = false; relay.lock.unlock()
        // Three questions, each one a notification the relay does not take.
        for round in 1...3 {
            let before = relay.sent
            mac.connection.sendInput(Data("\n".utf8), to: agent)
            waitUntil("question \(round) sent to the relay") { relay.sent > before }
            waitUntil("its failure said") { mac.pushFailureNotices.count >= 1 }
            mac.connection.sendInput(Data("\n".utf8), to: agent)
            waitUntil("working again") { mac.sessions.first?.state?.isWorking == true }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(mac.failures.filter { $0.part == .push }.count, 1, "the banner: one for the device, the newest")
        XCTAssertEqual(
            mac.pushFailureNotices.count, 1,
            "the Inbox got \(mac.pushFailureNotices.count) items for \(relay.sent) notifications the relay did not take")
    }
}
