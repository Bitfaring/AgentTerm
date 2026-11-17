import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What the agent in a session is doing, from what it tells its hooks (#3).
///
/// What each agent tells its hooks was recorded on 2026-11-13 by starting
/// each with hooks that only wrote it down: Claude Code 2.1.323, Copilot
/// CLI 1.0.110, Antigravity 1.5.7. Codex 0.167.2 runs no hook until the
/// user trusts it, so its events are as its documentation describes them.
/// Paths and identifiers are left out of what is kept here.
final class AgentStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func change(_ agent: String, _ event: String, _ json: String) -> AgentHooks.Change {
        let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return AgentHooks.change(agent: agent, event: event, input: input, now: at)
    }

    // MARK: - Each agent, from what it really says

    /// AGENT-1: Claude Code.
    func testClaudeCode() {
        XCTAssertEqual(
            change("claude", "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"Run touch probe2.txt","permission_mode":"default"}"#),
            .set(.working(since: at)))
        let ask =
            #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which colour do you prefer: red or blue?","header":"Colour","options":[{"label":"Red","description":"Choose red"},{"label":"Blue","description":"Choose blue"}],"multiSelect":false}]}}"#
        let question = AgentState.waitingForAnswer(AgentQuestion(text: "Which colour do you prefer: red or blue?", choices: ["Red", "Blue"]))
        XCTAssertEqual(change("claude", "PreToolUse", ask), .set(question))
        XCTAssertEqual(change("claude", "PermissionRequest", ask.replacingOccurrences(of: "PreToolUse", with: "PermissionRequest")), .set(question))
        XCTAssertEqual(
            change("claude", "PreToolUse", #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"touch probe2.txt"}}"#),
            .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "claude", "PermissionRequest",
                #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch probe2.txt","description":"Create empty file"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#
            ),
            .set(.waitingForPermission(AgentQuestion(text: "touch probe2.txt"))))
        XCTAssertEqual(
            change("claude", "Notification", #"{"hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#),
            .keep, "the permission was told already")
        XCTAssertEqual(change("claude", "PostToolUse", #"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change("claude", "Stop", #"{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"You picked red, and I ran touch probe2.txt."}"#),
            .set(.done(said: "You picked red, and I ran touch probe2.txt.")))
    }

    /// AGENT-2: Copilot CLI, which names the event only in the command.
    func testCopilotCLI() {
        XCTAssertEqual(change("copilot", "userPromptSubmitted", #"{"prompt":"Ask me which colour"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "copilot", "preToolUse",
                #"{"toolName":"ask_user","toolArgs":{"message":"Which colour do you choose?","requestedSchema":{"properties":{"colour":{"type":"string","title":"Colour","enum":["red","blue"]}}}}}"#
            ),
            .set(.waitingForAnswer(AgentQuestion(text: "Which colour do you choose?", choices: ["red", "blue"]))))
        XCTAssertEqual(change("copilot", "preToolUse", #"{"toolName":"bash","toolArgs":{"command":"touch probe.txt"}}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change("copilot", "permissionRequest", #"{"hookName":"permissionRequest","toolName":"bash","toolInput":{"command":"touch probe.txt"},"permissionSuggestions":[]}"#),
            .set(.waitingForPermission(AgentQuestion(text: "touch probe.txt"))))
        XCTAssertEqual(change("copilot", "postToolUse", #"{"toolName":"bash"}"#), .set(.working(since: at)))
        XCTAssertEqual(change("copilot", "agentStop", #"{"stopReason":"end_turn","stop_hook_active":false}"#), .set(.done(said: nil)))
    }

    /// AGENT-3: Antigravity, which says nothing while it waits for
    /// permission: while a tool runs, its state is not known.
    func testAntigravity() {
        XCTAssertEqual(change("agy", "PreInvocation", #"{"hookEventName":"PreInvocation","invocationNum":0}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "agy", "PreToolUse",
                #"{"hookEventName":"PreToolUse","toolCall":{"name":"ask_question","args":{"questions":[{"is_multi_select":false,"options":["(Recommended) Red","Blue"],"question":"Which colour do you choose?"}]}}}"#
            ),
            .set(.waitingForAnswer(AgentQuestion(text: "Which colour do you choose?", choices: ["(Recommended) Red", "Blue"]))))
        XCTAssertEqual(
            change("agy", "PreToolUse", #"{"hookEventName":"PreToolUse","toolCall":{"name":"run_command","args":{"CommandLine":"touch probe.txt"}}}"#),
            .set(nil), "running or waiting for permission: not known")
        XCTAssertEqual(change("agy", "PostToolUse", #"{"hookEventName":"PostToolUse","error":""}"#), .set(.working(since: at)))
        XCTAssertEqual(change("agy", "Stop", #"{"hookEventName":"Stop","fullyIdle":false,"terminationReason":"NO_TOOL_CALL"}"#), .keep)
        XCTAssertEqual(change("agy", "Stop", #"{"hookEventName":"Stop","fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}"#), .set(.done(said: nil)))
        XCTAssertEqual(AgentHooks.reply(agent: "agy", event: "PreToolUse"), #"{"decision":"allow"}"#, "leaves the decision to its own rules")
        XCTAssertNil(AgentHooks.reply(agent: "claude", event: "PreToolUse"))
    }

    /// AGENT-4: Codex, as its documentation describes its hooks.
    func testCodex() {
        XCTAssertEqual(change("codex", "UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"x"}"#), .set(.working(since: at)))
        XCTAssertEqual(
            change(
                "codex", "PermissionRequest",
                #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch probe.txt","description":"Create the probe file"}}"#),
            .set(.waitingForPermission(AgentQuestion(text: "Create the probe file"))))
        XCTAssertEqual(change("codex", "Stop", #"{"hook_event_name":"Stop","last_assistant_message":"Done."}"#), .set(.done(said: "Done.")))
        XCTAssertEqual(change("codex", "Interrupt", #"{"hook_event_name":"Interrupt"}"#), .set(nil))
    }

    // MARK: - What each agent is given, in its own configuration (#129)

    private func setup(_ root: URL, name: String = "agentterm-dev", prompt: String? = nil) -> AgentSetup {
        AgentSetup(
            directory: root.appendingPathComponent("setup"), tool: "/Apps/My App's/agenttermd", home: root.appendingPathComponent("home").path, name: name,
            environment: [:], locate: { [] }, prompt: { _ in prompt }, run: { _ in nil })
    }

    private func json(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    /// AGENT-13 (#129): each agent's plugin, which `agenttermd setup` adds to
    /// its own configuration, has its hooks, the one of its start among
    /// them, each running `agenttermd hook <agent> <event>`: the same
    /// command for every session, so that an agent that trusts a hook by
    /// its command asks once; and AgentTerm's MCP server.
    func testEachAgentsPluginHasItsHooksTheSameForEverySession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = setup(root)

        // Claude Code: a marketplace of one plugin, its hooks and its server.
        let claude = try setup.writeClaudeMarketplace()
        let market = try json(claude.appendingPathComponent(".claude-plugin/marketplace.json"))
        XCTAssertEqual(market["name"] as? String, "agentterm-dev")
        XCTAssertEqual((market["plugins"] as? [[String: Any]])?.first?["source"] as? String, "./plugin")
        let hooks = try XCTUnwrap(try json(claude.appendingPathComponent("plugin/hooks/hooks.json"))["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(["SessionStart"] + AgentHooks.claudeEvents))
        let stop = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "'/Apps/My App'\\''s/agenttermd' hook claude Stop")
        let servers = try XCTUnwrap(try json(claude.appendingPathComponent("plugin/.mcp.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["agentterm-dev"]?["command"] as? String, "/Apps/My App's/agenttermd")
        XCTAssertEqual(servers["agentterm-dev"]?["args"] as? [String], ["mcp"])

        // Codex: the server only, which names the session's variable, as
        // Codex passes no other (its hooks are in config.toml).
        let codex = try setup.writeCodexMarketplace()
        let codexServer = try XCTUnwrap((try json(codex.appendingPathComponent("plugin/.mcp.json"))["mcpServers"] as? [String: [String: Any]])?["agentterm-dev"])
        XCTAssertEqual(codexServer["env_vars"] as? [String], [HostServer.agentShellsVariable])
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent("plugin/hooks/hooks.json").path))

        // Copilot CLI: its own layout, with the hooks of its own names.
        let copilot = try setup.writeCopilotMarketplace()
        let plugin = try json(copilot.appendingPathComponent("plugin/hooks.json"))
        XCTAssertEqual(plugin["version"] as? Int, 1)
        let copilotHooks = try XCTUnwrap(plugin["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(copilotHooks.keys), Set(["sessionStart"] + AgentHooks.copilotEvents))
        XCTAssertEqual(copilotHooks["agentStop"]?.first?["bash"] as? String, "'/Apps/My App'\\''s/agenttermd' hook copilot agentStop")
        XCTAssertNotNil(FileManager.default.contents(atPath: copilot.appendingPathComponent("plugin/plugin.json").path))
        XCTAssertNotNil(FileManager.default.contents(atPath: copilot.appendingPathComponent("plugin/.mcp.json").path))

        // Antigravity: its own layout: a tool's hooks for every tool.
        let agy = try setup.writeAntigravityPlugin()
        let agyHooks = try XCTUnwrap(try json(agy.appendingPathComponent("hooks.json"))["agentterm-dev"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(agyHooks.keys), Set(["SessionStart"] + AgentHooks.antigravityEvents))
        XCTAssertEqual(agyHooks["PreToolUse"]?.first?["matcher"] as? String, "*")
        XCTAssertEqual(agyHooks["Stop"]?.first?["command"] as? String, "'/Apps/My App'\\''s/agenttermd' hook agy Stop")
        XCTAssertNotNil(FileManager.default.contents(atPath: agy.appendingPathComponent("mcp_config.json").path))

        // Nothing of a session is in any of it.
        for folder in [claude, codex, copilot, agy] {
            let files = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
            for file in files {
                let text = (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
                XCTAssertFalse(text.contains("session-"), file)
            }
        }
    }

    /// SCHED-23 (#11, #129): a schedule's run of Antigravity trusts the
    /// schedule's folder for that run, next to those the user trusts, whose
    /// settings are left as they are.
    func testAScheduledAntigravityTrustsItsFolderForThatRun() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        let settingsFile = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        try #"{"trustedWorkspaces":["/Users/someone/work"],"model":"x"}"#.write(to: settingsFile, atomically: true, encoding: .utf8)
        let arguments = try XCTUnwrap(AgentHooks.antigravityTrust(["/Users/someone/project"], home: home.path))
        let words = String(decoding: Subprocess.run("/bin/sh", ["-c", "printf '%s\\n' x" + arguments])?.output ?? Data(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(words.dropFirst().first, "--settings")
        let trusted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(words[2].utf8)) as? [String: Any])
        XCTAssertEqual(trusted["trustedWorkspaces"] as? [String], ["/Users/someone/work", "/Users/someone/project"])
        XCTAssertEqual(try String(contentsOf: settingsFile, encoding: .utf8), #"{"trustedWorkspaces":["/Users/someone/work"],"model":"x"}"#)
    }

    /// AGENT-14 (#129, principle 7): Codex keeps hooks only in its
    /// config.toml, where each build's are a block of their own between
    /// marks, after the user's own; taking one build's out leaves the
    /// other's and the user's as they were.
    func testEachBuildsCodexHooksAreABlockOfTheirOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("home/.codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let own = "model = \"o3\"\n\n[mcp_servers.mine]\ncommand = \"mine\"\n"
        try own.write(to: config, atomically: true, encoding: .utf8)
        let release = setup(root, name: "agentterm"), development = setup(root, name: "agentterm-dev")
        try release.addCodexHooks(path: "/no/codex")
        try development.addCodexHooks(path: "/no/codex")
        try release.addCodexHooks(path: "/no/codex")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(own), text)
        XCTAssertEqual(text.components(separatedBy: "# >>> AgentTerm's hooks (agentterm)").count, 2, "the release's block twice: \(text)")
        XCTAssertEqual(text.components(separatedBy: "# >>> AgentTerm's hooks (agentterm-dev)").count, 2)
        XCTAssertEqual(text.components(separatedBy: "[[hooks.Stop]]").count, 3)
        XCTAssertTrue(text.contains(#"hooks = [{ type = "command", command = "'/Apps/My App'\\''s/agenttermd' hook codex SessionStart" }]"#), text)
        try release.removeCodexHooks()
        let left = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(left.hasPrefix(own), left)
        XCTAssertFalse(left.contains("(agentterm)\n") || left.contains("hooks (agentterm),"), left)
        XCTAssertTrue(left.contains("# >>> AgentTerm's hooks (agentterm-dev)"), left)
        try development.removeCodexHooks()
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), own)
    }

    /// MCP-13: Copilot CLI and Antigravity are told to run their commands in
    /// shells the user sees as Claude Code and Codex are by AgentTerm's MCP
    /// server, which they do not hear: Copilot CLI through a folder of
    /// instructions its environment names, in every session; Antigravity
    /// through a rule of its plugin. Not when they are told nothing.
    func testCopilotAndAntigravityAreToldToUseTheShells() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-told-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks")

        // Antigravity: a rule always on, in its plugin.
        let plugin = try setup(root, prompt: AgentShellsInstructions.useShells).writeAntigravityPlugin()
        let rule = plugin.appendingPathComponent("rules/agentterm-dev.md")
        let text = try String(contentsOf: rule, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\ntrigger: always_on\n---\n"), text)
        XCTAssertTrue(text.contains(AgentShellsInstructions.useShells))
        // Read outside AgentTerm too: it says when it holds.
        XCTAssertTrue(text.contains("inside AgentTerm and nowhere else"), text)
        _ = try setup(root, prompt: nil).writeAntigravityPlugin()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rule.path), "turned off, the rule is still there")

        // Copilot CLI: a folder of instructions it is told of, next to any
        // the user's own environment names.
        let environment = try AgentHooks.instructionsEnvironment(agent: "copilot", directory: hooks, prompt: AgentShellsInstructions.useShells, current: ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/mine"])
        let folder = hooks.appendingPathComponent("copilot-instructions").path
        XCTAssertEqual(environment, ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/mine," + folder])
        let instructions = try String(contentsOfFile: folder + "/instructions/agentterm.instructions.md", encoding: .utf8)
        XCTAssertTrue(instructions.hasPrefix("---\napplyTo: \"**\"\n---\n"), instructions)
        XCTAssertTrue(instructions.contains(AgentShellsInstructions.useShells))
        XCTAssertEqual(try AgentHooks.instructionsEnvironment(agent: "copilot", directory: hooks, prompt: nil, current: [:]), [:])
        XCTAssertEqual(try AgentHooks.instructionsEnvironment(agent: "claude", directory: hooks, prompt: AgentShellsInstructions.useShells, current: [:]), [:])
    }

    /// PROMPT-1 (#129): Claude Code and Codex are told what AgentTerm says
    /// through its MCP server's instructions, which both give the model
    /// (Claude Code 2.1.326 was seen to on 2026-11-17): the user's words or
    /// the default, and nothing when there is nothing to say; the default
    /// names the browser's tools and the server they are of.
    func testClaudeAndCodexAreToldThroughTheServersInstructions() throws {
        func initialize(_ server: AgentShellsMCP) -> [String: Any]? {
            let line = server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
            return (line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any])?["result"] as? [String: Any]
        }
        let told = AgentShellsMCP(ask: { _ in .done }, version: "test", useShells: true, instructions: "Use AgentTerm's browser.")
        XCTAssertEqual(initialize(told)?["instructions"] as? String, "Use AgentTerm's browser.")

        let both = try XCTUnwrap(AgentShellsInstructions.told(useShells: true, browser: true, server: "agentterm-dev"))
        XCTAssertTrue(both.contains("shell_open") && both.contains("browser_open"), both)
        XCTAssertTrue(both.contains("the agentterm-dev MCP server"), both)
        XCTAssertTrue(both.contains("Claude in Chrome"), "the other way to a browser is not named: \(both)")
        XCTAssertEqual(AgentShellsInstructions.told(useShells: false, browser: true, server: "x"), AgentShellsInstructions.browser(server: "x"))
        XCTAssertNil(AgentShellsInstructions.told(useShells: false, browser: false))
    }

    func testWhatMayStopATurn() {
        XCTAssertTrue(AgentHooks.mayStopATurn(Data([0x1b])))
        XCTAssertTrue(AgentHooks.mayStopATurn(Data([0x03])))
        XCTAssertFalse(AgentHooks.mayStopATurn(Data("\u{1b}[A".utf8)), "an arrow key")
        XCTAssertFalse(AgentHooks.mayStopATurn(Data("hello\r".utf8)))
    }
}

/// A host with sessions whose stand-in agents tell their hooks what real
/// ones do, through the real `agenttermd hook`.
final class AgentStateHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        /// Every state a session was told to be in, in order, one for each change.
        func states(of title: String) -> [AgentState?] {
            var seen: [AgentState?] = []
            for case .sessions(let list) in messages {
                guard let session = list.first(where: { $0.title == title }) else { continue }
                if seen.isEmpty || seen.last! != session.state { seen.append(session.state) }
            }
            return seen
        }
    }

    private var root: URL!
    private var server: HostServer!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    /// How long the stand-in Mac has been left alone, in seconds.
    private var idle: TimeInterval = 0
    /// Whether the host holds the Mac awake now, through the stand-in hold.
    private var held = false
    private let holdLock = NSLock()
    private var isHeld: Bool {
        holdLock.lock()
        defer { holdLock.unlock() }
        return held
    }
    private var tool: URL { Bundle(for: AgentStateHostTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-state-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, statusLineTool: tool.path,
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = root.appendingPathComponent("hooks")
        configuration.home = root.path
        configuration.holdAwake = { [weak self] held, _ in
            self?.holdLock.lock()
            self?.held = held
            self?.holdLock.unlock()
            return true
        }
        configuration.isOnPower = { true }
        configuration.idleSeconds = { [weak self] in
            self?.holdLock.lock()
            defer { self?.holdLock.unlock() }
            return self?.idle
        }
        configuration.refreshInterval = 0.2
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

    /// A stand-in for Claude Code, under its name: it tells its hooks, as
    /// Claude Code does, through the command its settings name, then waits
    /// for a line on its input before each next step.
    private func standIn() throws -> URL {
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        try """
        #!/bin/sh
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | \(hook) UserPromptSubmit
        read line; printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}' | \(hook) PermissionRequest
        read line; printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' | \(hook) PostToolUse
        read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"All tests pass."}' | \(hook) Stop
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"again"}' | \(hook) UserPromptSubmit
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// INBOX-1 (#67): an agent that is done is unseen, on every device,
    /// until one of them shows its session; working again takes it out of
    /// the Inbox, and done again puts it back.
    func testADoneAgentIsUnseenUntilADeviceShowsIt() throws {
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        try """
        #!/bin/sh
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"go"}' | \(hook) UserPromptSubmit
        read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"Done once."}' | \(hook) Stop
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"again"}' | \(hook) UserPromptSubmit
        read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"Done twice."}' | \(hook) Stop
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let mac = Client(port: port, token: token, name: "mac")
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("both connected") { !mac.messages.isEmpty && !phone.messages.isEmpty }
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let id = try XCTUnwrap(mac.sessions.first?.id)
        mac.connection.send(.attach(session: id, size: TermSize(cols: 80, rows: 24)))
        func session(_ client: Client) -> SessionInfo? { client.sessions.first { $0.id == id } }
        func step(_ what: String, _ condition: @escaping () -> Bool) {
            mac.connection.sendInput(Data("\n".utf8), to: id)
            waitUntil(what, condition)
        }

        step("working") { session(mac)?.state?.isWorking == true }
        XCTAssertNotEqual(session(mac)?.unseen, true, "unseen while it works")
        step("done") { session(mac)?.state == .done(said: "Done once.") }
        waitUntil("unseen on both devices") { session(mac)?.unseen == true && session(phone)?.unseen == true }
        XCTAssertEqual(Inbox.items(sessions: phone.sessions, failures: []).map(\.id), ["session-\(id)"])

        // Shown on the phone: seen on the Mac too.
        phone.connection.send(.noticeSeen(session: id, state: .done(said: "Done once.")))
        waitUntil("seen on the Mac") { session(mac)?.unseen != true }
        XCTAssertTrue(Inbox.items(sessions: mac.sessions, failures: []).isEmpty)

        // Working again, then done again: unseen again.
        step("working again") { session(mac)?.state?.isWorking == true }
        step("done again") { session(mac)?.state == .done(said: "Done twice.") }
        waitUntil("unseen again") { session(phone)?.unseen == true }
        // A device that connects later is told it too.
        let later = Client(port: port, token: token, name: "later")
        waitUntil("the later device to be told") { session(later)?.unseen == true }
    }

    /// TURN-1 (#71): when a turn ends, every device is told what it came
    /// to: the prompt, the last answer, the commands with their exit codes
    /// from the agent's record, and the files of the folder that changed
    /// while it worked; a device that connects later is told it too; with
    /// its switch off in Settings, a turn is not looked at.
    func testWhatATurnCameToIsToldToEveryDevice() throws {
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try "one\n".write(to: repository.appendingPathComponent("parser.txt"), atomically: true, encoding: .utf8)
        try "one\n".write(to: repository.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "first")
        // Changed before the turn, and not by it.
        try "one\nmine\n".write(to: repository.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try [
            #"{"type":"user","message":{"role":"user","content":"Fix the parser"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make lint"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 2\nlint failed"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        let stop = #"{"hook_event_name":"Stop","last_assistant_message":"Fixed; lint fails.","transcript_path":"\#(transcript.path)"}"#
        try """
        #!/bin/sh
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"Fix the parser"}' | \(hook) UserPromptSubmit
        read line; printf 'two\\n' >> parser.txt; printf 'new\\n' > added.txt
        printf '%s' '\(stop)' | \(hook) Stop
        read line; printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"Again"}' | \(hook) UserPromptSubmit
        read line; printf '%s' '{"hook_event_name":"Stop","last_assistant_message":"Again."}' | \(hook) Stop
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let mac = Client(port: port, token: token, name: "mac")
        waitUntil("connected") { !mac.messages.isEmpty }
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: repository.path, title: "agent")))
        waitUntil("the session") { mac.sessions.count == 1 }
        let id = try XCTUnwrap(mac.sessions.first?.id)
        mac.connection.send(.attach(session: id, size: TermSize(cols: 80, rows: 24)))
        func result(_ client: Client) -> TurnResult? {
            client.messages.compactMap { if case .turnResult(id, let result) = $0 { return result } else { return nil } }.last
        }
        mac.connection.sendInput(Data("\n".utf8), to: id)
        waitUntil("working") { mac.sessions.first?.state?.isWorking == true }
        // The folder is looked at as the turn begins, away from the host's queue.
        Thread.sleep(forTimeInterval: 1)
        mac.connection.sendInput(Data("\n".utf8), to: id)
        waitUntil("what the turn came to", timeout: 20) { result(mac) != nil }
        let told = try XCTUnwrap(result(mac))
        XCTAssertEqual(told.end, .done)
        XCTAssertEqual(told.request, "Fix the parser")
        XCTAssertEqual(told.reply, "Fixed; lint fails.")
        XCTAssertEqual(told.commands, [TurnResult.Command(command: "swift test", exitCode: 0), TurnResult.Command(command: "make lint", exitCode: 2)])
        XCTAssertEqual(
            told.changes?.files, [TurnResult.File(path: "added.txt", status: "??"), TurnResult.File(path: "parser.txt", status: "M", added: 1, removed: 0)])
        XCTAssertEqual(told.changes?.shared, false)
        // A device that connects later is told it too.
        let later = Client(port: port, token: token, name: "later")
        waitUntil("the later device to be told") { result(later) == told }

        // Turned off in Settings: the next turn is not looked at.
        mac.connection.send(.setDisplaySettings(DisplaySettings(turnResults: false)))
        waitUntil("turned off, as the other device is told") {
            later.messages.contains { if case .displaySettings(let told?) = $0 { return !told.turnResults } else { return false } }
        }
        func results() -> Int { mac.messages.filter { if case .turnResult(id, _) = $0 { return true } else { return false } }.count }
        let before = results()
        mac.connection.sendInput(Data("\n".utf8), to: id)
        waitUntil("working again") { mac.sessions.first?.state?.isWorking == true }
        mac.connection.sendInput(Data("\n".utf8), to: id)
        waitUntil("done again") { mac.sessions.first?.state == .done(said: "Again.") }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(results(), before, "a turn was looked at with the switch off")
    }

    /// AGENT-5, AGENT-6, AGENT-7: each state is told when it begins, once,
    /// to every client; a client that connects later is told the state as
    /// it is; a shell has none; Escape to a working agent makes it not known.
    func testEachStateIsToldWhenItBeginsToEveryClient() throws {
        let script = try standIn()
        let mac = Client(port: port, token: token, name: "mac")
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("both connected") { !mac.messages.isEmpty && !phone.messages.isEmpty }
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path, title: "shell")))
        waitUntil("both sessions") { mac.sessions.count == 2 }
        let agent = try XCTUnwrap(mac.sessions.first { $0.title == "agent" })
        XCTAssertNil(agent.state, "not known until the agent says something")
        mac.connection.send(.attach(session: agent.id, size: TermSize(cols: 80, rows: 24)))

        /// One more line for the stand-in, and the state that follows.
        /// Working is compared by name: since when is the host's to say.
        func step(_ expected: AgentState?, _ what: String) {
            mac.connection.sendInput(Data("\n".utf8), to: agent.id)
            waitUntil(what) {
                let state = mac.sessions.first { $0.id == agent.id }?.state
                if case .working = expected { return state?.isWorking == true }
                return state == expected
            }
        }
        step(.working(since: Date()), "working")
        guard case .working(let since)? = mac.sessions.first(where: { $0.id == agent.id })?.state else { return XCTFail("not working") }
        step(.waitingForPermission(AgentQuestion(text: "make test")), "waiting for permission")
        step(.working(since: since), "working again")
        step(.done(said: "All tests pass."), "done")

        // Told once each, and the same on the other device.
        waitUntil("the phone to be told the same") { phone.states(of: "agent").count == mac.states(of: "agent").count }
        XCTAssertEqual(mac.states(of: "agent").map { $0?.name }, [nil, "working", "waiting for permission", "working", "done"])
        XCTAssertEqual(phone.states(of: "agent"), mac.states(of: "agent"))
        // A shell has no state.
        XCTAssertNil(mac.sessions.first { $0.title == "shell" }?.state)
        XCTAssertNil(mac.sessions.first { $0.title == "shell" }?.stateNote)

        // A device that connects later is told the state as it is.
        let later = Client(port: port, token: token, name: "later")
        waitUntil("the later device to be told") { later.sessions.first { $0.id == agent.id }?.state?.name == "done" }

        // Working again, then Escape: it may have stopped the turn.
        step(.working(since: Date()), "working once more")
        mac.connection.sendInput(Data([0x1b]), to: agent.id)
        waitUntil("not known after Escape") { mac.sessions.first { $0.id == agent.id }.map { $0.state == nil } ?? false }
    }

    /// AGENT-8: a Codex session says, until its hooks first report, that
    /// they have to be trusted for its state to be known: Codex 0.169 asks
    /// to review hooks that are new or changed, and runs none of them when
    /// told to go on without (tried 2026-11-15). An Antigravity session
    /// always says what it cannot tell.
    func testWhatIsSaidOfAnAgentWhoseStateCannotAllBeKnown() throws {
        let client = Client(port: port, token: token, name: "mac")
        waitUntil("connected") { !client.messages.isEmpty }
        let hook = Handoff.shellQuote(tool.path) + " hook codex"
        let prompt = #"{"hook_event_name":"UserPromptSubmit","prompt":"go"}"#
        let scripts = [
            // Its hooks report once something is typed into it.
            "codex": "#!/bin/sh\nstty raw -echo\nhead -c 1 > /dev/null\nprintf '%s' '\(prompt)' | \(hook) UserPromptSubmit\nexec sleep 600\n",
            "agy": "#!/bin/sh\nexec sleep 600\n",
        ]
        for (agent, text) in scripts {
            let script = root.appendingPathComponent(agent)
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            client.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: agent)))
        }
        waitUntil("both sessions") { client.sessions.count == 2 }
        let codex = try XCTUnwrap(client.sessions.first { $0.title == "codex" })
        XCTAssertEqual(codex.stateNote?.contains("Trust all and continue"), true, codex.stateNote ?? "no note")
        XCTAssertEqual(client.sessions.first { $0.title == "agy" }?.stateNote?.contains("does not say when it waits for permission"), true)

        // Its hooks report: the note goes.
        client.connection.send(.attach(session: codex.id, size: TermSize(cols: 80, rows: 24)))
        client.connection.sendInput(Data("\r".utf8), to: codex.id)
        waitUntil("working, the note gone") {
            let now = client.sessions.first { $0.id == codex.id }
            return now?.state?.isWorking == true && now?.stateNote == nil
        }
    }

    /// AWAKE-5: with "only while an agent is working", the Mac is held
    /// awake while an agent works and let go when none does; a shell and a
    /// waiting agent hold nothing. With it off, a shell holds the Mac as before.
    func testOnlyAnAgentAtWorkKeepsTheMacAwakeWhenAsked() throws {
        let script = try standIn()
        let mac = Client(port: port, token: token, name: "mac")
        waitUntil("connected") { !mac.messages.isEmpty }
        mac.connection.send(.setKeepAwakeOptions(KeepAwakeOptions(onlyWhileWorking: true)))
        mac.connection.send(.setKeepAwake(true))
        mac.connection.send(.create(CreateRequest(command: "exec sleep 600", cwd: root.path, title: "shell")))
        mac.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        waitUntil("both sessions") { mac.sessions.count == 2 }
        let agent = try XCTUnwrap(mac.sessions.first { $0.title == "agent" })
        mac.connection.send(.attach(session: agent.id, size: TermSize(cols: 80, rows: 24)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(isHeld, "a shell and an agent that said nothing hold nothing")

        func next(_ name: String) {
            mac.connection.sendInput(Data("\n".utf8), to: agent.id)
            waitUntil(name) { mac.sessions.first { $0.id == agent.id }?.state?.name == name }
        }
        next("working")
        waitUntil("the hold to be taken") { self.isHeld }
        next("waiting for permission")
        waitUntil("the hold to be let go while it waits") { !self.isHeld }
        next("working")
        waitUntil("taken again") { self.isHeld }
        next("done")
        waitUntil("let go when it is done") { !self.isHeld }

        // Off: any session holds the Mac awake, as before.
        mac.connection.send(.setKeepAwakeOptions(KeepAwakeOptions(onlyWhileWorking: false)))
        waitUntil("held for the sessions") { self.isHeld }
    }

    /// Settings saved before the option was added read with it off.
    func testOptionsSavedBeforeReadWithTheNewOneOff() throws {
        let old = try XCTUnwrap(MessageCoding.decode(KeepAwakeOptions.self, from: Data(#"{"display":true,"onlyOnPower":false}"#.utf8)))
        XCTAssertEqual(old, KeepAwakeOptions(display: true))
    }

    /// NOTE-2: a reply reaches the session while the agent still asks what
    /// it answers, and is dropped, with a word, once it moved on.
    func testAReplyIsTypedOnlyWhileItIsCurrent() throws {
        let script = try standIn()
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("connected") { !phone.messages.isEmpty }
        phone.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        waitUntil("the session") { phone.sessions.count == 1 }
        let agent = try XCTUnwrap(phone.sessions.first)
        phone.connection.send(.attach(session: agent.id, size: TermSize(cols: 80, rows: 24)))
        // Through the stand-in's first steps by typing, to "waiting for permission".
        phone.connection.sendInput(Data("\n".utf8), to: agent.id)
        waitUntil("working") { phone.sessions.first?.state?.isWorking == true }
        phone.connection.sendInput(Data("\n".utf8), to: agent.id)
        let waiting = AgentState.waitingForPermission(AgentQuestion(text: "make test"))
        waitUntil("waiting") { phone.sessions.first?.state == waiting }

        // A reply to what it asked before is dropped, with a word.
        phone.connection.send(.answer(session: agent.id, to: .done(said: "earlier"), text: "go on"))
        waitUntil("the reply to be refused") {
            phone.messages.contains { if case .error(let text) = $0 { return text.contains("moved on") } else { return false } }
        }
        XCTAssertEqual(phone.sessions.first?.state, waiting, "nothing was typed")

        // A reply to what it asks now is typed, then Return: the stand-in goes on.
        phone.connection.send(.answer(session: agent.id, to: waiting, text: "yes"))
        waitUntil("the agent to go on") { phone.sessions.first?.state?.isWorking == true }
    }

    /// NOTE-14 (#55): an answer to a question with choices is typed as the
    /// agent's list of them takes it, not as text into a prompt, which
    /// every agent answers with its first choice.
    func testAnAnswerPicksItsChoiceInTheAgentsList() {
        let asked = AgentState.waitingForAnswer(AgentQuestion(text: "Which color?", choices: ["Red", "Green", "Blue"]))
        let down = "\u{1b}[B"
        for agent in ["claude", "copilot", "agy"] {
            XCTAssertEqual(AgentAnswer.steps(agent: agent, state: asked, text: "Red"), ["\r"], agent)
            XCTAssertEqual(AgentAnswer.steps(agent: agent, state: asked, text: "Green"), [down, "\r"], agent)
            XCTAssertEqual(AgentAnswer.steps(agent: agent, state: asked, text: " blue\n"), [down + down, "\r"], agent)
        }
        // The user's own words go to the row after the choices.
        XCTAssertEqual(AgentAnswer.steps(agent: "claude", state: asked, text: "Purple"), [down + down + down, "Purple", "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: "copilot", state: asked, text: "Purple"), [down + down + down, "Purple", "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: "agy", state: asked, text: "Purple"), [down + down + down, "\r", "Purple", "\r"])
        // A prompt takes text and Return: a question without choices, a
        // finished task's next instruction, any other program.
        XCTAssertEqual(AgentAnswer.steps(agent: "claude", state: .waitingForAnswer(AgentQuestion(text: "Why?")), text: "Because"), ["Because", "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: "claude", state: .done(said: "ok"), text: "Green"), ["Green", "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: nil, state: asked, text: "Green"), ["Green", "\r"])
    }

    /// NOTE-15: a finished task's next instruction, long, goes as a paste
    /// to an agent that asked for bracketed paste, so that its Return
    /// submits it (Codex 0.169 kept one of 437 characters typed as it was,
    /// the Return a new line in it). Short, or to a question, it is typed
    /// as before.
    func testALongNextInstructionIsPastedWhenTheAgentAsksForIt() {
        let long = String(repeating: "Write the tests first. ", count: 20)
        let done = AgentState.done(said: "ok")
        XCTAssertEqual(AgentAnswer.steps(agent: "codex", state: done, text: long, bracketedPaste: true), ["\u{1b}[200~" + long + "\u{1b}[201~", "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: "codex", state: done, text: long, bracketedPaste: false), [long, "\r"])
        XCTAssertEqual(AgentAnswer.steps(agent: "codex", state: done, text: "go on", bracketedPaste: true), ["go on", "\r"])
        // A question's own words are typed as they were tried.
        let why = AgentState.waitingForAnswer(AgentQuestion(text: "Why?"))
        XCTAssertEqual(AgentAnswer.steps(agent: "claude", state: why, text: long, bracketedPaste: true), [long, "\r"])
    }

    /// NOTE-15: the host knows the session asked for bracketed paste, and
    /// what it types for a long next instruction reaches the session as one.
    func testALongNextInstructionReachesTheSessionAsAPaste() throws {
        let typed = root.appendingPathComponent("typed")
        let script = root.appendingPathComponent("codex")
        let hook = Handoff.shellQuote(tool.path) + " hook codex"
        let stop = #"{"hook_event_name":"Stop","last_assistant_message":"Done."}"#
        let long = String(repeating: "Write the tests first. ", count: 20)
        let expected = "\u{1b}[200~" + long + "\u{1b}[201~\r"
        // It says it is done, asks for bracketed paste, then writes down
        // what is typed into it.
        try """
        #!/bin/sh
        stty raw -echo
        printf '\\033[?2004h'
        printf '%s' '\(stop)' | \(hook) Stop
        head -c \(expected.utf8.count) > '\(typed.path)'
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("connected") { !phone.messages.isEmpty }
        phone.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        let done = AgentState.done(said: "Done.")
        waitUntil("done") { phone.sessions.first?.state == done }
        let agent = try XCTUnwrap(phone.sessions.first)
        phone.connection.send(.answer(session: agent.id, to: done, text: long))
        waitUntil("the instruction to be typed") { (try? Data(contentsOf: typed))?.count == expected.utf8.count }
        XCTAssertEqual(String(decoding: try Data(contentsOf: typed), as: UTF8.self), expected)
    }

    /// NOTE-14: what the host types for a choice reaches the agent's
    /// terminal as those keys.
    func testAChoiceIsTypedAsKeysIntoTheSession() throws {
        let typed = root.appendingPathComponent("typed")
        let script = root.appendingPathComponent("claude")
        let hook = Handoff.shellQuote(tool.path) + " hook claude"
        let asks =
            #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","options":[{"label":"Red"},{"label":"Green"},{"label":"Blue"}]}]}}"#
        // It asks, then writes down the next four bytes typed into it.
        try """
        #!/bin/sh
        printf '%s' '\(asks)' | \(hook) PreToolUse
        stty raw -echo
        head -c 4 > '\(typed.path)'
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let phone = Client(port: port, token: token, name: "phone")
        waitUntil("connected") { !phone.messages.isEmpty }
        phone.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        let asked = AgentState.waitingForAnswer(AgentQuestion(text: "Which color?", choices: ["Red", "Green", "Blue"]))
        waitUntil("the question") { phone.sessions.first?.state == asked }
        let agent = try XCTUnwrap(phone.sessions.first)
        phone.connection.send(.answer(session: agent.id, to: asked, text: "Green"))
        waitUntil("the keys to be typed") { (try? Data(contentsOf: typed))?.count == 4 }
        XCTAssertEqual(try Data(contentsOf: typed), Data("\u{1b}[B\r".utf8), "Down, then Return: the second choice")
    }

    /// NOTE-10 (#60): what an agent says, seen on one device, is told to
    /// the others, and to one that connects later, while the agent still
    /// says it.
    func testANoticeSeenOnOneDeviceIsToldToTheOthers() throws {
        let script = try standIn()
        let phone = Client(port: port, token: token, name: "phone")
        let mac = Client(port: port, token: token, name: "mac")
        waitUntil("connected") { !phone.messages.isEmpty && !mac.messages.isEmpty }
        func seen(_ client: Client) -> [AgentState] {
            client.messages.compactMap { if case .noticeSeen(_, let state) = $0 { return state } else { return nil } }
        }
        phone.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        waitUntil("the session") { phone.sessions.count == 1 }
        let agent = try XCTUnwrap(phone.sessions.first)
        phone.connection.send(.attach(session: agent.id, size: TermSize(cols: 80, rows: 24)))
        phone.connection.sendInput(Data("\n".utf8), to: agent.id)
        waitUntil("working") { phone.sessions.first?.state?.isWorking == true }
        phone.connection.sendInput(Data("\n".utf8), to: agent.id)
        let waiting = AgentState.waitingForPermission(AgentQuestion(text: "make test"))
        waitUntil("waiting") { phone.sessions.first?.state == waiting && mac.sessions.first?.state == waiting }

        // What it said before is seen by no one any more: not passed on.
        mac.connection.send(.noticeSeen(session: agent.id, state: .done(said: "earlier")))
        // The Mac's user opens the session: the phone hides its notice.
        mac.connection.send(.noticeSeen(session: agent.id, state: waiting))
        waitUntil("the phone to be told") { seen(phone) == [waiting] }
        XCTAssertEqual(seen(mac), [], "the device it was seen on is not told")
        // A device that was away is told when it connects.
        let tablet = Client(port: port, token: token, name: "tablet")
        waitUntil("the tablet to be told") { seen(tablet) == [waiting] }

        // Once the agent says something else, that is no longer what was seen.
        phone.connection.send(.answer(session: agent.id, to: waiting, text: "yes"))
        waitUntil("the agent to go on") { phone.sessions.first?.state?.isWorking == true }
        let later = Client(port: port, token: token, name: "later")
        waitUntil("the later device connected") { later.sessions.count == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(seen(later), [])
    }

    /// NOTE-3: the Mac is in use while its app is in front, or a key or the
    /// pointer was used in the last five minutes; every client is told.
    func testWhetherSomeoneIsAtTheMac() throws {
        let phone = Client(port: port, token: token, name: "phone")
        let mac = Client(port: port, token: token, name: "mac")
        func told(_ client: Client) -> Bool? { client.messages.compactMap { if case .macInUse(let on) = $0 { return on } else { return nil } }.last }
        waitUntil("told that it is in use") { told(phone) == true }

        holdLock.lock(); idle = 6 * 60; holdLock.unlock()
        waitUntil("told that no one is at it") { told(phone) == false }
        mac.connection.send(.appInFront(true))
        waitUntil("in use with its app in front") { told(phone) == true }
        mac.connection.send(.appInFront(false))
        waitUntil("not with its app behind") { told(phone) == false }
        holdLock.lock(); idle = 10; holdLock.unlock()
        waitUntil("in use once a key is pressed") { told(phone) == true }
        XCTAssertEqual(told(mac), true, "every client is told")
    }
}

/// AGENT-11: a state is known when the agent's hook saves it, through the
/// host's watch of the folder the hooks write in, not at its next refresh.
final class AgentStateWatchTests: XCTestCase {
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

    private var root: URL!
    private var server: HostServer!

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    func testAStateIsKnownWhenItIsSavedNotAtTheNextRefresh() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-watch-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, statusLineTool: "/usr/bin/true",
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.hooksDirectory = root.appendingPathComponent("hooks")
        configuration.home = root.path
        // No refresh within the test: only the watch can tell.
        configuration.refreshInterval = 600
        server = HostServer(configuration: configuration)
        let client = Client(port: try server.start(), token: token)
        waitUntil("connected") { !client.messages.isEmpty }

        // A stand-in for Claude Code: on each line, what its hook saves.
        let script = root.appendingPathComponent("claude")
        try """
        #!/bin/sh
        read line; printf '{"agent":"claude","event":"UserPromptSubmit","at":%s,"input":{}}' "$(date +%s)" > "$\(AppChannel.current.eventsVariable).new"; mv "$\(AppChannel.current.eventsVariable).new" "$\(AppChannel.current.eventsVariable)"
        read line; printf '{"agent":"claude","event":"Stop","at":%s,"input":{}}' "$(date +%s)" > "$\(AppChannel.current.eventsVariable).new"; mv "$\(AppChannel.current.eventsVariable).new" "$\(AppChannel.current.eventsVariable)"
        exec sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        client.connection.send(.create(CreateRequest(command: script.path, cwd: root.path, title: "agent")))
        waitUntil("the session") { client.sessions.count == 1 }
        let agent = try XCTUnwrap(client.sessions.first)
        // Past the host's first refresh, three seconds after it started.
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))

        client.connection.sendInput(Data("\n".utf8), to: agent.id)
        waitUntil("working, well before a refresh", timeout: 2) { client.sessions.first?.state?.isWorking == true }
        client.connection.sendInput(Data("\n".utf8), to: agent.id)
        waitUntil("done, well before a refresh", timeout: 2) { client.sessions.first?.state == .done(said: nil) }
    }
}
