import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// AGENT-16 and AGENT-17 (#141): Antigravity asks leave to call a tool of an
/// MCP server ("Allow calling this tool?") and says nothing while it waits;
/// for a tool of AgentTerm's own, AgentTerm knows all the same: the call it
/// said it is about to make does not come to its server.
final class AgentLeaveTests: XCTestCase {
    private var root: URL!
    private var server: HostServer!
    private var client: AgentTermConnection!
    private var sessions: [SessionInfo] = []
    /// Every state the host said of the first session, in turn.
    private var states: [AgentState?] = []
    private let token = "test-token-0123456789abcdef0123456789"
    private let own = AppChannel.current.mcpServerName

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-leave-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        // A stand-in Antigravity that says where its hooks write and what
        // its server is named by, and waits: the test plays its hooks.
        let file = root.appendingPathComponent("agents/agy")
        try """
        #!/bin/sh
        printf '%s\\n%s' "$\(HostServer.agentShellsVariable)" "$\(AppChannel.current.eventsVariable)" > '\(root.path)/variables.new'
        mv '\(root.path)/variables.new' '\(root.path)/variables'
        exec sleep 600

        """.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    override func tearDown() {
        client?.close()
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// AGENT-16: Antigravity's `PreToolUse` for a tool of AgentTerm's own
    /// server, as Antigravity 1.5.10 was seen to give it (2026-11-18), is
    /// told from one for another server's tool and from its own tools.
    func testACallOfAgentTermsOwnToolIsToldFromAnyOther() {
        func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
            ["hookEventName": "PreToolUse", "stepIdx": 4, "toolCall": ["id": "call_1", "name": name, "args": args]]
        }
        let mine = call("call_mcp_tool", ["ToolName": "shell_list", "ServerName": "agentterm", "Arguments": [String: Any]()])
        XCTAssertEqual(AgentHooks.ownToolCall(agent: "agy", event: "PreToolUse", input: mine, server: "agentterm"), "agentterm/shell_list")
        // The other build's server, another server, a tool of its own.
        XCTAssertNil(AgentHooks.ownToolCall(agent: "agy", event: "PreToolUse", input: mine, server: "agentterm-dev"))
        let theirs = call("call_mcp_tool", ["ToolName": "run", "ServerName": "Roblox_Studio"])
        XCTAssertNil(AgentHooks.ownToolCall(agent: "agy", event: "PreToolUse", input: theirs, server: "agentterm"))
        XCTAssertNil(AgentHooks.ownToolCall(agent: "agy", event: "PreToolUse", input: call("run_command", ["CommandLine": "ls"]), server: "agentterm"))
        // Another event, another agent.
        XCTAssertNil(AgentHooks.ownToolCall(agent: "agy", event: "PostToolUse", input: mine, server: "agentterm"))
        XCTAssertNil(AgentHooks.ownToolCall(agent: "claude", event: "PreToolUse", input: mine, server: "agentterm"))
    }

    // MARK: The host

