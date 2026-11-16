import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// An agent opens shells the user sees, through AgentTerm's MCP server (#10).
final class AgentShellsMCPTests: XCTestCase {
    private func call(_ server: AgentShellsMCP, _ method: String, _ params: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        let line = String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
        let reply = server.handle(line) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
    }

    private func tool(_ server: AgentShellsMCP, _ name: String, _ arguments: [String: Any] = [:]) -> (text: String, failed: Bool) {
        let result = call(server, "tools/call", ["name": name, "arguments": arguments])["result"] as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (text, result["isError"] as? Bool ?? true)
    }

    /// MCP-1: outside a session of AgentTerm, no tools.
    func testOutsideASessionOfAgentTermThereAreNoTools() {
        let server = AgentShellsMCP(ask: nil, version: "test")
        let initialized = call(server, "initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any]
        XCTAssertEqual(initialized?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "a notification is not answered")
        XCTAssertEqual(((call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [Any])?.count, 0)
        XCTAssertTrue(tool(server, "shell_open").failed)
        XCTAssertNotNil(call(server, "no/such")["error"])
    }

    /// MCP-2: each tool asks the host for what it does, and says what came of it.
    func testEachToolAsksTheHost() {
        var asked: [AgentShellRequest] = []
        let shell = SessionInfo(id: 7, title: "ssh", cwd: "/p", size: .default, createdAt: Date())
        let another = SessionInfo(id: 9, title: "dev", cwd: "/q", size: .default, createdAt: Date())
        let server = AgentShellsMCP(
            ask: { request in
                asked.append(request)
                switch request {
                case .open: return .opened(shell)
                case .list: return .shells([shell, another])
                case .read: return .screen("$ ls\nREADME.md")
                case .send: return .done
                case .close(let session): return session == 7 ? .done : .refused("not yours")
                case .run, .command: return .done
                }
            }, version: "test")
        XCTAssertEqual(((call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, AgentShellsMCP.tools.count)
        XCTAssertEqual(tool(server, "shell_open", ["command": "ssh build-server", "title": "build"]).text, "Opened shell 7, “ssh”, in /p. It runs that program: type into it with shell_send.")
        XCTAssertEqual(tool(server, "shell_list").text, "7: ssh, in /p\n9: dev, in /q")
        XCTAssertEqual(tool(server, "shell_read", ["session": 7, "lines_above": 20]).text, "$ ls\nREADME.md")
        XCTAssertFalse(tool(server, "shell_send", ["session": 7, "text": "ls", "keys": ["Return"]]).failed)
        XCTAssertTrue(tool(server, "shell_close", ["session": 8]).failed)
        XCTAssertTrue(tool(server, "shell_read").failed, "a shell's number is needed")
        XCTAssertEqual(
            asked,
            [
                .open(command: "ssh build-server", title: "build"), .list, .read(session: 7, linesAbove: 20),
                .send(session: 7, text: "ls", keys: ["Return"]), .close(session: 8),
            ])
    }

    /// MCP-3: wait returns once a text appears, or once the screen is still.
    func testWaitingForTheScreen() {
        var screens = ["$ make", "$ make\nbuilding", "$ make\nbuilding\ndone"]
        let server = AgentShellsMCP(
            ask: { _ in .screen(screens.count > 1 ? screens.removeFirst() : screens[0]) }, version: "test")
        server.pollInterval = 0.01
        let found = tool(server, "shell_wait", ["session": 1, "until_text": "done", "timeout_seconds": 5])
        XCTAssertTrue(found.text.hasPrefix("“done” is on the screen"), found.text)
        let still = tool(server, "shell_wait", ["session": 1, "quiet_seconds": 0.05, "timeout_seconds": 5])
        XCTAssertTrue(still.text.hasPrefix("The screen has been still"), still.text)
        let late = tool(server, "shell_wait", ["session": 1, "until_text": "never", "timeout_seconds": 0.1])
        XCTAssertTrue(late.text.hasPrefix("Still waiting after"), late.text)
    }

    /// MCP-23 (#64): a `wait` that has not ended does not hold the server:
    /// the same agent reads a screen, types and lists its shells
    /// meanwhile, and waits on another shell too; each request is answered
    /// once, under its own id; a `wait` that is cancelled ends without an
    /// answer.
    func testAWaitDoesNotHoldUpTheOtherCalls() throws {
        let lock = NSLock()
        var asked: [String] = []
        var screens: [SessionID: String] = [1: "$ make", 2: "$ test"]
        let server = AgentShellsMCP(
            ask: { request in
                lock.lock()
                defer { lock.unlock() }
                switch request {
                case .read(let session, _):
                    return .screen(screens[session] ?? "")
                case .send(let session, let text, _):
                    asked.append("send \(session) \(text ?? "")")
                    return .done
                case .list:
                    asked.append("list")
                    return .shells([])
                default:
                    return .done
                }
            }, version: "test")
        server.pollInterval = 0.01
        var replies: [[String: Any]] = []
        func send(_ id: Any, _ tool: String, _ arguments: [String: Any]) throws {
            let line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
            server.handle(String(decoding: line, as: UTF8.self)) { reply in
                let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? [:]
                lock.lock()
                replies.append(object)
                lock.unlock()
            }
        }
        func answered(_ id: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return replies.filter { ($0["id"] as? Int) == id }.compactMap { (($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String }
        }
        func waitUntil(_ what: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(condition(), "timed out waiting for: \(what)")
        }

        // Two waits, each for a text that is not there yet, on two shells.
        try send(1, "shell_wait", ["session": 1, "until_text": "done", "timeout_seconds": 30])
        try send(2, "shell_wait", ["session": 2, "until_text": "passed", "timeout_seconds": 30])
        // Meanwhile the same agent looks, types and lists: answered at once.
        try send(3, "shell_read", ["session": 1])
        try send(4, "shell_send", ["session": 1, "text": "q"])
        try send(5, "shell_list", [:])
        waitUntil("the three answered while both waits go on") { answered(3).count == 1 && answered(4).count == 1 && answered(5).count == 1 }
        XCTAssertEqual(answered(3), ["$ make"])
        XCTAssertEqual(answered(1), [], "the first wait has not ended")
        XCTAssertEqual(answered(2), [])
        lock.lock()
        XCTAssertEqual(asked.sorted(), ["list", "send 1 q"])
        // The second shell says what its wait is for; the first does not yet.
        screens[2] = "$ test\npassed"
        lock.unlock()
        waitUntil("the second wait") { answered(2).count == 1 }
        XCTAssertTrue(answered(2)[0].hasPrefix("“passed” is on the screen"), answered(2)[0])
        XCTAssertEqual(answered(1), [])

        // The first is cancelled: it ends, and is not answered, whatever the screen says after.
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"the user stopped it"}}"#) { _ in XCTFail("a notification is not answered") }
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock()
        screens[1] = "$ make\ndone"
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(answered(1), [], "a cancelled wait is not answered")
        // A wait made after it, for the same text, is: the cancelling was of that request only.
        try send(6, "shell_wait", ["session": 1, "until_text": "done", "timeout_seconds": 30])
        waitUntil("a later wait") { answered(6).count == 1 }
        // Cancelling what is over, or was never asked, does nothing.
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":6}}"#) { _ in XCTFail("a notification is not answered") }
        server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"none"}}"#) { _ in XCTFail("a notification is not answered") }
        try send(7, "shell_list", [:])
        waitUntil("still answering") { answered(7).count == 1 }
        lock.lock()
        XCTAssertEqual(replies.count, 6, "each request answered once, the cancelled one not at all")
        lock.unlock()

        // What is not a tool call is answered as before, at once.
        var pinged: String?
        server.handle(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#) { pinged = $0 }
        XCTAssertEqual(pinged, #"{"id":"p","jsonrpc":"2.0","result":{}}"#)
    }

    /// MCP-14: a session's variable names the build whose host it is, and
    /// only that build's server takes it as its own.
    func testAServerTakesOnlyASessionOfItsOwnBuild() {
        let session = AgentShellsMCP.Session(port: 7718, key: "key", useShells: true)
        XCTAssertEqual(session.variable(channel: .dev), "7718 key dev use")
        XCTAssertEqual(AgentShellsMCP.Session(port: 7717, key: "key", useShells: false).variable(channel: .release), "7717 key release")
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7718 key dev use", channel: .dev), session)
        XCTAssertNil(AgentShellsMCP.Session(variable: "7718 key dev use", channel: .release), "the dev build's session is not the released server's")
        XCTAssertNil(AgentShellsMCP.Session(variable: "7717 key release", channel: .dev), "nor the released build's the dev server's")
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7717 key release", channel: .release)?.useShells, false)
        // From a host before the builds had a server each: the released one's.
        XCTAssertEqual(AgentShellsMCP.Session(variable: "7717 key use", channel: .release), AgentShellsMCP.Session(port: 7717, key: "key", useShells: true))
        XCTAssertNil(AgentShellsMCP.Session(variable: "7717 key use", channel: .dev))
        XCTAssertNil(AgentShellsMCP.Session(variable: nil, channel: .dev))
        XCTAssertNil(AgentShellsMCP.Session(variable: "nothing", channel: .dev))
    }

    /// MCP-14: the server and its instructions go by the build's name.
    func testTheServerGoesByItsBuildsName() {
        let server = AgentShellsMCP(ask: { _ in .done }, name: "agentterm-dev", version: "test", useShells: true)
        let initialized = call(server, "initialize")["result"] as? [String: Any]
        XCTAssertEqual((initialized?["serverInfo"] as? [String: Any])?["name"] as? String, "agentterm-dev")
        XCTAssertTrue((initialized?["instructions"] as? String ?? "").contains("the agentterm-dev MCP server"))
        XCTAssertTrue(AgentShellsInstructions.useShells(server: "agentterm").contains("the agentterm MCP server"))
        XCTAssertEqual(AppChannel.release.mcpServerName, "agentterm")
        XCTAssertEqual(AppChannel.dev.mcpServerName, "agentterm-dev")
    }

    func testKeysByName() {
        XCTAssertEqual(TerminalKeys.bytes(for: "Return"), "\r")
        XCTAssertEqual(TerminalKeys.bytes(for: "Control C"), "\u{03}")
        XCTAssertEqual(TerminalKeys.bytes(for: "ctrl-d"), "\u{04}")
        XCTAssertEqual(TerminalKeys.bytes(for: "Up"), "\u{1b}[A")
        XCTAssertNil(TerminalKeys.bytes(for: "Hyper"))
    }
}

/// MCP-4: each agent is given the server on its command line, for its
/// session only, in the way it takes one; nothing when it is off. MCP-11:
/// Codex is told to pass the session's variable on to it.
final class AgentShellsGivenTests: XCTestCase {
    private func words(_ arguments: String) -> [String] {
        let result = Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' x" + arguments])
        return String(decoding: result?.output ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init).dropFirst().map { $0 }
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testEachAgentIsGivenTheServerForItsSessionOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-given-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks")
        let tool = "/Apps/My App's/agenttermd"
        let server = AgentHooks.Server(name: "agentterm-dev", tool: tool)
        func given(_ agent: String, _ server: AgentHooks.Server?) throws -> [String] {
            words(try AgentHooks.launchArguments(agent: agent, tool: tool, usageFile: nil, directory: hooks, home: root.path, prompt: "Told.", server: server))
        }

        // Claude Code: --mcp-config, before --settings, which ends the words
        // it takes.
        let claude = try given("claude", server)
        XCTAssertEqual(claude.first, "--mcp-config")
        XCTAssertEqual(claude[2], "--settings")
        let claudeServers = try XCTUnwrap(try object(claude[1])["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(claudeServers.keys.sorted(), ["agentterm-dev"])
        XCTAssertEqual(claudeServers["agentterm-dev"]?["command"] as? String, tool)
        XCTAssertEqual(claudeServers["agentterm-dev"]?["args"] as? [String], ["mcp"])
        XCTAssertEqual(claudeServers["agentterm-dev"]?["type"] as? String, "stdio")

        // Codex: its table as -c, with the session's variable passed on.
        let codex = try given("codex", server)
        XCTAssertTrue(codex.contains(#"mcp_servers.agentterm-dev.command="/Apps/My App's/agenttermd""#), codex.joined(separator: "\n"))
        XCTAssertTrue(codex.contains(#"mcp_servers.agentterm-dev.args=["mcp"]"#))
        XCTAssertTrue(codex.contains(#"mcp_servers.agentterm-dev.env_vars=["AGENTTERM_MCP"]"#))
        XCTAssertEqual(codex.filter { $0 == "-c" }.count, AgentHooks.codexEvents.count + 3)

        // Copilot CLI: --additional-mcp-config, every tool of it.
        let copilot = try given("copilot", server)
        let at = try XCTUnwrap(copilot.firstIndex(of: "--additional-mcp-config"))
        let copilotServer = try XCTUnwrap((try object(copilot[at + 1])["mcpServers"] as? [String: [String: Any]])?["agentterm-dev"])
        XCTAssertEqual(copilotServer["type"] as? String, "local")
        XCTAssertEqual(copilotServer["command"] as? String, tool)
        XCTAssertEqual(copilotServer["tools"] as? [String], ["*"])

        // Antigravity: in the folder it is given, which it reads as a
        // project's.
        let agy = try given("agy", server)
        XCTAssertEqual(Array(agy.prefix(2)), ["--add-dir", hooks.appendingPathComponent("antigravity").path])
        let file = hooks.appendingPathComponent("antigravity/.agents/mcp_config.json")
        let agyServers = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])["mcpServers"] as? [String: [String: Any]]
        XCTAssertEqual(agyServers?["agentterm-dev"]?["command"] as? String, tool)
        XCTAssertEqual(agyServers?["agentterm-dev"]?["args"] as? [String], ["mcp"])

        // Off: none of them gets it, and Antigravity's file is gone.
        XCTAssertFalse(try given("claude", nil).contains("--mcp-config"))
        XCTAssertFalse(try given("codex", nil).joined().contains("mcp_servers"))
        XCTAssertFalse(try given("copilot", nil).contains("--additional-mcp-config"))
        _ = try given("agy", nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// The server is always given, and nothing is run in the agents to
    /// give it.
    func testTheServerIsGivenAndNothingIsRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-given-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ran: [[String]] = []
        let agents = [AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex")]
        let setup = AgentShellsSetup(directory: root, tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm") {
            ran.append($0); return true
        }
        XCTAssertEqual(setup.server, AgentHooks.Server(name: "agentterm", tool: "/Apps/AgentTerm.app/agenttermd"))
        XCTAssertEqual(setup.removeLeftovers(agents: agents), [])
        XCTAssertEqual(ran, [], "nothing asked of the agents")
    }
}

/// MCP-19: what an earlier build put in the agents' configuration is taken
/// out with each agent's own command, once for each; an agent that refuses
/// is told to the apps, which warn of it, and is not asked again.
final class AgentShellsLeftoverTests: XCTestCase {
    private func recordInstalled(_ agents: [String: String], name: String?, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var record: [String: Any] = ["installed": agents]
        if let name { record["name"] = name }
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("agent-shells.json"))
    }

    func testWhatAnEarlierBuildInstalledIsTakenOutOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-leftover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try recordInstalled(["claude": "/Apps/AgentTerm.app/agenttermd", "codex": "/Apps/AgentTerm.app/agenttermd", "agy": "/x"], name: "agentterm", in: root)
        var ran: [[String]] = []
        let agents = [
            AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex"),
            AgentInfo(id: "copilot", name: "Copilot CLI", path: "/a/copilot"), AgentInfo(id: "agy", name: "Antigravity", path: nil),
        ]
        func leftovers() -> AgentShellsSetup {
            AgentShellsSetup(directory: root, tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm") {
                ran.append($0); return true
            }
        }
        XCTAssertEqual(leftovers().removeLeftovers(agents: agents), [])
        XCTAssertEqual(
            ran, [["/a/claude", "mcp", "remove", "--scope", "user", "agentterm"], ["/a/codex", "mcp", "remove", "agentterm"]],
            "only those it was installed in; one not installed now is left for later")
        ran = []
        XCTAssertEqual(leftovers().removeLeftovers(agents: agents.filter { $0.id != "agy" }), [])
        XCTAssertEqual(ran, [], "taken out: forgotten")
        // Antigravity installed again: taken out of it then.
        XCTAssertEqual(leftovers().removeLeftovers(agents: [AgentInfo(id: "agy", name: "Antigravity", path: "/a/agy")]), [])
        XCTAssertEqual(ran, [["/a/agy", "mcp", "remove", "agentterm"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-shells.json").path), "nothing left to take out")
    }

    func testAnAgentThatRefusesIsToldToTheApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        try recordInstalled(["claude": "/old/agenttermd", "codex": "/old/agenttermd"], name: "agentterm", in: state)
        let agents = [AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex")]
        var ran: [[String]] = []
        let token = "test-token-0123456789abcdef0123456789"
        /// A host on that state folder, until `done` with what it told, or
        /// for a second when nothing is awaited.
        func host(until done: (([[AgentShellsFault]]) -> Bool)? = nil) throws -> [[AgentShellsFault]] {
            var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { agents })
            configuration.foldersFile = state.appendingPathComponent("folders.json")
            // Codex refuses.
            configuration.agentShells = AgentShellsSetup(directory: state, tool: "/usr/bin/true", name: "agentterm") {
                ran.append($0); return $0.first != "/a/codex"
            }
            let server = HostServer(configuration: configuration)
            let port = try server.start()
            defer { server.stop() }
            let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            defer { client.close() }
            var told: [[AgentShellsFault]] = []
            client.onMessage = { if case .agentShellsFaults(let list) = $0 { told.append(list) } }
            client.connect()
            let deadline = Date().addingTimeInterval(done == nil ? 1 : 15)
            while !(done?(told) ?? false) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return told
        }
        let refused = [AgentShellsFault(cause: .leftOver, agents: ["Codex"])]
        XCTAssertEqual(try host { $0.last == refused }.last, refused)
        XCTAssertEqual(ran, [["/a/claude", "mcp", "remove", "--scope", "user", "agentterm"], ["/a/codex", "mcp", "remove", "agentterm"]])

        // The next host asks none of them again, and has nothing to say.
        ran = []
        XCTAssertEqual(try host().last, [])
        XCTAssertEqual(ran, [])
    }
}

/// MCP-15: a released build and a development build each give the server
/// under a name of their own, and each takes out only what it put in (#57).
final class AgentShellsBuildsTests: XCTestCase {
    func testEachBuildTakesOutItsOwnAndLeavesTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var ran: [[String]] = []
        let agents = [AgentInfo(id: "claude", name: "Claude Code", path: "/a/claude"), AgentInfo(id: "codex", name: "Codex", path: "/a/codex")]
        let releasedState = root.appendingPathComponent("AgentTerm"), devState = root.appendingPathComponent("AgentTerm Dev")
        for (state, record) in [
            (releasedState, #"{"installed":{"claude":"/Apps/AgentTerm.app/agenttermd"},"name":"agentterm"}"#),
            // A development build from before each build had its name, which
            // installed under the name every build shared.
            (devState, #"{"installed":{"codex":"/dist/AgentTerm Dev.app/agenttermd"}}"#),
        ] {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try record.write(to: state.appendingPathComponent("agent-shells.json"), atomically: true, encoding: .utf8)
        }
        let released = AgentShellsSetup(directory: releasedState, tool: "/Apps/AgentTerm.app/agenttermd", name: "agentterm") {
            ran.append($0); return true
        }
        let dev = AgentShellsSetup(directory: devState, tool: "/dist/AgentTerm Dev.app/agenttermd", name: "agentterm-dev") {
            ran.append($0); return true
        }
        dev.removeLeftovers(agents: agents)
        XCTAssertEqual(ran, [], "the shared name is not the development build's to take out")
        released.removeLeftovers(agents: agents)
        XCTAssertEqual(ran, [["/a/claude", "mcp", "remove", "--scope", "user", "agentterm"]])
        XCTAssertEqual(released.server.name, "agentterm")
        XCTAssertEqual(dev.server.name, "agentterm-dev")
    }
}

/// MCP-5 to MCP-8: stand-in agents start the real `agenttermd mcp`, as real
/// agents do, and the test speaks MCP to it through a pipe.
final class AgentShellsHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
    }

    /// An agent's MCP server, reached through its pipes.
    private final class Agent {
        let input: FileHandle
        let output: URL
        private var next = 0

        init(input: FileHandle, output: URL) {
            self.input = input
            self.output = output
        }

        /// Calls a tool and waits for its answer.
        func tool(_ name: String, _ arguments: [String: Any] = [:], in test: AgentShellsHostTests) -> (text: String, failed: Bool) {
            next += 1
            let id = next
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            do {
                try input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
            } catch {
                let said = (try? String(contentsOfFile: output.path + ".err", encoding: .utf8)) ?? ""
                XCTFail("the MCP server is gone: \(error); it said: \(said)")
                return ("", true)
            }
            var answer: [String: Any]?
            test.waitUntil("the answer to \(name)", timeout: 40) {
                let text = (try? String(contentsOf: self.output, encoding: .utf8)) ?? ""
                answer = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                    .first { ($0["id"] as? Int) == id }
                return answer != nil
            }
            let result = answer?["result"] as? [String: Any] ?? [:]
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", result["isError"] as? Bool ?? true)
        }

        /// Calls a tool and does not wait for its answer: its request's id.
        func begin(_ name: String, _ arguments: [String: Any] = [:]) throws -> Int {
            next += 1
            let request: [String: Any] = ["jsonrpc": "2.0", "id": next, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            try input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
            return next
        }

        /// Says something that is not answered.
        func notify(_ method: String, _ params: [String: Any]) throws {
            try input.write(contentsOf: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params]) + Data("\n".utf8))
        }

        /// What the server answered a request with, each time it did; the
        /// text of each answer.
        func answers(to id: Int) -> [String] {
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .filter { ($0["id"] as? Int) == id }
                .map { ((($0["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
        }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var tool: URL { Bundle(for: AgentShellsHostTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }
    private var stateBefore: String?

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        // A pipe whose reader is gone fails the write rather than the tests.
        signal(SIGPIPE, SIG_IGN)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-shells-\(UUID().uuidString)").standardizedFileURL
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        // The MCP server signs in with the Mac's own token, which it reads
        // from the state folder: the test's, never the user's.
        try token.write(to: state.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        stateBefore = ProcessInfo.processInfo.environment["AGENTTERM_STATE_DIR"]
        setenv("AGENTTERM_STATE_DIR", state.path, 1)
        server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        port = try server.start()
    }

    override func tearDown() {
        server?.stop()
        if let stateBefore { setenv("AGENTTERM_STATE_DIR", stateBefore, 1) } else { unsetenv("AGENTTERM_STATE_DIR") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// Starts a stand-in agent under `name`, which starts its MCP server as
    /// a real agent does, with its session's environment.
    private func startAgent(_ name: String, title: String, client: Client) throws -> (Agent, SessionID) {
        let folder = root.appendingPathComponent(title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pipe = folder.appendingPathComponent("in"), output = folder.appendingPathComponent("out")
        let script = folder.appendingPathComponent(name)
        try """
        #!/bin/sh
        mkfifo '\(pipe.path)'
        exec 3<>'\(pipe.path)'
        '\(tool.path)' mcp <&3 > '\(output.path)' 2> '\(output.path).err' &
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let before = Set(client.sessions.map(\.id))
        client.connection.send(.create(CreateRequest(command: script.path, cwd: folder.path, title: title)))
        waitUntil("the agent's session") { client.sessions.contains { !before.contains($0.id) } }
        waitUntil("its MCP server") { FileManager.default.fileExists(atPath: output.path) }
        let id = try XCTUnwrap(client.sessions.first { !before.contains($0.id) }?.id)
        return (Agent(input: try FileHandle(forWritingTo: pipe), output: output), id)
    }

    /// Starts the real `agenttermd mcp` with `variable` as its session's,
    /// says `request` to it, and gives its answer and how long it took.
    private func said(to request: [String: Any], variable: String, state: URL? = nil) throws -> (answer: [String: Any], took: TimeInterval) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment[HostServer.agentShellsVariable] = variable
        if let state { environment["AGENTTERM_STATE_DIR"] = state.path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var line = request
        line["jsonrpc"] = "2.0"
        line["id"] = 1
        let started = Date()
        try process.run()
        defer { process.terminate() }
        try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
        // Read off the main thread, which the host under test answers on.
        var read: Data?
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.availableData
            DispatchQueue.main.async { read = data }
        }
        waitUntil("the MCP server's answer", timeout: 40) { read != nil }
        let took = Date().timeIntervalSince(started)
        try input.fileHandleForWriting.close()
        let reply = try JSONSerialization.jsonObject(with: read ?? Data()) as? [String: Any]
        return (try XCTUnwrap(reply?["result"] as? [String: Any]), took)
    }

    private func toolsOffered(variable: String) throws -> Int {
        try XCTUnwrap((try said(to: ["method": "tools/list"], variable: variable).answer["tools"] as? [Any])?.count)
    }

    /// Calls `shell_list` through a server started with `variable`.
    private func listShells(variable: String, state: URL? = nil) throws -> (text: String, failed: Bool, took: TimeInterval) {
        let (result, took) = try said(to: ["method": "tools/call", "params": ["name": "shell_list", "arguments": [:]]], variable: variable, state: state)
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false, took)
    }

    /// MCP-17: an agent whose server cannot reach its host is told at once,
    /// and why, instead of waiting fifteen seconds for one fixed sentence
    /// (#58).
    func testAnAgentIsToldAtOnceThatItsHostIsNotRunning() throws {
        // A port nothing listens on: the host's own, once it has stopped.
        let gone = port
        server.stop()
        server = nil
        let told = try listShells(variable: AgentShellsMCP.Session(port: gone, key: "a-key", useShells: false).variable())
        XCTAssertTrue(told.failed)
        XCTAssertTrue(told.text.hasPrefix("AgentTerm's host is not running on port \(gone)"), told.text)
        XCTAssertLessThan(told.took, 8, "told at once, not after the fifteen seconds a silent host is given")
    }

    /// MCP-18: a server the host refuses says so to its agent, and the host
    /// tells the apps, which warn of it, until a server signs in again.
    func testAServerThatIsRefusedTellsItsAgentAndTheApps() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        func faults() -> [AgentShellsFault]? {
            mac.messages.compactMap { if case .agentShellsFaults(let list) = $0 { return list } else { return nil } }.last
        }
        // Another copy's state folder, with a token of its own.
        let other = root.appendingPathComponent("other-state")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "another-token-0123456789abcdef0123456789".write(to: other.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let variable = AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable()
        let told = try listShells(variable: variable, state: other)
        XCTAssertTrue(told.failed)
        XCTAssertTrue(told.text.hasPrefix("AgentTerm's host refused this server's sign-in"), told.text)
        XCTAssertLessThan(told.took, 8)
        waitUntil("the apps to be told") { faults() == [AgentShellsFault(cause: .signIn)] }

        // A server with the host's own token: answered, and the warning goes.
        let answered = try listShells(variable: variable)
        XCTAssertEqual(answered.text, "This is not the session of an agent AgentTerm started, or that session has ended.")
        waitUntil("the warning to go") { faults() == [] }
    }

    /// MCP-16: with both builds installed, an agent has two servers of
    /// AgentTerm. The one of the session's own build offers the tools; the
    /// other build's offers none, and does not sign in to a host that is
    /// not its own (#57).
    func testInASessionOnlyItsOwnBuildsServerOffersTools() throws {
        // The shells' six, and the browser's (#76).
        XCTAssertEqual(
            try toolsOffered(variable: AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable()), AgentShellsMCP.tools.count + AgentShellsMCP.browserTools.count,
            "its own build's session")
        let other: AppChannel = AppChannel.current == .dev ? .release : .dev
        XCTAssertEqual(
            try toolsOffered(variable: AgentShellsMCP.Session(port: port, key: "a-key", useShells: false).variable(channel: other)), 0,
            "a session of the other build")
    }

    /// MCP-24 (#64): the real server, in an agent's session, with a `wait`
    /// going on in a shell: the agent types into that shell and reads it
    /// meanwhile, answered at once, and what it typed ends the wait; a
    /// second wait is cancelled and never answered.
    func testTheRealServerAnswersWhileAWaitGoesOn() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (agent, _) = try startAgent("claude", title: "waiting", client: mac)
        let opened = agent.tool("shell_open", ["command": "cat", "title": "echo"], in: self)
        XCTAssertFalse(opened.failed, opened.text)
        waitUntil("the shell") { mac.sessions.contains { $0.title == "echo" } }
        let shell = try XCTUnwrap(mac.sessions.first { $0.title == "echo" }?.id)

        // Waits for a line nobody has typed yet.
        let waiting = try agent.begin("shell_wait", ["session": shell, "until_text": "finished", "timeout_seconds": 60])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(agent.answers(to: waiting), [])
        // Meanwhile: read, list, and type, each answered while the wait goes on.
        let started = Date()
        XCTAssertFalse(agent.tool("shell_read", ["session": shell], in: self).failed)
        XCTAssertTrue(agent.tool("shell_list", in: self).text.contains("echo"))
        XCTAssertFalse(agent.tool("shell_send", ["session": shell, "text": "finished", "keys": ["Return"]], in: self).failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "not held up until the wait's minute is over")
        // What it typed is what the wait was for.
        waitUntil("the wait to end") { agent.answers(to: waiting).count == 1 }
        XCTAssertTrue(agent.answers(to: waiting)[0].hasPrefix("“finished” is on the screen"))

        // A wait that is cancelled ends without an answer; the server goes on answering.
        let dropped = try agent.begin("shell_wait", ["session": shell, "until_text": "never typed", "timeout_seconds": 60])
        Thread.sleep(forTimeInterval: 0.3)
        try agent.notify("notifications/cancelled", ["requestId": dropped, "reason": "stopped"])
        XCTAssertFalse(agent.tool("shell_send", ["session": shell, "text": "never typed", "keys": ["Return"]], in: self).failed)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(agent.answers(to: dropped), [], "a cancelled wait is not answered, though its text came")
        XCTAssertEqual(agent.answers(to: waiting).count, 1, "answered once")
    }

    /// MCP-26 (#63): a shell an agent opened connects on a device as fast
    /// as a session the user started, with the lines above its screen,
    /// also while its agent waits on it, reading its screen all the time.
    func testAnAgentsShellConnectsAsFastAsAnyOtherAlsoWhileItsAgentWaits() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (agent, _) = try startAgent("claude", title: "busy", client: mac)
        // Three thousand lines, and then a program that waits: in a shell
        // the agent opened, and in a session the user started.
        let lines = "sh -c 'seq 1 3000; exec cat'"
        XCTAssertFalse(agent.tool("shell_open", ["command": lines, "title": "the agent's"], in: self).failed)
        mac.connection.send(.create(CreateRequest(command: lines, cwd: root.path, title: "the user's")))
        waitUntil("both") { mac.sessions.contains { $0.title == "the agent's" } && mac.sessions.contains { $0.title == "the user's" } }
        let shell = try XCTUnwrap(mac.sessions.first { $0.title == "the agent's" }?.id)
        let own = try XCTUnwrap(mac.sessions.first { $0.title == "the user's" }?.id)
        XCTAssertTrue(agent.tool("shell_wait", ["session": shell, "until_text": "3000", "timeout_seconds": 20], in: self).text.contains("3000"))
        XCTAssertTrue(agent.tool("shell_read", ["session": own], in: self).failed, "the user's session is not the agent's to read")
        Thread.sleep(forTimeInterval: 0.5)

        /// A device that opens a session with 500 of the lines above its
        /// screen: how long until its screen is there, and what came.
        func open(_ session: SessionID) -> (took: TimeInterval, text: String) {
            let device = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
            var welcomed = false
            var text = ""
            device.onMessage = { if case .welcome = $0 { welcomed = true } }
            device.onOutput = { id, data in if id == session { text += String(decoding: data, as: UTF8.self) } }
            device.connect()
            waitUntil("the device connected") { welcomed }
            let started = Date()
            device.send(.attach(session: session, size: TermSize(cols: 60, rows: 30), history: 500))
            waitUntil("its screen", timeout: 30) { text.contains("3000") }
            let took = Date().timeIntervalSince(started)
            device.close()
            return (took, text)
        }

        let users = open(own)
        let idle = open(shell)
        // Its agent waits on it, for a text that does not come.
        let waiting = try agent.begin("shell_wait", ["session": shell, "until_text": "never there", "timeout_seconds": 60])
        Thread.sleep(forTimeInterval: 0.6)
        let busy = open(shell)
        XCTAssertEqual(agent.answers(to: waiting), [], "still waiting")
        try agent.notify("notifications/cancelled", ["requestId": waiting])
        print(
            String(
                format: "MEASURE a session of 3,000 lines opened on a device: the user's %.0f ms, an agent's shell %.0f ms, the same while its agent waits %.0f ms", users.took * 1000,
                idle.took * 1000, busy.took * 1000))

        // The lines above the screen came with it, each time.
        for opened in [users, idle, busy] {
            XCTAssertTrue(opened.text.contains("2600"), "a line above the screen is missing")
            XCTAssertFalse(opened.text.contains("\r\n2400\r\n"), "more than the 500 lines asked for")
        }
        // As fast as any other: not slower than the user's by more than half a second.
        XCTAssertLessThan(idle.took, users.took + 0.5)
        XCTAssertLessThan(busy.took, users.took + 0.5)

        // A program that clears the lines above its screen itself, as zsh's
        // `clear` does (ESC [ 3 J): those lines are gone on the host, for
        // every device, and that is the program's doing.
        let cleared = "sh -c 'seq 1 3000; printf \"\\033[3J\\033[H\\033[2J\"; echo after-the-clear; exec cat'"
        XCTAssertFalse(agent.tool("shell_open", ["command": cleared, "title": "cleared"], in: self).failed)
        waitUntil("the cleared shell") { mac.sessions.contains { $0.title == "cleared" } }
        let wiped = try XCTUnwrap(mac.sessions.first { $0.title == "cleared" }?.id)
        XCTAssertTrue(agent.tool("shell_wait", ["session": wiped, "until_text": "after-the-clear", "timeout_seconds": 20], in: self).text.contains("after-the-clear"))
        let device = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
        var text = ""
        var welcomed = false
        device.onMessage = { if case .welcome = $0 { welcomed = true } }
        device.onOutput = { id, data in if id == wiped { text += String(decoding: data, as: UTF8.self) } }
        device.connect()
        waitUntil("connected") { welcomed }
        device.send(.attach(session: wiped, size: TermSize(cols: 60, rows: 30), history: 500))
        waitUntil("its screen") { text.contains("after-the-clear") }
        XCTAssertFalse(text.contains("2600"), "the program cleared them: they are not kept behind its back")
        device.close()
    }

    func testAnAgentSeesOnlyTheShellsItOpened() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (first, firstID) = try startAgent("claude", title: "first", client: mac)
        let (second, _) = try startAgent("codex", title: "second", client: mac)
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path, title: "mine")))
        waitUntil("the user's session") { mac.sessions.contains { $0.title == "mine" } }
        let mine = try XCTUnwrap(mac.sessions.first { $0.title == "mine" }?.id)

        // MCP-5: it opens a shell, in its folder, marked as its own.
        let opened = first.tool("shell_open", ["command": "cat", "title": "echo"], in: self)
        XCTAssertFalse(opened.failed, opened.text)
        waitUntil("the shell to be listed") { mac.sessions.contains { $0.title == "echo" } }
        let shell = try XCTUnwrap(mac.sessions.first { $0.title == "echo" })
        XCTAssertEqual(shell.openedBy, firstID)
        XCTAssertEqual(shell.cwd, root.appendingPathComponent("first").path)
        XCTAssertEqual(first.tool("shell_list", in: self).text, "\(shell.id): echo, in \(shell.cwd)")
        // MCP-12: the agent's server only asks; it is not a device looking
        // at the shell. The Mac that shows it is the one whose size it takes.
        mac.connection.send(.attach(session: shell.id, size: TermSize(cols: 120, rows: 40)))
        waitUntil("the Mac told the size") {
            mac.messages.contains { if case .resized(shell.id, _, _) = $0 { return true } else { return false } }
        }
        let told = mac.messages.compactMap { message -> (TermSize, Bool)? in
            if case .resized(shell.id, let size, let driver) = message { return (size, driver) } else { return nil }
        }.last
        XCTAssertEqual(told?.1, true, "the Mac was told another device uses the shell")
        XCTAssertEqual(told?.0, TermSize(cols: 120, rows: 40))

        // What it types reaches the program; the screen it reads shows it.
        XCTAssertFalse(first.tool("shell_send", ["session": shell.id, "text": "hello", "keys": ["Return"]], in: self).failed)
        let waited = first.tool("shell_wait", ["session": shell.id, "until_text": "hello", "timeout_seconds": 10], in: self)
        XCTAssertTrue(waited.text.hasPrefix("“hello” is on the screen"), waited.text)
        XCTAssertTrue(first.tool("shell_read", ["session": shell.id], in: self).text.contains("hello"))

        // MCP-6: never the user's session, nor an agent's own.
        XCTAssertTrue(first.tool("shell_read", ["session": mine], in: self).failed)
        XCTAssertTrue(first.tool("shell_send", ["session": mine, "text": "rm -rf ~"], in: self).failed)
        XCTAssertTrue(second.tool("shell_read", ["session": firstID], in: self).failed)
        // MCP-20: a shell is its agent's alone: another agent neither sees
        // it, nor reads it, types into it or closes it, and is told to open
        // one of its own.
        XCTAssertEqual(second.tool("shell_list", in: self).text, "You have no shell open: open one with shell_open.")
        let read = second.tool("shell_read", ["session": shell.id], in: self)
        XCTAssertTrue(read.failed)
        XCTAssertFalse(read.text.contains("hello"))
        let typed = second.tool("shell_send", ["session": shell.id, "text": "again", "keys": ["Return"]], in: self)
        XCTAssertTrue(typed.failed)
        XCTAssertTrue(typed.text.contains("only the shells you opened") && typed.text.contains("shell_open"), typed.text)
        XCTAssertTrue(second.tool("shell_close", ["session": shell.id], in: self).failed)
        XCTAssertTrue(second.tool("shell_wait", ["session": shell.id, "quiet_seconds": 0.5, "timeout_seconds": 5], in: self).failed)
        // Nothing of it reached the program, and the shell still runs.
        XCTAssertFalse(first.tool("shell_read", ["session": shell.id], in: self).text.contains("again"))
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id })
        // It opens one of its own instead, which the first does not reach.
        XCTAssertFalse(second.tool("shell_open", ["command": "cat", "title": "other"], in: self).failed)
        waitUntil("the second's shell") { mac.sessions.contains { $0.title == "other" } }
        let other = try XCTUnwrap(mac.sessions.first { $0.title == "other" })
        XCTAssertFalse(second.tool("shell_send", ["session": other.id, "text": "mine", "keys": ["Return"]], in: self).failed)
        XCTAssertTrue(first.tool("shell_send", ["session": other.id, "text": "no"], in: self).failed)
        XCTAssertTrue(first.tool("shell_read", ["session": other.id], in: self).failed)
        XCTAssertEqual(first.tool("shell_list", in: self).text, "\(shell.id): echo, in \(shell.cwd)")
        XCTAssertFalse(second.tool("shell_close", ["session": other.id], in: self).failed)
        waitUntil("the second's shell to be closed", timeout: 15) { !mac.sessions.contains { $0.id == other.id } }

        // MCP-7: starting an agent is refused.
        let agent = first.tool("shell_open", ["command": "claude --resume x"], in: self)
        XCTAssertTrue(agent.failed)
        XCTAssertTrue(agent.text.contains("Starting an agent is not allowed"), agent.text)

        // MCP-8: when the agent's session ends, its shells stay, the user's.
        mac.connection.send(.kill(session: firstID))
        waitUntil("the agent's session to end") { !mac.sessions.contains { $0.id == firstID } }
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id }, "its shell stays")
        // Its MCP server ended with it, as an agent's does.

        // It is the user's now: no agent sees it, and nothing takes it
        // over. The user ends it.
        let (third, _) = try startAgent("copilot", title: "third", client: mac)
        XCTAssertEqual(third.tool("shell_list", in: self).text, "You have no shell open: open one with shell_open.")
        XCTAssertTrue(third.tool("shell_read", ["session": shell.id], in: self).failed)
        XCTAssertTrue(third.tool("shell_send", ["session": shell.id, "text": "taken"], in: self).failed)
        XCTAssertTrue(second.tool("shell_close", ["session": shell.id], in: self).failed)
        XCTAssertTrue(mac.sessions.contains { $0.id == shell.id })
        XCTAssertEqual(shell.openedByName(among: mac.sessions), "an agent that has ended")
        mac.connection.send(.kill(session: shell.id))
        waitUntil("the shell to be ended by the user", timeout: 15) { !mac.sessions.contains { $0.id == shell.id } }
    }

    /// SHELL-1, SHELL-2: how shells are started is kept by the host and
    /// told to every device; a program that does not run is refused. A
    /// shell the user opens is the program picked, and what is to be run
    /// first in it is typed at its prompt.
    func testTheShellPickedAndWhatItRunsFirst() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        // A shell of the test's own, so that no startup file of the person
        // running it is read: it says it was started, then is a plain `sh`.
        let started = root.appendingPathComponent("started"), ran = root.appendingPathComponent("ran")
        let program = root.appendingPathComponent("test-shell")
        try "#!/bin/sh\necho \"$0\" > '\(started.path)'\nexec /bin/sh -i\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)

        mac.connection.send(.setShellSettings(ShellSettings(program: "/nowhere/shell")))
        waitUntil("refused") { mac.messages.contains { if case .error(let text) = $0 { return text.contains("/nowhere/shell") } else { return false } } }
        let settings = ShellSettings(program: program.path, startup: "echo startup > '\(ran.path)'", agentStartup: "export AT_AGENT=on")
        mac.connection.send(.setShellSettings(settings))
        waitUntil("every device told") {
            mac.messages.contains { if case .shellSettings(let told, _, _) = $0 { return told == settings } else { return false } }
        }

        mac.connection.send(.create(CreateRequest(cwd: root.path, title: "mine")))
        waitUntil("the picked shell started", timeout: 15) { FileManager.default.fileExists(atPath: started.path) }
        waitUntil("what is run first, run", timeout: 15) { FileManager.default.fileExists(atPath: ran.path) }
        XCTAssertEqual(try String(contentsOf: ran, encoding: .utf8), "startup\n")
    }

    /// SHELL-3: what is run first in an agent's shell is run before its
    /// first prompt, not taken for one of the agent's commands; with the
    /// marks turned off, a command's end and exit code are not known.
    func testAnAgentsShellRunsItsStartupAndTheMarksCanBeTurnedOff() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        // zsh, the shell that is set up to say when its commands end, which
        // the login shell of the machine running the tests may not be: CI's
        // is bash.
        mac.connection.send(.setShellSettings(ShellSettings(program: "/bin/zsh", agentStartup: "export AT_AGENT=on")))
        waitUntil("told") { mac.messages.contains { if case .shellSettings(let told, _, _) = $0 { return told.agentStartup != "" } else { return false } } }
        let (agent, _) = try startAgent("claude", title: "starter", client: mac)
        let opened = agent.tool("shell_open", ["title": "work"], in: self)
        let shell = try XCTUnwrap(opened.text.range(of: #"shell \d+"#, options: .regularExpression).map { SessionID(opened.text[$0].dropFirst(6))! }, opened.text)
        let ran = agent.tool("shell_run", ["session": shell, "command": "echo agent:$AT_AGENT"], in: self)
        XCTAssertEqual(ran.text, "Exit code 0. Its output:\n\nagent:on")

        // A shell that cannot say when its commands end: bash, which is not
        // set up for it.
        mac.connection.send(.setShellSettings(ShellSettings(program: "/bin/bash", agentStartup: "export AT_AGENT=on")))
        waitUntil("told") { mac.messages.contains { if case .shellSettings(let told, _, _) = $0 { return told.program == "/bin/bash" } else { return false } } }
        let second = agent.tool("shell_open", ["title": "plain"], in: self)
        let plain = try XCTUnwrap(second.text.range(of: #"shell \d+"#, options: .regularExpression).map { SessionID(second.text[$0].dropFirst(6))! }, second.text)
        let typed = agent.tool("shell_run", ["session": plain, "command": "echo plain", "timeout_seconds": 10], in: self)
        XCTAssertTrue(typed.text.hasPrefix("This shell does not say when a command ends"), typed.text)
        XCTAssertTrue(typed.text.contains("plain"), typed.text)
    }

    /// MCP-30: in a shell it opened, an agent runs a command and is told
    /// its exit code and its output, in one call: a command of several
    /// lines as one; one that outlasts the call keeps running, another is
    /// refused meanwhile, and waiting tells how it ended; one stopped with
    /// Control C ends with 130. The user's zsh startup files are read.
    func testAnAgentRunsCommandsAndIsToldHowTheyEnded() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        // zsh, which the login shell of CI's machine is not.
        mac.connection.send(.setShellSettings(ShellSettings(program: "/bin/zsh")))
        waitUntil("told") { mac.messages.contains { if case .shellSettings(let told, _, _) = $0 { return told.program == "/bin/zsh" } else { return false } } }
        let (agent, _) = try startAgent("claude", title: "runner", client: mac)
        let opened = agent.tool("shell_open", ["title": "work"], in: self)
        XCTAssertFalse(opened.failed, opened.text)
        XCTAssertTrue(opened.text.hasSuffix("Run commands in it with shell_run."), opened.text)
        let shell = try XCTUnwrap(opened.text.range(of: #"shell \d+"#, options: .regularExpression).map { SessionID(opened.text[$0].dropFirst(6))! })

        let ran = agent.tool("shell_run", ["session": shell, "command": "echo hello; (exit 3)"], in: self)
        XCTAssertFalse(ran.failed, ran.text)
        XCTAssertTrue(ran.text.hasPrefix("Exit code 3."), ran.text)
        XCTAssertTrue(ran.text.hasSuffix("hello"), "only what the command wrote: \(ran.text)")
        // Several lines, one command.
        let lines = agent.tool("shell_run", ["session": shell, "command": "printf 'one\\n'\nprintf 'two\\n'"], in: self)
        XCTAssertTrue(lines.text.hasPrefix("Exit code 0."), lines.text)
        XCTAssertTrue(lines.text.hasSuffix("one\ntwo"), lines.text)
        // The marks are not left in what the user's zsh is told.
        let told = agent.tool("shell_run", ["session": shell, "command": "echo ${ZDOTDIR-unset} ${AGENTTERM_USER_ZDOTDIR-gone}"], in: self)
        XCTAssertTrue(told.text.hasSuffix("gone"), told.text)
        XCTAssertFalse(told.text.contains("shell-integration"), "zsh started from it would read AgentTerm's files: \(told.text)")

        // Longer than the call: it goes on, and is waited for.
        let long = agent.tool("shell_run", ["session": shell, "command": "sleep 3; echo done", "timeout_seconds": 1], in: self)
        XCTAssertTrue(long.text.hasPrefix("Still running after"), long.text)
        XCTAssertTrue(long.text.contains("shell_wait"), long.text)
        let refused = agent.tool("shell_run", ["session": shell, "command": "echo meanwhile"], in: self)
        XCTAssertTrue(refused.failed)
        XCTAssertTrue(refused.text.contains("still running"), refused.text)
        let waited = agent.tool("shell_wait", ["session": shell, "timeout_seconds": 20], in: self)
        XCTAssertTrue(waited.text.hasPrefix("Exit code 0."), waited.text)
        XCTAssertTrue(waited.text.hasSuffix("done"), waited.text)

        // Stopped.
        XCTAssertTrue(agent.tool("shell_run", ["session": shell, "command": "sleep 30", "timeout_seconds": 1], in: self).text.hasPrefix("Still running"))
        XCTAssertFalse(agent.tool("shell_send", ["session": shell, "keys": ["Control C"]], in: self).failed)
        let stopped = agent.tool("shell_wait", ["session": shell, "timeout_seconds": 10], in: self)
        XCTAssertTrue(stopped.text.hasPrefix("Exit code 130."), stopped.text)
    }
}

/// PERF-2: a folder whose list is larger than a message could hold arrives
/// whole, in pieces.
final class LargeMessageTests: XCTestCase {
    func testAFolderOfManyEntriesIsListedWhole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let long = String(repeating: "n", count: 150)
        for index in 0..<25_000 { FileManager.default.createFile(atPath: root.appendingPathComponent("\(long)-\(index)").path, contents: nil) }
        let token = "test-token-0123456789abcdef0123456789"
        let server = HostServer(configuration: .init(port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }))
        let port = try server.start()
        defer { server.stop() }
        let connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "phone")
        var listed: [FileEntry]?
        connection.onMessage = { if case .files(_, let entries) = $0 { listed = entries } }
        connection.connect()
        connection.send(.files(path: root.path))
        let deadline = Date().addingTimeInterval(30)
        while listed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(MessageCoding.encode(ServerMessage.files(path: root.path, entries: listed ?? [])).count, 4 * 1024 * 1024, "larger than one message may be")
        XCTAssertEqual(listed?.count, 25_000)
    }
}

/// MCP-10: the agents are asked to run their commands in shells the user
/// sees, with no switch; an agent whose words the user emptied is told
/// nothing, its server's instructions included.
final class AgentsUseShellsTests: XCTestCase {
    func testTheAgentsAreAskedToUseTheShellsUnlessTheirWordsAreEmptied() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-use-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let told = root.appendingPathComponent("told")
        // A stand-in for Claude Code that writes down how it was started,
        // a line each time: what it is told has lines of its own.
        try "#!/bin/sh\nargs=$(printf '%s' \"$*\" | tr '\\n' ' ')\nprintf '%s|%s\\n' \"$AGENTTERM_MCP\" \"$args\" >> '\(told.path)'\nexec sleep 600\n".write(
            to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents.path) }, statusLineTool: "/usr/bin/true",
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.agentsDirectory = agents.path
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        configuration.agentShells = AgentShellsSetup(directory: root.appendingPathComponent("state"), tool: "/usr/bin/true") { _ in true }
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        var prompts: [String: String]?
        client.onMessage = { if case .agentPrompts(let custom, _) = $0 { prompts = custom } }
        client.connect()
        func spin(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        func lines() -> [String] { ((try? String(contentsOf: told, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        spin { prompts != nil }

        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        spin { lines().count == 1 }
        func says(_ line: String, _ word: String) -> Bool { line.split(separator: "|").first?.split(separator: " ").contains { $0 == word } == true }
        let first = try XCTUnwrap(lines().first)
        XCTAssertTrue(says(first, "use"), first)
        XCTAssertTrue(first.contains("--append-system-prompt"), first)
        XCTAssertTrue(first.contains("shell_open") && first.contains("browser_open"), first)

        // Its words emptied in Settings > Agents: nothing in its system
        // prompt, and its server asks nothing of it either.
        client.send(.setAgentPrompt(agent: "claude", text: ""))
        spin { prompts?["claude"] == "" }
        client.send(.create(CreateRequest(command: "claude", cwd: root.path)))
        spin { lines().count == 2 }
        let second = try XCTUnwrap(lines().last)
        XCTAssertFalse(says(second, "use"), second)
        XCTAssertFalse(second.contains("--append-system-prompt"), second)
        XCTAssertFalse(second.contains("shell_open"), second)

        // MCP-4: each session is given the server on its command line,
        // whatever it is asked.
        for line in [first, second] {
            XCTAssertTrue(line.contains("--mcp-config") && line.contains(#""command":"/usr/bin/true""#), line)
        }
    }

    func testTheServerSaysSoInItsInstructions() {
        func instructions(_ server: AgentShellsMCP) -> String {
            let reply = server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#) ?? ""
            let result = ((try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any])?["result"] as? [String: Any]
            return result?["instructions"] as? String ?? ""
        }
        XCTAssertEqual(instructions(AgentShellsMCP(ask: { _ in .done }, version: "t", useShells: true)), AgentShellsInstructions.useShells)
        XCTAssertFalse(instructions(AgentShellsMCP(ask: { _ in .done }, version: "t", useShells: false)).contains("rather than with your own"))
    }
}

// MARK: The browser (#76)

extension AgentShellsMCPTests {
    /// BROWSER-4: each browser tool makes its request of the browser; what
    /// is missing is said without asking; a picture is given as an image.
    func testEachBrowserToolMakesItsRequest() throws {
        var asked: [BrowserRequest] = []
        let server = AgentShellsMCP(
            ask: { _ in .done },
            askBrowser: { request in
                asked.append(request)
                if case .screenshot = request { return .image(png: Data([0x89, 0x50, 0x4E, 0x47]), text: "Tab 4 at http://localhost:3000/") }
                return .text("done")
            }, version: "test")
        let tools = (call(server, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, AgentShellsMCP.tools.count + AgentShellsMCP.browserTools.count)
        // browser_profiles came on 2026-11-16, with browser_open's profile
        // and private; browser_upload the same day.
        XCTAssertEqual(AgentShellsMCP.browserTools.count, 22)
        XCTAssertTrue(tools.contains { $0["name"] as? String == "browser_snapshot" })
        XCTAssertFalse(tool(server, "browser_open", ["url": "localhost:3000"]).failed)
        XCTAssertFalse(tool(server, "browser_profiles").failed)
        XCTAssertFalse(tool(server, "browser_open", ["profile": "Work"]).failed)
        XCTAssertFalse(tool(server, "browser_open", ["private": true]).failed)
        XCTAssertFalse(tool(server, "browser_upload", ["tab": "4", "ref": "e7", "paths": ["report.txt"]]).failed)
        XCTAssertEqual(tool(server, "browser_upload", ["tab": "4", "ref": "e7"]).text, "Give `paths` as `paths`.")
        XCTAssertFalse(tool(server, "browser_click", ["tab": "4", "ref": "e3"]).failed)
        XCTAssertFalse(tool(server, "browser_type", ["tab": 4, "ref": "e5", "text": "hi", "submit": true]).failed)
        XCTAssertFalse(tool(server, "browser_emulate", ["tab": "4", "device": "iphone 16"]).failed)
        XCTAssertFalse(tool(server, "browser_back", ["tab": "4"]).failed)
        let missing = tool(server, "browser_click", ["tab": "4"])
        XCTAssertTrue(missing.failed)
        XCTAssertEqual(missing.text, "Give `ref` as `ref`.")
        XCTAssertTrue(tool(server, "browser_emulate", ["tab": "4", "device": "Nokia"]).text.contains("There is no device called “Nokia”"))
        XCTAssertEqual(
            asked,
            [
                .open(url: "localhost:3000", profile: nil, private: false), .profiles, .open(url: nil, profile: "Work", private: false),
                .open(url: nil, profile: nil, private: true), .upload(tab: "4", ref: "e7", paths: ["report.txt"]),
                .click(tab: "4", ref: "e3", double: false), .type(tab: "4", ref: "e5", text: "hi", submit: true, append: false),
                .emulate(tab: "4", device: BrowserDevice.preset(named: "iPhone 16")), .history(tab: "4", step: -1),
            ])
        let picture = call(server, "tools/call", ["name": "browser_screenshot", "arguments": ["tab": "4"]])["result"] as? [String: Any] ?? [:]
        let content = picture["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")
        XCTAssertEqual(content.first?["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        let instructions = (call(server, "initialize")["result"] as? [String: Any])?["instructions"] as? String ?? ""
        XCTAssertTrue(instructions.contains("browser_open"), instructions)
    }

    /// PROMPT-3: the session's variable names its agent, and a server given
    /// the user's words gives them as its instructions.
    func testTheServerGivesTheAgentsOwnInstructions() {
        let session = AgentShellsMCP.Session(port: 7717, key: "key", useShells: true, agent: "codex")
        XCTAssertEqual(session.variable(channel: .release), "7717 key release use agent:codex")
        XCTAssertEqual(AgentShellsMCP.Session(variable: session.variable(channel: .release), channel: .release), session)
        XCTAssertNil(AgentShellsMCP.Session(variable: "7717 key release", channel: .release)?.agent)
        let server = AgentShellsMCP(ask: { _ in .done }, askBrowser: { _ in .text("") }, version: "t", useShells: true, instructions: "Mine.")
        XCTAssertEqual((call(server, "initialize")["result"] as? [String: Any])?["instructions"] as? String, "Mine.")
    }

    /// BROWSER-5: devices by name, and that only the agent that opened a
    /// tab sees and drives it; the user's no agent does.
    func testDevicesAndWhoMayDriveATab() {
        XCTAssertEqual(BrowserDevice.preset(named: "pixel 9")?.width, 412)
        XCTAssertNil(BrowserDevice.preset(named: "pixel"))
        let info = BrowserTabInfo(id: "4", title: "", url: "http://localhost:3000/", project: "/p", openedBy: 7)
        XCTAssertTrue(info.reachable(by: 7))
        XCTAssertFalse(info.reachable(by: 8))
        XCTAssertFalse(BrowserTabInfo(id: "5", title: "", url: "", project: "/p").reachable(by: 7), "an agent reaches the user's tab")
        XCTAssertEqual(info.displayTitle, "http://localhost:3000/")
        XCTAssertTrue(BrowserRequest.click(tab: "4", ref: "e1", double: false).acts)
        XCTAssertFalse(BrowserRequest.snapshot(tab: "4", within: nil).acts, "looking at a tab is not acting on it")
    }
}

extension AgentShellsHostTests {
    /// PROMPT-2: what the user writes for an agent in Settings is kept by
    /// the host, told to every device, and given to the agent's new
    /// session: its MCP server gives it as its instructions. Back to the
    /// default, it is gone.
    func testTheUsersWordsForAnAgentAreWhatItIsTold() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let words = "In AgentTerm, use its browser for every web page: the browser_ tools of agentterm."
        mac.connection.send(.setAgentPrompt(agent: "claude", text: words))
        waitUntil("every device told") {
            mac.messages.contains { if case .agentPrompts(let custom, _) = $0 { return custom["claude"] == words } else { return false } }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: HostServer.agentPromptsFile.path), "the host did not keep them")

        let (agent, _) = try startAgent("claude", title: "told", client: mac)
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 900, "method": "initialize", "params": [:]]
        try agent.input.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8))
        var instructions: String?
        waitUntil("the server's instructions") {
            let text = (try? String(contentsOf: agent.output, encoding: .utf8)) ?? ""
            instructions = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .first { ($0["id"] as? Int) == 900 }
                .flatMap { ($0["result"] as? [String: Any])?["instructions"] as? String }
            return instructions != nil
        }
        XCTAssertEqual(instructions, words)

        mac.connection.send(.setAgentPrompt(agent: "claude", text: nil))
        waitUntil("back to the default") {
            mac.messages.last { if case .agentPrompts = $0 { return true } else { return false } }
                .map { if case .agentPrompts(let custom, _) = $0 { return custom["claude"] == nil } else { return false } } ?? false
        }
    }

    /// BROWSER-1: with no app showing the browser, an agent is told why at
    /// once, not after a wait that says nothing.
    func testAnAgentIsToldAtOnceWhenNoAppShowsTheBrowser() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        let (agent, _) = try startAgent("claude", title: "first", client: mac)
        let started = Date()
        let answer = agent.tool("browser_open", ["url": "http://localhost:3000"], in: self)
        XCTAssertTrue(answer.failed)
        XCTAssertEqual(answer.text, BrowserWords.noApp)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// BROWSER-2: the app that shows the browser is asked, for the agent's
    /// session, and its answer reaches the agent; when the app goes, what
    /// waits for it is answered with why. A device does not drive a page.
    func testTheAppThatShowsTheBrowserIsAskedForTheAgent() throws {
        let mac = Client(port: port, token: token)
        waitUntil("connected") { !mac.messages.isEmpty }
        var calls: [(id: Int, agent: SessionID?, request: BrowserRequest)] = []
        mac.connection.onMessage = { [weak mac] message in
            mac?.messages.append(message)
            guard case .browserCall(let id, let agent, let request) = message else { return }
            calls.append((id, agent, request))
            if case .tabs = request {
                mac?.connection.send(.browserReply(id: id, result: .tabs([BrowserTabInfo(id: "4", title: "Shop", url: "http://localhost:3000/", project: "", openedBy: agent)])))
            }
        }
        mac.connection.send(.browserProvider(true))
        mac.connection.send(.browserTabs([BrowserTabInfo(id: "4", title: "Shop", url: "http://localhost:3000/", project: "")]))
        let (agent, agentID) = try startAgent("claude", title: "first", client: mac)
        let tabs = agent.tool("browser_tabs", in: self)
        XCTAssertFalse(tabs.failed, tabs.text)
        XCTAssertEqual(tabs.text, "4: Shop — http://localhost:3000/")
        XCTAssertEqual(calls.first?.agent, agentID, "the app was not told which agent asks")

        // A device asks for the tabs and is answered by the host; to click
        // in one it is refused.
        let device = Client(port: port, token: token)
        waitUntil("the device connected") { !device.messages.isEmpty }
        device.connection.send(.browserAsk(id: 1, request: .tabs))
        device.connection.send(.browserAsk(id: 2, request: .click(tab: "4", ref: "e1", double: false)))
        waitUntil("the device answered") {
            device.messages.contains { if case .browserAnswer(2, .refused) = $0 { return true } else { return false } }
                && device.messages.contains { if case .browserAnswer(1, .tabs(let list)) = $0 { return list.map(\.id) == ["4"] } else { return false } }
        }
        XCTAssertEqual(calls.count, 1, "a device's click reached the app")

        // A call the app does not answer, and then the app goes.
        let pending = try agent.begin("browser_snapshot", ["tab": "4"])
        waitUntil("the app asked") { calls.count == 2 }
        XCTAssertEqual(calls.last?.request, .snapshot(tab: "4", within: nil))
        mac.connection.send(.browserProvider(false))
        waitUntil("the agent told why") { !agent.answers(to: pending).isEmpty }
        XCTAssertEqual(agent.answers(to: pending), [BrowserWords.noApp])
        waitUntil("the device told there are no tabs") {
            device.messages.contains { if case .browserTabs(let list) = $0 { return list.isEmpty } else { return false } }
        }
    }
}
