import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Notices through Apple for a device that is away (#66), with a stand-in
/// for the relay: nothing reaches the network.
final class PushTests: XCTestCase {
    /// The relay as the host asks it: what it was sent, and how it answers.
    private final class Relay {
        let lock = NSLock()
        var registered: [String] = []
        var pushes: [[String: Any]] = []
        var pushStatus = 200
        var reachable = true

        var transport: PushCenter.Transport {
            { [weak self] url, body, done in
                guard let self else { return done(0, nil) }
                self.lock.lock()
                let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let reachable = self.reachable
                let status = self.pushStatus
                if url.path.hasSuffix("/v1/register") { self.registered.append(object["token"] as? String ?? "") }
                if url.path.hasSuffix("/v1/push") { self.pushes.append(object) }
                self.lock.unlock()
                DispatchQueue.global().async {
                    guard reachable else { return done(0, Data(#"{"reason":"offline"}"#.utf8)) }
                    if url.path.hasSuffix("/v1/register") {
                        done(200, Data(#"{"ticket":"signed","expires":4102444800}"#.utf8))
                    } else {
                        done(status, status == 200 ? Data(#"{"ok":true}"#.utf8) : Data(#"{"error":"apns","reason":"Unregistered"}"#.utf8))
                    }
                }
            }
        }

        var sent: [[String: Any]] {
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
        var notices: [Notice] { messages.compactMap { if case .notice(let notice) = $0 { return notice } else { return nil } } }
        var log: [Notice]? { messages.compactMap { if case .noticeLog(let list) = $0 { return list } else { return nil } }.last }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var relay: Relay!
    private var idle: TimeInterval = 6 * 60
    private let lock = NSLock()
    private var tool: URL { Bundle(for: PushTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }
    private let deviceToken = String(repeating: "ab", count: 32)
    private let key = PushSeal.newKey()
    private let macName = "6B1E2C3D-mac"

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-push-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        relay = Relay()
        try start(relay: URL(string: "https://relay.test"))
    }

    private func start(relay url: URL?) throws {
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, devicesFile: root.appendingPathComponent("devices.json"),
            statusLineTool: tool.path, usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = root.appendingPathComponent("hooks")
        configuration.home = root.path
        configuration.holdAwake = { _, _ in true }
        configuration.isOnPower = { true }
        configuration.idleSeconds = { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            return self?.idle
        }
        configuration.refreshInterval = 0.2
        configuration.pushRelay = url
        configuration.pushesFile = root.appendingPathComponent("pushes.json")
        configuration.pushTransport = relay.transport
        server = HostServer(configuration: configuration)
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// A stand-in for Claude Code that tells its hooks, one step for each
    /// line on its input: working, asking permission, working, done.
    private func standIn() throws -> URL {
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        try """
        #!/bin/sh
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | \(hook) UserPromptSubmit
        read line; printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}' | \(hook) PermissionRequest
        read line; printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \(hook) PostToolUse
        read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"All tests pass."}' | \(hook) Stop
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Pairs a phone, and returns its token.
    private func pair(_ mac: Client) throws -> String {
        mac.connection.send(.createPairingCode)
        waitUntil("a code") { mac.code != nil }
        let phone = Client(port: port, credential: .pairingCode(try XCTUnwrap(mac.code)), name: "iPhone")
        waitUntil("paired") { phone.token != nil }
        let token = try XCTUnwrap(phone.token)
        phone.connection.close()
        return token
    }

    /// A phone that registers, with a session whose agent works.
    private func phoneAway() throws -> (mac: Client, token: String, agent: SessionID) {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("told it is off") { phone.pushState == .off }
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        XCTAssertEqual(relay.registered, [deviceToken])
        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("working") { mac.sessions.first?.state?.isWorking == true }
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }
        return (mac, phoneToken, agent)
    }

    private func identifier(_ notice: UInt64) -> String { PushNotice.identifier(mac: macName, notice: notice) }

    private func opened(_ push: [String: Any]) throws -> PushNotice {
        let identifier = try XCTUnwrap(push["collapse"] as? String)
        return try PushSeal.open(try XCTUnwrap(push["payload"] as? String), identifier: identifier, key: key)
    }

    /// PUSH-2: a phone that is away is told through the relay of each
    /// notice, encrypted with its key; one handled while it is away is
    /// taken back the same way; when it comes back it is sent the log and
    /// nothing it was told already.
    func testAPhoneThatIsAwayIsToldThroughTheRelay() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        let waiting = AgentState.waitingForPermission(AgentQuestion(text: "make test"))
        waitUntil("waiting") { mac.sessions.first?.state == waiting }
        waitUntil("pushed") { relay.sent.count == 1 }
        let push = try XCTUnwrap(relay.sent.first)
        XCTAssertEqual(push["token"] as? String, deviceToken)
        XCTAssertEqual(push["ticket"] as? String, "signed")
        let question = try XCTUnwrap(mac.notices.first)
        XCTAssertEqual(push["collapse"] as? String, identifier(question.id))
        XCTAssertFalse((push["payload"] as? String ?? "").contains("make test"), "the relay cannot read it")
        let notice = try opened(push)
        XCTAssertEqual(notice.id, question.id)
        XCTAssertEqual(notice.state, waiting)
        XCTAssertEqual(notice.stateDigest, PushNotice.digest(waiting))
        XCTAssertEqual(notice.name, mac.sessions.first?.displayName)

        // Nothing more while it keeps waiting.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(relay.sent.count, 1)

        // Answered in the terminal: the agent moves on, and the notice is
        // taken back from the phone; then done: told again.
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("taken back") { relay.sent.count >= 2 }
        XCTAssertEqual(relay.sent[1]["gone"] as? String, identifier(question.id))
        XCTAssertNil(relay.sent[1]["payload"])
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("pushed again") { relay.sent.count == 3 }
        XCTAssertEqual(try opened(relay.sent[2]).state, .done(said: "All tests pass."))

        // Back: the log, and no notice again.
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("the log") { phone.log != nil }
        XCTAssertEqual(phone.log?.map(\.id), mac.notices.map(\.id))
        XCTAssertEqual(phone.log?.first?.handled?.how, .movedOn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(phone.notices, [], "it was told through Apple")
        XCTAssertEqual(phone.pushState, .on)
    }

    /// PUSH-3: told whether someone is at the Mac or not; a phone that is
    /// connected is told over its connection, not through Apple.
    func testEveryDeviceIsToldWhetherSomeoneIsAtTheMacOrNot() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        func inUse() -> Bool? { mac.messages.compactMap { if case .macInUse(let on) = $0 { return on } else { return nil } }.last }
        lock.lock(); idle = 5; lock.unlock()
        waitUntil("someone at the Mac") { inUse() == true }
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("pushed although the Mac is in use") { relay.sent.count == 1 }
        XCTAssertEqual(mac.notices.count, 1, "the Mac's app is told too")

        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("the phone back") { phone.log != nil }
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("done, told to the phone") { phone.notices.contains { $0.state == .done(said: "All tests pass.") } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(relay.sent.filter { $0["payload"] != nil }.count, 1, "a connected phone is not pushed to")
        XCTAssertNil(relay.sent.first { $0["gone"] != nil }, "a connected phone is told it is handled over its connection")
        XCTAssertTrue(phone.messages.contains { if case .noticeHandled = $0 { return true } else { return false } })
    }

    /// LIVE-4 (#168): a phone away has its Live Activity kept true through
    /// the relay: started with its start token, then updated with its
    /// activity's token, a burst of changes in one update, ended when no
    /// agent works or waits.
    func testTheLiveActivityOfAPhoneAwayIsKeptTrue() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        let start = String(repeating: "5a", count: 32)
        phone.connection.send(.liveActivity(token: nil, startToken: start))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }
        func activities() -> [[String: Any]] { relay.sent.compactMap { $0["activity"] as? [String: Any] } }

        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("started", timeout: 15) { activities().count == 1 }
        XCTAssertEqual(activities()[0]["token"] as? String, start)
        XCTAssertEqual(activities()[0]["event"] as? String, "start")
        XCTAssertEqual((activities()[0]["state"] as? [String: Any])?["working"] as? Int, 1)

        // The activity it started gives its own token.
        let own = String(repeating: "6b", count: 32)
        let back = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("back") { back.pushState == .on }
        back.connection.send(.liveActivity(token: own, startToken: start))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        back.connection.close()
        waitUntil("gone again") { mac.devices?.first?.isConnected == false }
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("done") { mac.sessions.first?.state == .done(said: "All tests pass.") }
        waitUntil("ended", timeout: 15) { activities().last?["event"] as? String == "end" }
        XCTAssertTrue(activities().dropFirst().allSatisfy { $0["token"] as? String == own })
        XCTAssertLessThanOrEqual(activities().count, 4, "a burst is gathered: \(activities().map { $0["event"] ?? "" })")
    }

    /// PUSH-4: a push the relay refuses is said in both apps' banner, once
    /// for the device; a token APNs no longer knows is forgotten.
    func testAPushThatFailsIsSaidAndAnUnknownTokenForgotten() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        relay.lock.lock(); relay.pushStatus = 410; relay.lock.unlock()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the failure said") { mac.failures.contains { $0.part == .push } }
        let failure = try XCTUnwrap(mac.failures.first { $0.part == .push })
        XCTAssertEqual(failure.name, "iPhone")
        XCTAssertTrue(failure.headline().hasPrefix("A notification to “iPhone” could not be sent through Apple"), failure.headline())
        XCTAssertTrue(failure.details.contains("Unregistered"), failure.details)
        XCTAssertTrue(failure.details.contains("no longer told through Apple"), failure.details)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("told it is off, to register again") { phone.pushState == .off }
    }

    /// PUSH-4: a relay that cannot be reached is said too, and the device
    /// stays registered.
    func testARelayThatCannotBeReachedIsSaid() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        relay.lock.lock(); relay.reachable = false; relay.lock.unlock()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the failure said") { mac.failures.contains { $0.part == .push && $0.details.contains("offline") } }
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("still on") { phone.pushState == .on }
    }

    /// PUSH-5: a revoked device is no longer told, and its key is gone
    /// from the host's file.
    func testARevokedDeviceIsNoLongerTold() throws {
        let (mac, _, agent) = try phoneAway()
        let file = root.appendingPathComponent("pushes.json")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(macName))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the keys are the user's alone")
        mac.connection.send(.revokeDevice(id: try XCTUnwrap(mac.devices?.first?.id)))
        waitUntil("revoked") { mac.devices?.isEmpty == true }
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(macName))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("waiting") { mac.sessions.first?.state?.isWaiting == true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(relay.sent.count, 0)
    }

    /// PUSH-6: a host without a relay says why, in the words of the build
    /// it is: a development build has no push.
    func testAHostWithoutARelaySaysWhy() throws {
        server.stop()
        try start(relay: nil)
        let mac = Client(port: port, credential: .token(token), name: "mac")
        let phone = Client(port: port, credential: .token(try pair(mac)), name: "iPhone")
        waitUntil("told") { phone.pushState != nil }
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("told why") { phone.pushState == .unavailable(reason: PushWords.notInThisBuild) }
        XCTAssertEqual(relay.registered, [])
    }
}
