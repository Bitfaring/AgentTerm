import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// `agenttermd setup` (#129): AgentTerm's hooks and MCP server added to each
/// agent's own configuration with the agent's own commands, and taken out;
/// SETUP-1 to SETUP-6 in docs/TESTING.md. The agents are stand-ins, which
/// write down how they are run and answer `plugin list` as each real one
/// was seen to (2026-11-17), in a home of the test's own: nothing of the
/// user's agents is run or read.
final class AgentSetupTests: XCTestCase {
    private var root: URL!
    private var agents: URL { root.appendingPathComponent("agents") }
    private var home: URL { root.appendingPathComponent("home") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-setup-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for agent in ["claude", "codex", "copilot", "agy"] { try standIn(agent) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in agent: what it is run with goes in `<agent>.log`; the
    /// plugins it was given are files in a folder of its own, which its
    /// `plugin list` prints as the real one does.
    private func standIn(_ agent: String) throws {
        let listed: String
        switch agent {
        case "claude": listed = #"printf '  ❯ %s\n    Version: 1.0\n    Status: ✔ enabled\n' "$n""#
        case "codex": listed = #"printf '%s  installed, enabled  1.0  /x\n' "$n""#
        case "copilot": listed = #"printf '  • %s (v1.0) (enabled)\n' "$n""#
        default: listed = #"printf -- '- %s (enabled, 1.0)\n' "$n""#
        }
        let state = root.appendingPathComponent("state-\(agent)").path
        let script = """
            #!/bin/sh
            mkdir -p '\(state)'
            printf '%s\\n' "$*" >> '\(root.appendingPathComponent("\(agent).log").path)'
            case "$1 $2" in
              "plugin list")
                for f in '\(state)'/plugin-*; do [ -e "$f" ] || continue; n=${f##*/plugin-}; \(listed); done; exit 0;;
              "plugin install"|"plugin add")
                if [ -e '\(state)/fail' ]; then cat '\(state)/fail'; exit 1; fi
                case "$3" in /*) n=$(sed -n 's/.*"name" *: *"\\([^"]*\\)".*/\\1/p' "$3/plugin.json" | head -1);; *) n="$3";; esac
                touch '\(state)'/plugin-"$n"; exit 0;;
              "plugin uninstall"|"plugin remove")
                rm -f '\(state)'/plugin-"$3"; exit 0;;
              "features list")
                if [ -e '\(state)/broken' ]; then echo "error: could not parse config.toml"; exit 1; fi; exit 0;;
            esac
            exit 0

            """
        let file = agents.appendingPathComponent(agent)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    private func setup(name: String = "agentterm-dev", tool: String = "/Apps/AgentTerm Dev.app/agenttermd", prompt: String? = "Use the shells.") -> AgentSetup {
        let directory = agents.path, home = home.path
        return AgentSetup(
            directory: root.appendingPathComponent("setup-\(name)"), tool: tool, home: home, name: name, environment: [:],
            locate: { AgentDetector.detect(in: directory) }, prompt: { _ in prompt }, run: { AgentSetup.direct($0, home: home) })
    }

    /// What a stand-in was run with, a line each time.
    private func ran(_ agent: String) -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("\(agent).log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func state(_ setup: AgentSetup, _ agent: String) throws -> AgentSetupState {
        try XCTUnwrap(setup.report().agents.first { $0.agent == agent })
    }

    /// SETUP-1: Claude Code gets a plugin with its own commands (a
    /// marketplace of AgentTerm's folder, then the plugin), and AgentTerm's
    /// status line in its settings, the user's own kept; asked again, it
    /// has all of it; taken out, it has none, and its status line is the
    /// user's again.
    func testClaudeIsSetUpWithItsOwnCommandsAndTakenOut() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"printf mine"},"theme":"dark"}"#.write(to: settings, atomically: true, encoding: .utf8)
        let setup = setup()
        let before = try state(setup, "claude")
        XCTAssertEqual([before.hooks, before.mcp, before.statusLine], [false, false, false])
        XCTAssertEqual(before.command, "'/Apps/AgentTerm Dev.app/agenttermd' setup claude")
        XCTAssertEqual(before.removeCommand, "'/Apps/AgentTerm Dev.app/agenttermd' setup claude --remove")

        setup.install("claude")
        let market = root.appendingPathComponent("setup-agentterm-dev/claude").path
        // At the user's scope, for every folder.
        XCTAssertTrue(ran("claude").contains("plugin marketplace add \(market) --scope user"), ran("claude").joined(separator: "\n"))
        XCTAssertTrue(ran("claude").contains("plugin install agentterm-dev@agentterm-dev --scope user"), ran("claude").joined(separator: "\n"))
        let after = try state(setup, "claude")
        XCTAssertEqual([after.hooks, after.mcp, after.statusLine], [true, true, true])
        XCTAssertTrue(after.isSetUp)
        XCTAssertNil(after.problem)
        let set = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(set["theme"] as? String, "dark")

        setup.remove("claude")
        XCTAssertTrue(ran("claude").contains("plugin uninstall agentterm-dev@agentterm-dev --scope user"))
        XCTAssertTrue(ran("claude").contains("plugin marketplace remove agentterm-dev"))
        let removed = try state(setup, "claude")
        XCTAssertEqual([removed.hooks, removed.mcp, removed.statusLine], [false, false, false])
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((back["statusLine"] as? [String: String])?["command"], "printf mine")
    }

