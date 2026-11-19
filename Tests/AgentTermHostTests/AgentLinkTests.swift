import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Whether each agent's session talks to the host (#129): its hooks and
/// AgentTerm's MCP server, heard from or said missing; an agent typed by
/// hand in a shell, found from the program in front of the terminal.
/// LINK-1 to LINK-4 and LINK-14 in docs/TESTING.md.
final class AgentLinkTests: XCTestCase {
    private var root: URL!
    private var server: HostServer!
    private var client: AgentTermConnection!
    private var sessions: [SessionInfo] = []
    /// What the host first said of each agent's link. `sessions` is the
    /// list as it is by the time it is looked at, and a hook may have been
    /// heard by then: on CI's runner it had (LINK-2, 2026-11-17).
    private var firstLink: [SessionID: AgentLink] = [:]
    private let token = "test-token-0123456789abcdef0123456789"
    /// The state folder the test's process had, while a host given the MCP
    /// server has one of the test's.
    private var stateBefore: String?
    private var stateChanged = false

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-link-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        // A program named as an agent is, which only waits.
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bin/claude").path, withDestinationPath: "/bin/sleep")
    }

    override func tearDown() {
        client?.close()
        server?.stop()
        if let stateBefore { setenv("AGENTTERM_STATE_DIR", stateBefore, 1) } else if stateChanged { unsetenv("AGENTTERM_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in agent, whose script is `body`.
    private func standIn(_ agent: String, _ body: String) throws {
        let file = root.appendingPathComponent("agents/\(agent)")
        try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// With `shells`, the host gives the agents AgentTerm's MCP server and
    /// its instructions, kept in the test's own state folder.
    private func start(grace: TimeInterval, shells: Bool = false) throws {
        let agents = root.appendingPathComponent("agents").path
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents) }, home: root.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.agentsDirectory = agents
        configuration.foldersFile = root.appendingPathComponent("folders.json")
        configuration.linkGrace = grace
        configuration.foregroundInterval = 0.3
        if shells {
            stateBefore = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
            stateChanged = true
            setenv("AGENTTERM_STATE_DIR", root.appendingPathComponent("state").path, 1)
            configuration.agentShells = AgentShellsSetup(directory: root.appendingPathComponent("state"), tool: "/usr/bin/true")
        }
        server = HostServer(configuration: configuration)
        let port = try server.start()
        client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        client.onMessage = { [weak self] message in
            guard let self, case .sessions(let list) = message else { return }
            self.sessions = list
            for session in list where self.firstLink[session.id] == nil { self.firstLink[session.id] = session.link }
        }
        client.connect()
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// An event as `agenttermd hook` saves it.
    private func event(_ agent: String, _ name: String) -> String {
        #"printf '{"agent":"\#(agent)","event":"\#(name)","at":%s,"input":{}}' "$(date +%s)" > "$\#(AppChannel.current.eventsVariable)""#
    }

    /// LINK-2: an agent's session hears its hooks and its MCP server: the
    /// server says it started, for its session's key.
    func testAnAgentsHooksAndServerAreHeard() throws {
        let key = root.appendingPathComponent("key")
        try standIn("claude", "printf '%s' \"$AGENTTERM_MCP\" > '\(key.path)'\n\(event("claude", "SessionStart"))\nexec sleep 600")
        try start(grace: 30)
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        // As the host first said it, before anything of the agent's ran.
        // No instructions in a test's host, which gives no MCP server: said
        // disabled from the start (#172).
        XCTAssertEqual(sessions.first.flatMap { firstLink[$0.id] }, AgentLink(prompt: .disabled), "known before it was heard")
        wait("its hooks heard") { sessions.first?.link?.hooks == true }
        XCTAssertNil(sessions.first?.link?.mcp)
        wait("its key") { FileManager.default.fileExists(atPath: key.path) }
        let session = try XCTUnwrap(AgentShellsMCP.Session(variable: try String(contentsOf: key, encoding: .utf8)))
        client.send(.agentShell(id: 0, key: session.key, request: .started(agent: "claude")))
        wait("its server heard") { sessions.first?.link == AgentLink(hooks: true, mcp: true, prompt: .disabled) }
    }

    /// LINK-3: what an agent's session has not heard from within the grace
    /// of its start is said missing.
    func testWhatIsNotHeardIsSaidMissing() throws {
        try standIn("claude", "exec sleep 600")
        try start(grace: 1)
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        wait("both said missing") { sessions.first?.link == AgentLink(hooks: false, mcp: false, prompt: .disabled) }
    }

    /// LINK-14 (#172): an agent given AgentTerm's instructions, which come
    /// through its MCP server, is checking until the server is heard, then
    /// given; one whose server is not heard within the grace, not given.
    func testInstructionsComeThroughTheServerAndAreSaidGivenOrNot() throws {
        let key = root.appendingPathComponent("key")
        try standIn("claude", "printf '%s' \"$AGENTTERM_MCP\" > '\(key.path)'\nexec sleep 600")
        try start(grace: 30, shells: true)
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        XCTAssertEqual(sessions.first.flatMap { firstLink[$0.id] }, AgentLink(), "not checking before its server was heard")
        wait("its key") { FileManager.default.fileExists(atPath: key.path) }
        let session = try XCTUnwrap(AgentShellsMCP.Session(variable: try String(contentsOf: key, encoding: .utf8)))
        client.send(.agentShell(id: 0, key: session.key, request: .started(agent: "claude")))
        wait("given") { sessions.first?.link == AgentLink(mcp: true, prompt: .given) }
    }

    func testInstructionsAreSaidNotGivenWhenTheServerIsNotHeard() throws {
        try standIn("claude", "exec sleep 600")
        try start(grace: 1, shells: true)
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        wait("not given") { sessions.first?.link == AgentLink(hooks: false, mcp: false, prompt: .missing) }
    }

    /// LINK-4: an agent typed by hand in a shell is found from the program
    /// in front of its terminal, as named when typed; heard as one started
    /// from a button, its hooks before it was found too; gone, with what it
    /// had, when the shell is in front again.
    func testAnAgentTypedInAShellIsFoundAndGoes() throws {
        try start(grace: 2)
        client.send(.create(CreateRequest(cwd: root.path)))
        wait("the shell") { sessions.count == 1 }
        let shell = try XCTUnwrap(sessions.first)
        XCTAssertNil(shell.typedAgent)
        XCTAssertNil(shell.link)
        client.send(.attach(session: shell.id, size: .default))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        // Its hook says before the program is looked at.
        client.connection(send: shell.id, "\(event("claude", "UserPromptSubmit")); '\(root.appendingPathComponent("bin/claude").path)' 600\r")
        wait("the agent typed in it") { sessions.first?.typedAgent == "claude" }
        wait("its hooks heard") { sessions.first?.link?.hooks == true }
        XCTAssertEqual(sessions.first?.state?.isWorking, true, "its state is not shown")
        wait("its server said missing") { sessions.first?.link?.mcp == false }
        // Ended: a shell again.
        client.connection(send: shell.id, "\u{03}")
        wait("the agent gone") { sessions.first?.typedAgent == nil }
        XCTAssertNil(sessions.first?.link)
        XCTAssertNil(sessions.first?.state)
    }

    /// A program is named as it was started, not by its file: a link named
    /// as an agent is that agent, as Claude Code's command is a link to a
    /// file named for its version.
    func testAProgramIsNamedAsItWasStarted() throws {
        let process = Process()
        process.executableURL = root.appendingPathComponent("bin/claude")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        wait("its name") { ProcessNames.command(of: process.processIdentifier) == "claude" }
        XCTAssertEqual(ProcessNames.parent(of: process.processIdentifier), getpid())
        XCTAssertEqual(ProcessNames.agent(above: process.processIdentifier, known: { SessionSummaries.agent(forCommand: $0) }), "claude")
        XCTAssertNil(ProcessNames.agent(above: getpid(), known: { SessionSummaries.agent(forCommand: $0) }))
    }
}

private extension AgentTermConnection {
    /// Types into a session, as a person does.
    func connection(send session: SessionID, _ text: String) {
        sendInput(Data(text.utf8), to: session)
    }
}
