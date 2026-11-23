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
        var alerts: [UInt64] { messages.compactMap { if case .noticeAlert(let id) = $0 { return id } else { return nil } } }
        var read: [UInt64] { messages.flatMap { if case .noticesRead(let ids) = $0 { return ids } else { return [] } } }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var relay: Relay!
    private var idle: TimeInterval = 6 * 60
    private var activityKeptIdle: TimeInterval = 2
    /// Where the host keeps its notices; nil keeps them in memory.
    private var noticesFile: URL?
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
        configuration.activityKeptIdle = activityKeptIdle
        configuration.pushRelay = url
        configuration.pushesFile = root.appendingPathComponent("pushes.json")
        configuration.pushTransport = relay.transport
        configuration.noticesFile = noticesFile
        // Short, for the tests; the wait itself is PUSH-19's (#322).
        configuration.alertDelay = Self.alertDelay
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
    /// How long a notice waits to be a notification in these tests.
    private static let alertDelay: TimeInterval = 0.5

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
        // PUSH-20 (#317): every field the relay and Apple can read of a
        // notification. What it says is in `payload`, sealed for the iPhone;
        // `collapse` is the Mac's name and the notice's number.
        XCTAssertEqual(Set(push.keys), ["token", "ticket", "expires", "payload", "collapse"])
        XCTAssertEqual(push["token"] as? String, deviceToken)
        XCTAssertEqual(push["ticket"] as? String, "signed")
        // The Mac's app is told over its connection, which may come after
        // the relay was asked.
        waitUntil("the Mac told") { !mac.notices.isEmpty }
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
        // A taking back: the notification it names, nothing else.
        XCTAssertEqual(Set(relay.sent[1].keys), ["token", "ticket", "expires", "gone"])
        XCTAssertNil(relay.sent[1]["payload"])
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("pushed again") { relay.sent.count == 3 }
        XCTAssertEqual(try opened(relay.sent[2]).state, .done(said: "All tests pass."))

        // Back: the log, and no notice again.
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("the log") { phone.log != nil }
        waitUntil("the Mac told of both") { mac.notices.count == 2 }
        XCTAssertEqual(phone.log?.map(\.id), mac.notices.map(\.id))
        XCTAssertEqual(phone.log?.first?.handled?.how, .movedOn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(phone.notices, [], "it was told through Apple")
        XCTAssertEqual(phone.pushState, .on)
    }

    /// PUSH-19 (#322): an agent's notification waits, and one the user acted
    /// on meanwhile (its agent moved on) is never shown; one not acted on
    /// is shown once the wait is over.
    func testANotificationWaitsAndIsNotShownWhenTheUserActedMeanwhile() throws {
        let (mac, _, agent) = try phoneAway()
        func payloads() -> Int { relay.sent.filter { $0["payload"] != nil }.count }
        // It asks for a permission: in the Inbox at once, not yet a notification.
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the Mac's app told") { mac.notices.count == 1 }
        XCTAssertEqual(mac.alerts, [], "a notification before its wait")
        XCTAssertEqual(payloads(), 0, "pushed before its wait")
        // Answered in the session before the wait is over: it goes on.
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("handled") { mac.messages.contains { if case .noticeHandled = $0 { return true } else { return false } } }
        RunLoop.main.run(until: Date().addingTimeInterval(Self.alertDelay * 3))
        XCTAssertEqual(mac.alerts, [], "the question answered meanwhile was a notification on the Mac")
        XCTAssertEqual(payloads(), 0, "the question answered meanwhile was pushed")
        XCTAssertNil(relay.sent.first { $0["gone"] != nil }, "nothing was pushed, so nothing is taken back")

        // Done, and nobody acts: a notification once the wait is over.
        let done = Date()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("pushed after its wait", timeout: 5) { payloads() == 1 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(done), Self.alertDelay, "pushed before its wait")
        // Over the Mac's connection, which may come after the relay heard.
        waitUntil("a notification on the Mac too", timeout: 5) { mac.alerts.count == 1 }
        XCTAssertEqual(try opened(try XCTUnwrap(relay.sent.first { $0["payload"] != nil })).state, .done(said: "All tests pass."))
    }

    /// PUSH-3: told whether someone is at the Mac or not; a phone that is
    /// connected is told over its connection, not through Apple.
    func testEveryDeviceIsToldWhetherSomeoneIsAtTheMacOrNot() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        func inUse() -> Bool? { mac.messages.compactMap { if case .macInUse(let on) = $0 { return on } else { return nil } }.last }
        lock.lock(); idle = 5; lock.unlock()
        waitUntil("someone at the Mac") { inUse() == true }
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the Mac's app told") { mac.notices.count == 1 }
        // Someone at the Mac: pushed all the same, once its wait is over
        // (#234, #322).
        waitUntil("pushed after its wait", timeout: 3) { relay.sent.count == 1 }

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
        // PUSH-20 (#317): a Live Activity's push is read by Apple to draw it,
        // so all of it is in the clear: the counts, the names of the
        // sessions that wait or are done, the Mac's name, and how soon.
        let started = try XCTUnwrap(relay.sent.last { $0["activity"] != nil })
        XCTAssertEqual(Set(started.keys), ["token", "ticket", "expires", "activity"])
        XCTAssertEqual(Set(activities()[0].keys), ["token", "event", "state", "mac", "urgent"])
        // The Mac's own name, as macOS gives it.
        XCTAssertFalse((activities()[0]["mac"] as? String ?? "").isEmpty)
        XCTAssertEqual(
            Set((activities()[0]["state"] as? [String: Any])?.keys.map { $0 } ?? []).subtracting(["firstWaiting"]),
            ["working", "permission", "asking", "done", "failed", "waiting", "doneNames"])

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
        // Kept between turns (#180): updated to done, not ended at once.
        waitUntil("updated to done", timeout: 15) {
            (activities().last?["state"] as? [String: Any])?["done"] as? Int == 1
        }
        XCTAssertEqual(activities().last?["event"] as? String, "update")
        let updated = Date()
        waitUntil("ended once nothing worked for a while", timeout: 15) { activities().last?["event"] as? String == "end" }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(updated), 1, "ended at once")
        XCTAssertTrue(activities().dropFirst().allSatisfy { $0["token"] as? String == own })
        XCTAssertEqual(activities().filter { $0["event"] as? String == "start" }.count, 1, "started again")
        XCTAssertLessThanOrEqual(activities().count, 5, "a burst is gathered: \(activities().map { $0["event"] ?? "" })")
    }

    /// LIVE-5 (#192): a phone that was connected when the host's activity
    /// ended (nothing worked or waited for `keptIdle`) and goes away later,
    /// before its own wait ran out, is sent the end then: once, closed or
    /// in the background.
    func testAPhoneThatGoesAwayAfterTheActivityEndedIsSentTheEnd() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        let own = String(repeating: "6b", count: 32)
        phone.connection.send(.liveActivity(token: own, startToken: String(repeating: "5a", count: 32)))
        func activities() -> [[String: Any]] { relay.sent.compactMap { $0["activity"] as? [String: Any] } }

        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        for _ in 0..<4 { mac.connection.sendInput(Data("\n".utf8), to: agent) }
        waitUntil("done") { mac.sessions.first?.state == .done(said: "All tests pass.") }
        // Past the burst's 3 s and `keptIdle`: the host's activity ended
        // while the phone was connected, so nothing went through Apple.
        RunLoop.main.run(until: Date().addingTimeInterval(3 + activityKeptIdle + 1.5))
        XCTAssertEqual(activities().count, 0, "a connected phone is sent its activity through Apple")

        phone.connection.send(.deviceInBackground(true))
        waitUntil("the end, once it is away", timeout: 5) { activities().contains { $0["event"] as? String == "end" } }
        XCTAssertEqual(activities().count, 1)
        XCTAssertEqual(activities().first?["token"] as? String, own)
        phone.connection.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(activities().count, 1, "ended twice")
    }

    /// LIVE-6 (#194): an activity ended through Apple is gone: the next
    /// turn, with the phone still away, starts a new one with the start
    /// token, not an update to the ended one; and once started, nothing
    /// more is sent to it, not a second start, until the phone gives the
    /// new activity's token.
    func testAnActivityEndedThroughAppleIsStartedAgainOnce() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        let start = String(repeating: "5a", count: 32)
        let own = String(repeating: "6b", count: 32)
        phone.connection.send(.liveActivity(token: own, startToken: start))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }
        func activities() -> [[String: Any]] { relay.sent.compactMap { $0["activity"] as? [String: Any] } }
        func event(_ index: Int) -> String? { activities()[index]["event"] as? String }

        let script = try standIn()
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "first")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let first = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: first, size: TermSize(cols: 80, rows: 24)))
        for _ in 0..<4 { mac.connection.sendInput(Data("\n".utf8), to: first) }
        waitUntil("ended", timeout: 15) { activities().last?["event"] as? String == "end" }
        let ended = activities().count
        XCTAssertEqual(activities().last?["token"] as? String, own)

        // Another turn, the phone still away.
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "second")))
        waitUntil("the second session") { mac.sessions.count == 2 }
        let second = try XCTUnwrap(mac.sessions.first { $0.id != first }).id
        mac.connection.send(.attach(session: second, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: second)
        waitUntil("sent again", timeout: 10) { activities().count > ended }
        XCTAssertEqual(event(ended), "start", "sent to the ended activity: \(activities()[ended])")
        XCTAssertEqual(activities()[ended]["token"] as? String, start)

        // Its agent asks: the started activity's token is not known yet,
        // and a second start would show a second activity.
        mac.connection.sendInput(Data("\n".utf8), to: second)
        waitUntil("asking") { mac.sessions.first { $0.id == second }?.state?.isWaiting == true }
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(activities().count, ended + 1, "more sent: \(activities().dropFirst(ended).map { $0["event"] ?? "" })")

        // The phone gives the new activity's token: updated through it.
        let new = String(repeating: "7c", count: 32)
        let back = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("back") { back.pushState == .on }
        back.connection.send(.liveActivity(token: new, startToken: start))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        back.connection.close()
        waitUntil("gone again") { mac.devices?.first?.isConnected == false }
        mac.connection.sendInput(Data("\n".utf8), to: second)
        waitUntil("updated", timeout: 10) { activities().count > ended + 1 }
        XCTAssertEqual(activities().last?["event"] as? String, "update")
        XCTAssertEqual(activities().last?["token"] as? String, new)
    }

    /// LIVE-9 (#233): each update of a phone's Live Activity through Apple
    /// says how soon it is to be shown: high (`urgent`) when an agent starts
    /// or stops asking or becomes done, low when it only works or the
    /// activity ends; the host's log names each.
    func testALiveActivityUpdateIsUrgentOnlyWhenItChangesWhatNeedsTheUser() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        phone.connection.send(.liveActivity(token: String(repeating: "6b", count: 32), startToken: String(repeating: "5a", count: 32)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }
        func activities() -> [[String: Any]] { relay.sent.compactMap { $0["activity"] as? [String: Any] } }
        func last() -> (state: [String: Any], urgent: Bool?, event: String?) {
            let item = activities().last ?? [:]
            return (item["state"] as? [String: Any] ?? [:], item["urgent"] as? Bool, item["event"] as? String)
        }

        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        func step(_ what: String, _ sent: (Int) -> Bool) {
            let before = activities().count
            mac.connection.sendInput(Data("\n".utf8), to: agent)
            waitUntil(what, timeout: 10) { activities().count > before && sent(before) }
        }
        step("working") { _ in last().state["working"] as? Int == 1 }
        XCTAssertEqual(last().urgent, false, "only working is urgent")
        step("asking") { _ in last().state["permission"] as? Int == 1 }
        XCTAssertEqual(last().urgent, true, "an agent that asks is not urgent")
        step("answered, working again") { _ in last().state["permission"] as? Int == 0 }
        XCTAssertEqual(last().urgent, true, "an agent that stops asking is not urgent")
        step("done") { _ in last().state["done"] as? Int == 1 }
        XCTAssertEqual(last().urgent, true, "an agent that is done is not urgent")
        waitUntil("ended", timeout: 15) { last().event == "end" }
        XCTAssertEqual(last().urgent, false, "the end is urgent")
        XCTAssertTrue(activities().allSatisfy { $0["event"] as? String != "start" })
        // What the host's log says of a push: the device cut short, what,
        // how soon; never what it holds.
        let push = PushCenter.Push(device: "0123456789abcdef", body: Data("make test".utf8), kind: "activity update", priority: .high)
        XCTAssertEqual(PushCenter.logLine(push), "agenttermd: push to 01234567: activity update, high (10)\n")
        let back = PushCenter.Push(device: "0123456789abcdef", body: Data(), kind: "take back", priority: nil)
        XCTAssertEqual(PushCenter.logLine(back), "agenttermd: push to 01234567: take back\n")
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

    /// PUSH-8 (#234): nothing waits. While someone is at the Mac, an agent
    /// that asks and an agent that is done are each a notification, on the
    /// Mac (`noticeAlert`) and pushed to the phone away, at the same moment:
    /// once its wait is over (#322), whoever is at the Mac.
    func testEveryNoticeIsANotificationAtOnceAlsoWhileSomeoneIsAtTheMac() throws {
        // Someone at the Mac from the start.
        lock.lock(); idle = 5; lock.unlock()
        server.stop()
        try start(relay: URL(string: "https://relay.test"))
        let (mac, _, agent) = try phoneAway()
        func inUse() -> Bool? { mac.messages.compactMap { if case .macInUse(let on) = $0 { return on } else { return nil } }.last }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(inUse(), true)
        func pushed() -> [UInt64] { relay.sent.filter { $0["payload"] != nil }.compactMap { try? opened($0).id } }

        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the question in the Mac's Inbox") { mac.notices.count == 1 }
        let question = try XCTUnwrap(mac.notices.first).id
        waitUntil("the question on both after its wait", timeout: Self.alertDelay + 0.6) { pushed() == [question] && mac.alerts == [question] }

        // Answered in the terminal, then done: done is told the same way.
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("done in the Mac's Inbox") { mac.notices.count == 2 }
        let done = try XCTUnwrap(mac.notices.last)
        XCTAssertEqual(done.state, .done(said: "All tests pass."))
        waitUntil("done on both after its wait", timeout: Self.alertDelay + 0.6) { pushed() == [question, done.id] && mac.alerts == [question, done.id] }
        XCTAssertEqual(inUse(), true, "no one at the Mac by the end")
    }

    /// PUSH-9 (#234, #322): a done agent's notice is not held back to be
    /// read first: it is a notification on both once its wait is over, and
    /// read on the Mac right after, it is taken back from the phone.
    func testADoneAgentReadOnTheMacIsTakenBackFromThePhone() throws {
        let (mac, _, agent) = try phoneAway()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("done") { mac.notices.count == 2 }
        let done = try XCTUnwrap(mac.notices.last).id
        func pushed() -> [UInt64] { relay.sent.filter { $0["payload"] != nil }.compactMap { try? opened($0).id } }
        waitUntil("done on both after its wait", timeout: Self.alertDelay + 0.6) { pushed().contains(done) && mac.alerts.contains(done) }
        mac.connection.send(.readNotices(ids: [done]))
        waitUntil("read, said back") { mac.read == [done] }
        waitUntil("taken back from the phone") { relay.sent.contains { $0["gone"] as? String == self.identifier(done) } }
    }

    /// PUSH-10 (#190): a phone that says it went to the background is away,
    /// though its connection is still open (iOS suspends the app without
    /// closing its socket): a notice reaches it through Apple only, not
    /// also over the connection; back in front it is shown nothing twice.
    func testAPhoneInTheBackgroundIsToldThroughAppleOnly() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        phone.connection.send(.deviceInBackground(true))
        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the question on the Mac") { mac.alerts.count == 1 }
        let id = try XCTUnwrap(mac.alerts.first)
        waitUntil("pushed") { relay.sent.contains { $0["payload"] != nil } }
        XCTAssertEqual(try opened(try XCTUnwrap(relay.sent.first { $0["payload"] != nil })).id, id)
        XCTAssertTrue(phone.notices.contains { $0.id == id }, "in its Inbox all the same")
        XCTAssertEqual(phone.alerts, [], "shown twice: over the connection too")
        XCTAssertEqual(mac.devices?.first?.isConnected, true, "the connection is still open")

        // Back in front: it was told already, through Apple.
        phone.connection.send(.deviceInBackground(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(phone.alerts, [], "shown again on coming back")
    }

    /// PUSH-14 (#233): a phone that connected again, its earlier connection
    /// left open on the Mac (the phone changed networks, and nothing told
    /// the Mac the old one is gone), is as its newest connection says: in
    /// the background, it is told through Apple, and its Live Activity is
    /// kept true through Apple, though the old connection never said it
    /// went to the background.
    func testAPhoneIsAsItsNewestConnectionSaysNotAnOlderOneLeftOpen() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phoneToken = try pair(mac)
        let old = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        old.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { old.pushState == .on }
        old.connection.send(.deviceInBackground(false))
        // Connected again: the old connection stays open, and says nothing more.
        let new = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("connected again") { new.pushState == .on }
        new.connection.send(.liveActivity(token: String(repeating: "6b", count: 32), startToken: String(repeating: "5a", count: 32)))
        new.connection.send(.deviceInBackground(true))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the question on the Mac") { mac.alerts.count == 1 }
        let id = try XCTUnwrap(mac.alerts.first)
        waitUntil("pushed though an old connection is open") { relay.sent.contains { $0["payload"] != nil } }
        XCTAssertEqual(try opened(try XCTUnwrap(relay.sent.first { $0["payload"] != nil })).id, id)
        waitUntil("its Live Activity through Apple", timeout: 6) { relay.sent.contains { $0["activity"] != nil } }
        XCTAssertEqual(old.alerts, [], "shown over the old connection")
        XCTAssertEqual(new.alerts, [], "shown over the connection of an app in the background")
    }

    /// PUSH-11 (#190): what came due while a phone was in the background
    /// and did not reach it through Apple (it is not registered) is shown
    /// when it comes back to the front, as to a phone that connects.
    func testWhatCameDueWhileAPhoneWasInTheBackgroundIsShownWhenItComesBack() throws {
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phone = Client(port: port, credential: .token(try pair(mac)), name: "iPhone")
        waitUntil("connected") { phone.pushState == .off }
        phone.connection.send(.deviceInBackground(true))
        mac.connection.send(.create(CreateRequest(command: try standIn().path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let agent = try XCTUnwrap(mac.sessions.first).id
        mac.connection.send(.attach(session: agent, size: TermSize(cols: 80, rows: 24)))
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("the question on the Mac") { mac.alerts.count == 1 }
        let id = try XCTUnwrap(mac.alerts.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(phone.alerts, [], "shown over the connection while in the background")
        phone.connection.send(.deviceInBackground(false))
        waitUntil("shown once back") { phone.alerts == [id] }
        phone.connection.send(.deviceInBackground(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(phone.alerts, [id], "once")
    }

    /// PUSH-12 (#193, #234): a failure that stopped work (a session that
    /// crashed) while someone is at the Mac is a notification at once, on
    /// the Mac and through Apple; a host that starts again, with the
    /// notices kept in a file, tells it neither again.
    func testAFailureIsAlertedAtOnceAndNotAgainAfterTheHostStartsAgain() throws {
        noticesFile = root.appendingPathComponent("notices.json")
        lock.lock(); idle = 5; lock.unlock()
        server.stop()
        try start(relay: URL(string: "https://relay.test"))
        let mac = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        let phone = Client(port: port, credential: .token(try pair(mac)), name: "iPhone")
        phone.connection.send(.pushRegister(PushRegistration(token: deviceToken, key: key, mac: macName)))
        waitUntil("registered") { phone.pushState == .on }
        phone.connection.close()
        waitUntil("the phone gone") { mac.devices?.first?.isConnected == false }
        mac.connection.send(.create(CreateRequest(command: "kill -KILL $$", cwd: root.path, title: "crash")))
        waitUntil("the failure's notice") { mac.notices.contains { $0.alerts && $0.state == nil } }
        let id = try XCTUnwrap(mac.notices.first { $0.alerts && $0.state == nil }).id
        func pushed() -> [UInt64] { relay.sent.filter { $0["payload"] != nil }.compactMap { try? opened($0).id } }
        waitUntil("on both at once", timeout: 0.6) { pushed() == [id] && mac.alerts == [id] }
        mac.connection.close()

        server.stop()
        try start(relay: URL(string: "https://relay.test"))
        let again = Client(port: port, credential: .token(token), name: "mac", kind: .mac)
        waitUntil("the log") { again.log?.contains { $0.id == id } == true }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(again.alerts, [], "shown again after the host started again")
        XCTAssertEqual(pushed(), [id], "pushed again after the host started again")
    }

    /// READ-1 (#180): read on one device is read on every device: the
    /// others are told, a phone that comes back finds it read in the log,
    /// and one that had it through Apple has it taken back.
    func testReadOnOneDeviceIsReadOnEvery() throws {
        let (mac, phoneToken, agent) = try phoneAway()
        mac.connection.sendInput(Data("\n".utf8), to: agent)
        waitUntil("pushed") { relay.sent.count == 1 }
        waitUntil("the Mac told") { mac.notices.count == 1 }
        let id = try XCTUnwrap(mac.notices.first).id
        let other = Client(port: port, credential: .token(token), name: "mac 2", kind: .mac)
        waitUntil("the other's log") { other.log != nil }
        mac.connection.send(.readNotices(ids: [id]))
        waitUntil("the other told") { other.read == [id] }
        waitUntil("taken back from the phone") { relay.sent.contains { $0["gone"] as? String == self.identifier(id) } }
        let phone = Client(port: port, credential: .token(phoneToken), name: "iPhone")
        waitUntil("the log") { phone.log != nil }
        XCTAssertEqual(phone.log?.first { $0.id == id }?.read, true)
        XCTAssertEqual(phone.alerts, [], "read: not shown again")
    }
}
