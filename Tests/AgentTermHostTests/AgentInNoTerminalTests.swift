import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// LINK-10 and LINK-11 (#140): an agent that runs in no terminal is no
/// session's. What `agenttermd hook` and `agenttermd mcp` are told of their
/// session by their environment is gone by only when the agent that started
/// them runs in a terminal: Codex 0.169 runs its sessions through one app
/// server they share, in no terminal, in the environment of the session
/// that started it, and every session after spoke as that one.
final class AgentInNoTerminalTests: XCTestCase {
    private var root: URL!
    private var server: HostServer!
    private var client: AgentTermConnection!
    private var sessions: [SessionInfo] = []
    private var started: [pid_t] = []
    private var stateBefore: String?
    private let token = "test-token-0123456789abcdef0123456789"
    private var tool: URL { Bundle(for: AgentInNoTerminalTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }
    private let known: (String) -> String? = { SessionSummaries.agent(forCommand: $0) }

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-terminal-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state"), withIntermediateDirectories: true)
        // The MCP server signs in with the Mac's own token, which it reads
        // from the state folder: the test's, never the user's.
        try token.write(to: root.appendingPathComponent("state/token"), atomically: true, encoding: .utf8)
        stateBefore = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
        setenv("AGENTTERM_STATE_DIR", root.appendingPathComponent("state").path, 1)
    }

