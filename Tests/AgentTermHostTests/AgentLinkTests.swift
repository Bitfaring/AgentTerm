import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Whether each agent's session talks to the host (#129): its hooks and
/// AgentTerm's MCP server, heard from or said missing; an agent typed by
/// hand in a shell, found from the program in front of the terminal.
/// LINK-2 to LINK-4 and LINK-14 in docs/TESTING.md.
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
    private func start(grace: TimeInterval, shells: Bool = false, hooksDirectory: URL? = nil) throws {
        let agents = root.appendingPathComponent("agents").path
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents) }, home: root.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = hooksDirectory
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

    func testOnlySubmittedTextStartsTheHookCheck() {
        var input = FirstPromptInput()
        for keys in [
            "\r", "\u{1b}[A", "\r", "x", "\u{7f}", "\r", "discard", "\u{15}", "\r",
            "\u{1b}[20", "0~first line\r", "second line", "\u{1b}[201~",
        ] {
            XCTAssertFalse(input.submitted(Data(keys.utf8)))
        }
        XCTAssertTrue(input.submitted(Data("\r".utf8)))
    }

    func testAgentsWithDelayedHooksWaitForTheFirstEventAfterTheGracePeriod() throws {
        let agents = ["agy", "copilot", "codex", "claude"]
        let trigger = root.appendingPathComponent("first-turn")
        for agent in agents {
            let stop = event(agent, agent == "copilot" ? "agentStop" : "Stop")
            try standIn(agent, "while [ ! -f '\(trigger.path)' ]; do sleep 0.1; done\n\(stop)\nexec sleep 600")
        }
        try start(grace: 0.5)
        for agent in agents { client.send(.create(CreateRequest(command: agent, cwd: root.path))) }
        wait("all sessions past the grace period") { sessions.count == agents.count && sessions.allSatisfy { $0.link?.mcp == false } }
        XCTAssertTrue(sessions.allSatisfy { $0.link?.hooks == nil })
        for session in sessions {
            client.send(.attach(session: session.id, size: .default))
            client.connection(send: session.id, "hello")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(sessions.allSatisfy { $0.link?.hooks == nil }, "typing alone is not a submission")
        for session in sessions { client.connection(send: session.id, "\r") }
        wait("no hook response after submitting") { sessions.allSatisfy { $0.link?.hooks == false } }
        try Data().write(to: trigger)
        wait("the first event from each agent") { sessions.allSatisfy { $0.link?.hooks == true } }
    }

    /// LINK-3: what an agent's session has not heard from within the grace
    /// of its start is said missing.
    func testWhatIsNotHeardIsSaidMissing() throws {
        try standIn("claude", "exec sleep 600")
        try start(grace: 1)
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        let id = try XCTUnwrap(sessions.first?.id)
        client.send(.attach(session: id, size: .default))
        client.connection(send: id, "hello\r")
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
        wait("not given") { sessions.first?.link == AgentLink(mcp: false, prompt: .missing) }
    }

    func testCopilotCannotBeGivenInstructionsInAnUnwritableLocation() throws {
        let file = root.appendingPathComponent("regular-file")
        try Data().write(to: file)
        try standIn("copilot", "exec sleep 600")
        try start(grace: 1, shells: true, hooksDirectory: file)
        client.send(.create(CreateRequest(command: "copilot", cwd: root.path)))
        wait("the link check") { sessions.first?.link?.mcp == false }
        XCTAssertEqual(sessions.first?.link?.prompt, .missing)
    }

    func testCopilotIsGivenThePreparedDirectory() throws {
        let file = root.appendingPathComponent("instructions-path")
        try standIn("copilot", #"printf '%s' "$COPILOT_CUSTOM_INSTRUCTIONS_DIRS" > '\#(file.path)'; exec sleep 600"#)
        try start(grace: 1, shells: true, hooksDirectory: root)
        client.send(.create(CreateRequest(command: "copilot", cwd: root.path)))
        wait("the link check") { sessions.first?.link?.mcp == false }
        let directories = try String(contentsOf: file, encoding: .utf8).split(separator: ",")
        XCTAssertEqual(directories.last.map(String.init), root.appendingPathComponent("copilot-instructions").path)
        XCTAssertEqual(sessions.first?.link?.prompt, .given)
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

    /// TABS-7: a shell says it runs a program while a command it was typed
    /// is in front, and not at its prompt; a session started with a command
    /// runs one from its start.
    func testAShellSaysWhileItRunsACommand() throws {
        try start(grace: 60)
        client.send(.create(CreateRequest(cwd: root.path)))
        wait("the shell") { sessions.count == 1 }
        let shell = try XCTUnwrap(sessions.first)
        client.send(.attach(session: shell.id, size: .default))
        wait("at its prompt") { sessions.first?.running == false }
        XCTAssertFalse(try XCTUnwrap(sessions.first).isBusy)
        client.connection(send: shell.id, "sleep 600\r")
        wait("running a command") { sessions.first?.running == true }
        XCTAssertTrue(try XCTUnwrap(sessions.first).isBusy)
        client.connection(send: shell.id, "\u{03}")
        wait("at its prompt again") { sessions.first?.running == false }

        client.send(.create(CreateRequest(command: "sleep 600", cwd: root.path, title: "build")))
        wait("the command's session") { sessions.contains { $0.title == "build" } }
        XCTAssertEqual(sessions.first { $0.title == "build" }?.running, true)
    }

    /// A program is named as it was started, not by its file: a link named
    /// as an agent is that agent, as Claude Code's command is a link to a
    /// file named for its version.
    func testAProgramIsNamedAsItWasStarted() throws {
        let process = Process()
        process.executableURL = root.appendingPathComponent("bin/claude")
        process.arguments = ["5"]
        process.environment = OwnEnvironment.withoutAgentTerms
        try process.run()
        defer { process.terminate() }
        wait("its name") { ProcessNames.command(of: process.processIdentifier) == "claude" }
        XCTAssertEqual(ProcessNames.parent(of: process.processIdentifier), getpid())
        XCTAssertEqual(ProcessNames.agent(above: process.processIdentifier, known: { SessionSummaries.agent(forCommand: $0) }), "claude")
        // None above launchd: the test's own process may well be under an
        // agent, the tests being run from one (#187).
        XCTAssertNil(ProcessNames.agent(above: 1, known: { SessionSummaries.agent(forCommand: $0) }))
    }
}

private extension AgentTermConnection {
    /// Types into a session, as a person does.
    func connection(send session: SessionID, _ text: String) {
        sendInput(Data(text.utf8), to: session)
    }
}