    /// SETUP-2: Codex gets a plugin with the server, and its hooks between
    /// marks in its config.toml, which it reads back; Copilot CLI a plugin
    /// of a marketplace of AgentTerm's; Antigravity a plugin installed from
    /// AgentTerm's folder, with the words it is told as a rule. Each with
    /// its own commands, and taken out the same way.
    func testCodexCopilotAndAntigravityAreSetUpWithTheirOwnCommands() throws {
        let setup = setup()
        for agent in ["codex", "copilot", "agy"] { setup.install(agent) }
        XCTAssertTrue(ran("codex").contains("plugin marketplace add \(root.appendingPathComponent("setup-agentterm-dev/codex").path)"))
        XCTAssertTrue(ran("codex").contains("plugin add agentterm-dev@agentterm-dev"))
        XCTAssertTrue(ran("codex").contains("features list"), "Codex did not read its configuration back")
        let config = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("[[hooks.Stop]]") && config.contains("hook codex Stop"), config)
        XCTAssertTrue(ran("copilot").contains("plugin install agentterm-dev@agentterm-dev"), ran("copilot").joined(separator: "\n"))
        let plugin = root.appendingPathComponent("setup-agentterm-dev/agy/plugin")
        XCTAssertTrue(ran("agy").contains("plugin install \(plugin.path)"), ran("agy").joined(separator: "\n"))
        XCTAssertTrue(try String(contentsOf: plugin.appendingPathComponent("rules/agentterm-dev.md"), encoding: .utf8).contains("Use the shells."))
        for agent in ["codex", "copilot", "agy"] {
            let each = try state(setup, agent)
            XCTAssertEqual([each.hooks, each.mcp], [true, true], agent)
            XCTAssertNil(each.statusLine, agent)
            XCTAssertNil(each.problem, agent)
        }
        XCTAssertNotNil(try state(setup, "codex").note, "Codex's review of its hooks is not said")