    private func start() throws -> (key: String, events: URL, session: SessionID) {
        let agents = root.appendingPathComponent("agents").path
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents) }, home: root.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.agentsDirectory = agents
        configuration.foldersFile = root.appendingPathComponent("folders.json")
        configuration.linkGrace = 60
        configuration.leaveGrace = 0.6
        server = HostServer(configuration: configuration)
        let port = try server.start()
        client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        client.onMessage = { [weak self] message in
            guard let self, case .sessions(let list) = message else { return }
            self.sessions = list
            if let first = list.first, self.states.last != .some(first.state) { self.states.append(first.state) }
        }
        client.connect()
        client.send(.create(CreateRequest(command: "agy", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        let variables = root.appendingPathComponent("variables")
        wait("its variables") { FileManager.default.fileExists(atPath: variables.path) }
        let its = try String(contentsOf: variables, encoding: .utf8).components(separatedBy: "\n")
        let key = try XCTUnwrap(AgentShellsMCP.Session(variable: its.first)).key
        return (key, URL(fileURLWithPath: try XCTUnwrap(its.last)), try XCTUnwrap(sessions.first?.id))
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// What `agenttermd hook agy <event>` saves, said now.
    private func hook(_ event: String, _ input: [String: Any], in file: URL) throws {
        let record: [String: Any] = ["agent": "agy", "event": event, "at": Date().timeIntervalSince1970, "input": input]
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
    }

    private func call(server: String, tool: String) -> [String: Any] {
        ["toolCall": ["id": "call_\(UUID().uuidString)", "name": "call_mcp_tool", "args": ["ToolName": tool, "ServerName": server, "Arguments": [String: Any]()]]]
    }

    /// AGENT-17: Antigravity says it is about to call a tool of AgentTerm's
    /// own, and the call does not come to AgentTerm's server: it waits for
    /// leave, with the tool it asks for, as its own question names it. The
    /// call come, it works.
    func testACallOfAgentTermsOwnToolThatDoesNotComeIsWaitingForLeave() throws {
        let agent = try start()
        try hook("PreInvocation", [:], in: agent.events)
        wait("it works") { sessions.first?.state?.isWorking == true }
        try hook("PreToolUse", call(server: own, tool: "shell_open"), in: agent.events)
        wait("it waits for leave") { sessions.first?.state == .waitingForPermission(AgentQuestion(text: "\(own)/shell_open")) }
        // Allowed: the call comes to the server.
        client.send(.agentShell(id: 1, key: agent.key, request: .list))
        wait("it works again") { sessions.first?.state?.isWorking == true }
        // The next one is held, and the user stops the turn: not known.
        try hook("PreToolUse", call(server: own, tool: "shell_run"), in: agent.events)
        wait("it waits again") { sessions.first?.state == .waitingForPermission(AgentQuestion(text: "\(own)/shell_run")) }
        try hook("Stop", ["fullyIdle": true], in: agent.events)
        wait("it is done") { if case .done? = sessions.first?.state { return true } else { return false } }
    }

    /// AGENT-17: a call that comes at once, as one the user allowed for
    /// good does, is never said to wait, whichever the host learns of
    /// first, the hook or the call; nor is a call of another server's tool
    /// or of one of Antigravity's own, of which nothing is known.
    func testACallThatComesAndACallOfAnotherToolAreNotSaidToWait() throws {
        let agent = try start()
        try hook("PreInvocation", [:], in: agent.events)
        wait("it works") { sessions.first?.state?.isWorking == true }
        // The hook, then the call, within the grace.
        try hook("PreToolUse", call(server: own, tool: "shell_list"), in: agent.events)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        client.send(.agentShell(id: 1, key: agent.key, request: .list))
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(sessions.first?.state?.isWorking, true, "\(states)")
        // The call first, as the host may hear it, then the hook.
        try hook("PostToolUse", [:], in: agent.events)
        let before = Date()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        client.send(.agentShell(id: 2, key: agent.key, request: .list))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let record: [String: Any] = ["agent": "agy", "event": "PreToolUse", "at": before.timeIntervalSince1970, "input": call(server: own, tool: "shell_list")]
        try JSONSerialization.data(withJSONObject: record).write(to: agent.events, options: .atomic)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(sessions.first?.state?.isWorking, true, "\(states)")
        // Another server's tool, a tool of its own: not known, as before.
        for input in [call(server: "Roblox_Studio", tool: "run"), ["toolCall": ["name": "run_command", "args": ["CommandLine": "ls"]]]] {
            try hook("PreToolUse", input, in: agent.events)
            wait("its state not known") { sessions.first?.state == nil }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            XCTAssertNil(sessions.first?.state, "\(states)")
            try hook("PostToolUse", [:], in: agent.events)
            wait("it works") { sessions.first?.state?.isWorking == true }
        }
        XCTAssertFalse(states.contains { if case .waitingForPermission? = $0 { return true } else { return false } }, "\(states)")
    }
}