    override func tearDown() {
        // Each is the leader of a group of its own.
        for pid in started { kill(-pid, SIGKILL) }
        client?.close()
        server?.stop()
        if let stateBefore { setenv("AGENTTERM_STATE_DIR", stateBefore, 1) } else { unsetenv("AGENTTERM_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The rule

    /// The processes of a trial, as `ps` showed them: each with its command
    /// as typed, what started it, and whether it has a terminal.
    private func lookup(_ rows: [pid_t: (command: String, parent: pid_t, terminal: Bool?)]) -> ProcessNames.Lookup {
        ProcessNames.Lookup(command: { rows[$0]?.command }, parent: { rows[$0]?.parent }, hasTerminal: { rows[$0]?.terminal ?? nil })
    }

    /// LINK-10: the agent that started a hook or a server is looked for
    /// past the shells that only ran its command line; in no terminal, it
    /// is no session's. As each real agent was seen to start them on
    /// 2026-11-18 (docs/AGENT-CLIS.md).
    func testAnAgentInNoTerminalIsFoundPastTheShells() {
        // Claude Code 2.1.327 and Codex 0.169.1 with --no-daemon: the hook
        // has no terminal, the agent that started it has.
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 10, known: known, lookup: lookup([10: ("claude", 1, true)])))
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 10, known: known, lookup: lookup([10: ("codex", 1, true)])))
        // Copilot CLI 1.0.113 and Antigravity 1.5.10: both have it.
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 10, known: known, lookup: lookup([10: ("copilot", 1, true)])))
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 10, known: known, lookup: lookup([10: ("agy", 1, true)])))
        // Codex 0.169.1 as it starts by itself: the app server its sessions
        // share, in no terminal, kept by a loop the first session started.
        let shared: [pid_t: (command: String, parent: pid_t, terminal: Bool?)] = [
            30: ("codex", 20, false), 20: ("codex", 10, false), 10: ("codex", 1, true),
        ]
        XCTAssertEqual(ProcessNames.agentInNoTerminal(startedBy: 30, known: known, lookup: lookup(shared)), "codex")
        // A shell that stays between the two is looked past.
        XCTAssertEqual(
            ProcessNames.agentInNoTerminal(startedBy: 40, known: known, lookup: lookup(shared.merging([40: ("sh", 30, false)]) { $1 })), "codex")
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 40, known: known, lookup: lookup([40: ("bash", 10, false), 10: ("claude", 1, true)])))
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 40, known: known, lookup: lookup([40: ("zsh", 10, true), 10: ("zsh", 1, true)])))
        // A program that is no shell is not looked past: a test that starts
        // the server itself is believed, whatever runs the tests.
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 50, known: known, lookup: lookup(shared.merging([50: ("xctest", 30, false)]) { $1 })))
        // An agent that cannot be asked, as one that ended, is not said to
        // have no terminal.
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 10, known: known, lookup: lookup([10: ("codex", 1, nil)])))
        XCTAssertNil(ProcessNames.agentInNoTerminal(startedBy: 99, known: known, lookup: lookup([:])))
    }

    // MARK: The real hook and server

    private func start() throws {
        let agents = root.appendingPathComponent("agents").path
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents) }, home: root.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.agentsDirectory = agents
        configuration.foldersFile = root.appendingPathComponent("folders.json")
        configuration.linkGrace = 60
        configuration.foregroundInterval = 0.3
        server = HostServer(configuration: configuration)
        let port = try server.start()
        client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        client.onMessage = { [weak self] message in
            guard let self, case .sessions(let list) = message else { return }
            self.sessions = list
        }
        client.connect()
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// What a stand-in Codex does once it runs: its hook of a prompt, then
    /// AgentTerm's MCP server, which is asked for its tools and answers in
    /// `tools`. Both are started by it, not in its place.
    private func script(tools: URL) throws -> URL {
        let pipe = root.appendingPathComponent("in-\(UUID().uuidString)")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let file = root.appendingPathComponent("does-\(UUID().uuidString).sh")
        try """
        printf '{}' | '\(tool.path)' hook codex UserPromptSubmit
        exec 3<>'\(pipe.path)'
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' >&3
        '\(tool.path)' mcp <&3 > '\(tools.path)' 2> '\(tools.path).err' &
        wait

        """.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// How many tools the server offered, once it answered.
    private func offered(_ tools: URL) -> Int? {
        guard let text = try? String(contentsOf: tools, encoding: .utf8), let line = text.split(separator: "\n").first,
            let answer = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        return ((answer["result"] as? [String: Any])?["tools"] as? [Any])?.count
    }

    /// Starts a program named `codex` in a session of its own, with no
    /// terminal, as Codex's shared app server is: `environment` is all it
    /// has.
    private func startInNoTerminal(_ script: URL, environment: [String: String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0) }
        let arguments = [root.appendingPathComponent("bin/codex").path, script.path].map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + variables).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments, variables)
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        started.append(pid)
        return pid
    }

    /// LINK-11: a program named as an agent, in no terminal and with a
    /// session's environment, as Codex's shared app server has the one of
    /// the session that started it. Its hook and its server say nothing as
    /// that session: the host hears neither, the session's state stays, and
    /// the server offers no tools.
    func testWhatAnAgentInNoTerminalStartsDoesNotSpeakForASession() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        let variables = root.appendingPathComponent("variables")
        let stand = root.appendingPathComponent("agents/codex")
        try """
        #!/bin/sh
        printf '%s\\n%s' "$\(HostServer.agentShellsVariable)" "$\(AppChannel.current.eventsVariable)" > '\(variables.path).new'
        mv '\(variables.path).new' '\(variables.path)'
        exec sleep 600

        """.write(to: stand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.path)
        try start()
        client.send(.create(CreateRequest(command: "codex", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        wait("its variables") { FileManager.default.fileExists(atPath: variables.path) }
        let its = try String(contentsOf: variables, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(its.count, 2)
        XCTAssertFalse(its[1].isEmpty, "the session names no file for its hooks")

        // The first session's environment, in no terminal.
        let tools = root.appendingPathComponent("tools")
        let shared = try startInNoTerminal(
            try script(tools: tools),
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": root.path, "AGENTTERM_STATE_DIR": root.appendingPathComponent("state").path,
                HostServer.agentShellsVariable: its[0], AppChannel.current.eventsVariable: its[1],
            ])
        wait("it to be named as Codex is") { ProcessNames.command(of: shared) == "codex" }
        XCTAssertEqual(ProcessNames.hasTerminal(shared), false)
        wait("its server's answer") { offered(tools) != nil }
        XCTAssertEqual(offered(tools), 0, "the server of an agent in no terminal offers a session's tools")
        // Long enough for the host to hear what was said, had it been.
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: its[1]), "its hook wrote into the session's file")
        XCTAssertEqual(sessions.first?.link, AgentLink(prompt: .disabled), "the session heard an agent that is not its own")
        XCTAssertNil(sessions.first?.state, "the session shows the state of an agent that is not its own")
    }

    /// LINK-11, the other way: the same program in a session's terminal is
    /// that session's agent: its hook and its server are heard, and the
    /// server offers its tools.
    func testWhatAnAgentInATerminalStartsSpeaksForItsSession() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        try start()
        let tools = root.appendingPathComponent("tools")
        let does = try script(tools: tools)
        // Named as Codex is, in the session's own terminal.
        client.send(.create(CreateRequest(command: "exec -a codex /bin/sh '\(does.path)'", cwd: root.path)))
        wait("the session") { sessions.count == 1 }
        wait("its server's answer") { offered(tools) != nil }
        XCTAssertEqual(offered(tools), AgentShellsMCP.tools.count + AgentShellsMCP.browserTools.count)
        wait("the agent typed in it") { sessions.first?.typedAgent == "codex" }
        wait("its hooks and its server heard") { sessions.first?.link == AgentLink(hooks: true, mcp: true, prompt: .disabled) }
        XCTAssertEqual(sessions.first?.state?.isWorking, true)
    }
}