        for agent in ["codex", "copilot", "agy"] { setup.remove(agent) }
        for agent in ["codex", "copilot", "agy"] {
            let each = try state(setup, agent)
            XCTAssertEqual([each.hooks, each.mcp], [false, false], agent)
        }
        XCTAssertFalse(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8).contains("hook codex"))
    }

    /// SETUP-3: what does not work is said, in the agent's own words; a
    /// config.toml Codex cannot read with the hooks in it is put back as it
    /// was.
    func testWhatDoesNotWorkIsSaidInTheAgentsOwnWords() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-copilot"), withIntermediateDirectories: true)
        try "Error: marketplace plugin not found".write(to: root.appendingPathComponent("state-copilot/fail"), atomically: true, encoding: .utf8)
        let setup = setup()
        setup.install("copilot")
        let copilot = try state(setup, "copilot")
        XCTAssertEqual(copilot.hooks, false)
        XCTAssertTrue(copilot.problem?.contains("marketplace plugin not found") == true, copilot.problem ?? "nothing said")

        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o3\"\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-codex"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("state-codex/broken").path, contents: nil)
        setup.install("codex")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "model = \"o3\"\n", "left with what Codex cannot read")
        XCTAssertTrue(try state(setup, "codex").problem?.contains("could not parse config.toml") == true)
    }

    /// SETUP-4 (MCP-15, principle 7): a released build and a development
    /// build each set up their own, under names of their own, and each
    /// takes out only its own. Claude Code has one status line: the build
    /// set up last has it, and runs the one it took the place of after its
    /// own; the other's is then not known, not said missing.
    func testEachBuildSetsUpAndTakesOutOnlyItsOwn() throws {
        let released = setup(name: "agentterm", tool: "/Applications/AgentTerm.app/agenttermd")
        let development = setup()
        released.install("claude")
        development.install("claude")
        let both = try state(released, "claude")
        XCTAssertEqual([both.hooks, both.mcp], [true, true])
        XCTAssertNil(both.statusLine, "the other build's status line said to be none")
        XCTAssertTrue(both.isSetUp)
        XCTAssertTrue(try state(development, "claude").isSetUp)
        development.remove("claude")
        let left = try state(released, "claude")
        XCTAssertEqual([left.hooks, left.mcp, left.statusLine], [true, true, true], "the development build took the released build's out")
        XCTAssertEqual(try state(development, "claude").hooks, false)
    }

    /// SETUP-5: an agent that is not installed is said so, and nothing is
    /// run for it.
    func testAnAgentThatIsNotInstalledIsSaidSo() throws {
        try FileManager.default.removeItem(at: agents.appendingPathComponent("agy"))
        let setup = setup()
        let agy = try state(setup, "agy")
        XCTAssertFalse(agy.installed)
        XCTAssertNil(agy.hooks)
        XCTAssertFalse(agy.needsSetup)
        setup.install("agy")
        XCTAssertEqual(try state(setup, "agy").problem, "It is not installed on this Mac.")
        XCTAssertEqual(ran("agy"), [])
    }

    /// SETUP-6: nothing is run in the agents until a device asks; the apps
    /// ask the host what each has, and the Mac's own app has one set up,
    /// told when it starts and when it is done.
    func testNothingIsRunUntilAskedAndTheMacsAppSetsUp() throws {
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: self.agents.path) })
        configuration.foldersFile = root.appendingPathComponent("folders.json")
        configuration.agentSetup = setup()
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        defer { client.close() }
        var reports: [AgentSetupReport] = []
        var welcomed = false
        client.onMessage = {
            if case .agentSetup(let report) = $0 { reports.append(report) }
            if case .welcome = $0 { welcomed = true }
        }
        client.connect()
        func spin(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        spin { welcomed }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for agent in ["claude", "codex", "copilot", "agy"] { XCTAssertEqual(ran(agent), [], "\(agent) was run before anyone asked") }

        client.send(.agentSetupStatus)
        spin { !reports.isEmpty }
        XCTAssertEqual(reports.last?.agents.map(\.agent), ["claude", "codex", "agy", "copilot"])
        XCTAssertTrue(reports.last?.needsSetup == true)
        XCTAssertFalse(ran("claude").contains { $0.hasPrefix("plugin install") }, "asking installed something")

        client.send(.runAgentSetup(agent: "claude", remove: false))
        spin { reports.last.map { $0.busy.isEmpty && $0.agents.first { $0.agent == "claude" }?.isSetUp == true } == true }
        XCTAssertTrue(reports.contains { $0.busy == ["claude"] }, "nobody told it was being set up")
        XCTAssertTrue(reports.last?.agents.first { $0.agent == "claude" }?.isSetUp == true)
    }
}
