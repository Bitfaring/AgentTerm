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

    /// How a stand-in answers `mcp add`, `mcp get`, `mcp list` and `mcp
    /// remove`, as the real agent was seen to on 2026-11-18 (Claude Code
    /// 2.1.327, Codex 0.169.1, Copilot CLI 1.0.113, Antigravity 1.5.10):
    /// what each prints, its status, and whether it takes a name it has.
    /// Codex's writes the table into its config.toml as the real one does,
    /// since AgentTerm adds a line to it.
    private func servers(_ agent: String, state: String) -> String {
        let has = "[ -e '\(state)'/server-\"$n\" ]"
        let keep = "printf '%s\\n' \"$1\" > '\(state)'/server-\"$n\"; shift; printf '%s\\n' \"$*\" > '\(state)'/server-\"$n\".args"
        let drop = "rm -f '\(state)'/server-\"$n\" '\(state)'/server-\"$n\".args"
        switch agent {
        case "claude":
            return """
                  "mcp add")
                    shift 2; while [ "$1" = "--scope" ]; do shift 2; done; n=$1; shift; [ "$1" = "--" ] && shift
                    if \(has); then echo "MCP server $n already exists in user config"; exit 1; fi
                    echo "Added stdio MCP server $n with command: $* to user config"; \(keep); exit 0;;
                  "mcp get")
                    n=$3
                    if ! \(has); then echo "No MCP server named \\"$n\\". Run \\`claude mcp add\\` to add one."; exit 1; fi
                    printf '%s:\\n  Scope: User config (available in all your projects)\\n  Status: ✔ Connected\\n  Type: stdio\\n  Command: %s\\n  Args: %s\\n  Environment:\\n' "$n" "$(cat '\(state)'/server-"$n")" "$(cat '\(state)'/server-"$n".args)"; exit 0;;
                  "mcp remove")
                    shift 2; while [ "$1" = "--scope" ]; do shift 2; done; n=$1
                    if ! \(has); then echo "No MCP server named \\"$n\\" in user scope"; exit 1; fi
                    \(drop); echo "Removed MCP server $n from user config"; exit 0;;
                """
        case "copilot":
            return """
                  "mcp add")
                    n=$3; shift 3; [ "$1" = "--" ] && shift
                    if \(has); then printf 'Error: Server "%s" already exists. To update it, remove it first:\\n  copilot mcp remove %s\\n' "$n" "$n"; exit 1; fi
                    echo "Added server \\"$n\\""; \(keep); exit 0;;
                  "mcp get")
                    n=$3
                    if ! \(has); then echo "Error: Server \\"$n\\" not found."; exit 1; fi
                    printf '{\\n  "%s": {\\n    "tools": [\\n      "*"\\n    ],\\n    "type": "local",\\n    "command": "%s",\\n    "args": [\\n      "%s"\\n    ],\\n    "source": "user",\\n    "enabled": true\\n  }\\n}\\n' "$n" "$(cat '\(state)'/server-"$n")" "$(cat '\(state)'/server-"$n".args)"; exit 0;;
                  "mcp remove")
                    n=$3
                    if ! \(has); then echo "Error: Server \\"$n\\" not found."; exit 1; fi
                    \(drop); echo "Removed server \\"$n\\""; exit 0;;
                """
        case "agy":
            return """
                  "mcp add")
                    n=$3; shift 3; echo "Added MCP server \\"$n\\" (stdio)"; \(keep); exit 0;;
                  "mcp list")
                    any=
                    for f in '\(state)'/server-*; do
                      case "$f" in *.args) continue;; esac; [ -e "$f" ] || continue
                      [ -n "$any" ] || echo "NAME             TYPE   STATUS   COMMAND/URL"; any=1
                      printf '%s  stdio  enabled  %s %s\\n' "${f##*/server-}" "$(cat "$f")" "$(cat "$f".args)"
                    done
                    [ -n "$any" ] || echo "No MCP servers configured."; exit 0;;
                  "mcp remove")
                    n=$3
                    if ! \(has); then echo "Error: MCP server \\"$n\\" not found"; exit 1; fi
                    \(drop); echo "Removed MCP server \\"$n\\""; exit 0;;
                """
        default:
            return """
                  "mcp add")
                    n=$3; shift 3; [ "$1" = "--" ] && shift
                    mkdir -p "$HOME/.codex"; rest=$(without "$n")
                    { [ -z "$rest" ] || printf '%s\\n\\n' "$rest"; printf '[mcp_servers.%s]\\ncommand = "%s"\\nargs = ["mcp"]\\n' "$n" "$1"; } > "$conf.new"; mv "$conf.new" "$conf"
                    echo "Added global MCP server '$n'."; exit 0;;
                  "mcp get")
                    n=$3; body=$(table "$n")
                    if [ -z "$body" ]; then echo "Error: No MCP server named '$n' found."; exit 1; fi
                    printf '{\\n  "name": "%s",\\n  "enabled": true,\\n  "transport": {\\n    "type": "stdio",\\n    "command": "%s",\\n    "args": [\\n      "mcp"\\n    ],\\n    "env": null,\\n    "env_vars": [%s],\\n    "cwd": null\\n  }\\n}\\n' "$n" "$(printf '%s\\n' "$body" | sed -n 's/^command = "\\(.*\\)"$/\\1/p')" "$(printf '%s\\n' "$body" | sed -n 's/^env_vars = \\[\\(.*\\)\\]$/\\1/p')"; exit 0;;
                  "mcp remove")
                    n=$3
                    if [ -z "$(table "$n")" ]; then echo "No MCP server named '$n' found."; exit 0; fi
                    without "$n" > "$conf.new"; mv "$conf.new" "$conf"; echo "Removed global MCP server '$n'."; exit 0;;
                """
        }
    }

    /// A stand-in agent: what it is run with goes in `<agent>.log`; the
    /// plugins it was given are files in a folder of its own, which its
    /// `plugin list` prints as the real one does; and its MCP servers.
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
            conf="$HOME/.codex/config.toml"
            # The lines of a server's table in Codex's config.toml, and the file without it.
            table() { awk -v h="[mcp_servers.$1]" '$0==h{on=1;next} on&&/^\\[/{on=0} on' "$conf" 2>/dev/null; }
            without() { awk -v h="[mcp_servers.$1]" '$0==h{skip=1;pend=0;next} skip&&/^\\[/{skip=0} skip{next} /^$/{pend++;next} {while(pend>0){print "";pend--} print}' "$conf" 2>/dev/null; }
            case "$1 $2" in
            \(servers(agent, state: state))
              "plugin list")
                for f in '\(state)'/plugin-*; do [ -e "$f" ] || continue; n=${f##*/plugin-}; \(listed); done; exit 0;;
              "plugin install"|"plugin add")
                if [ -e '\(state)/fail' ]; then cat '\(state)/fail'; exit 1; fi
                case "$3" in /*) n=$(sed -n 's/.*"name" *: *"\\([^"]*\\)".*/\\1/p' "$3/plugin.json" | head -1);; *) n="$3";; esac
                touch '\(state)'/plugin-"$n"; exit 0;;
              "plugin uninstall"|"plugin remove")
                rm -f '\(state)'/plugin-"$3"; exit 0;;
              "features list")
                if [ -e '\(state)/broken' ]; then echo "error: could not parse config.toml"; exit 1; fi
                if [ -e '\(state)/shared-server' ]; then printf 'apps                                     stable             true\\ndaemon_auto_start                        stable             %s\\n' "$(cat '\(state)/shared-server')"; fi
                exit 0;;
              "features disable"|"features enable")
                if [ "$3" != daemon_auto_start ] || [ ! -e '\(state)/shared-server' ]; then echo "Error: Unknown feature flag: $3"; exit 1; fi
                if [ "$2" = disable ]; then echo false > '\(state)/shared-server'; echo 'Disabled feature `daemon_auto_start` in config.toml.'
                else echo true > '\(state)/shared-server'; echo 'Enabled feature `daemon_auto_start` in config.toml.'; fi
                exit 0;;
              "app-server daemon")
                if [ "$3" = version ] && [ -e '\(state)/server-running' ]; then echo '{"status":"running","backend":"pid","cliVersion":"0.169.1","appServerVersion":"0.169.1"}'; exit 0; fi
                printf 'Error: failed to connect to %s/app-server-control/app-server-control.sock\\n\\nCaused by:\\n    No such file or directory (os error 2)\\n' "$HOME/.codex"; exit 1;;
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

    /// What a stand-in Codex says of the server its sessions share: whether
    /// it starts it by itself, as `codex features list` prints it; nil for
    /// a Codex that has none.
    private func sharedServer(startsItself: Bool?) throws {
        let folder = root.appendingPathComponent("state-codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("shared-server")
        if let startsItself { try (startsItself ? "true\n" : "false\n").write(to: file, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: file) }
    }

    private var sharedServerStartsItself: String {
        ((try? String(contentsOf: root.appendingPathComponent("state-codex/shared-server"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SETUP-7 (#140): the background server Codex's sessions share is
    /// turned off with Codex's own command, as Codex 0.169.1 was seen to
    /// take it, and turned on again when AgentTerm's is taken out; while it
    /// still runs, that is said, with what to do; one the user had off is
    /// left off; a Codex that has none is asked nothing of it.
    func testCodexsSharedServerIsTurnedOffWithItsOwnCommandAndOnAgain() throws {
        try sharedServer(startsItself: true)
        let setup = setup()
        let before = try state(setup, "codex")
        XCTAssertEqual(before.sharedServerOff, false)
        XCTAssertTrue(before.note?.contains("codex features disable daemon_auto_start") == true, "what Install does to Codex is not said before it is done")

        setup.install("codex")
        XCTAssertTrue(ran("codex").contains("features disable daemon_auto_start"), ran("codex").joined(separator: "\n"))
        XCTAssertEqual(sharedServerStartsItself, "false")
        var after = try state(setup, "codex")
        XCTAssertEqual([after.hooks, after.mcp, after.sharedServerOff], [true, true, true])
        XCTAssertTrue(after.isSetUp)
        XCTAssertNil(after.problem)
        // Its hooks are still between their marks: the command kept them.
        XCTAssertTrue(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8).contains("hook codex Stop"))

        // Turned off, and one from before still runs: Codex uses it.
        FileManager.default.createFile(atPath: root.appendingPathComponent("state-codex/server-running").path, contents: nil)
        after = try state(setup, "codex")
        XCTAssertEqual(after.sharedServerOff, false)
        XCTAssertFalse(after.isSetUp)
        XCTAssertEqual(after.problem, AgentSetupWords.sharedServerRunning)
        XCTAssertTrue(after.problem?.contains("codex app-server daemon stop") == true)
        XCTAssertFalse(ran("codex").contains { $0.hasPrefix("app-server daemon stop") }, "the user's sessions were ended for them")
        try FileManager.default.removeItem(at: root.appendingPathComponent("state-codex/server-running"))
        XCTAssertEqual(try state(setup, "codex").sharedServerOff, true)

        setup.remove("codex")
        XCTAssertTrue(ran("codex").contains("features enable daemon_auto_start"), ran("codex").joined(separator: "\n"))
        XCTAssertEqual(sharedServerStartsItself, "true")
        XCTAssertEqual(try state(setup, "codex").sharedServerOff, false)
    }

    /// SETUP-7: a shared server the user had turned off is left off when
    /// AgentTerm's is taken out, and a Codex with no such server is asked
    /// nothing of it.
    func testASharedServerTheUserHadOffIsLeftOffAndACodexWithoutOneIsNotAsked() throws {
        try sharedServer(startsItself: false)
        let setup = setup()
        setup.install("codex")
        XCTAssertFalse(ran("codex").contains { $0.hasPrefix("features disable") })
        XCTAssertEqual(try state(setup, "codex").sharedServerOff, true)
        setup.remove("codex")
        XCTAssertFalse(ran("codex").contains { $0.hasPrefix("features enable") }, "turned on what the user had turned off")
        XCTAssertEqual(sharedServerStartsItself, "false")

        try sharedServer(startsItself: nil)
        let ranBefore = ran("codex").count
        setup.install("codex")
        let without = try state(setup, "codex")
        XCTAssertNil(without.sharedServerOff)
        XCTAssertTrue(without.isSetUp)
        XCTAssertFalse(without.note?.contains("daemon_auto_start") == true)
        let since = ran("codex").dropFirst(ranBefore)
        XCTAssertFalse(since.contains { $0.hasPrefix("features disable") || $0.hasPrefix("app-server") }, since.joined(separator: "\n"))
    }

    /// SETUP-7 (principle 7): with both builds set up in Codex, the one
    /// taken out first leaves the shared server off, which the other needs
    /// as much.
    func testTheSharedServerStaysOffWhileTheOtherBuildIsSetUp() throws {
        try sharedServer(startsItself: true)
        let released = setup(name: "agentterm", tool: "/Applications/AgentTerm.app/agenttermd")
        let development = setup()
        released.install("codex")
        development.install("codex")
        XCTAssertEqual(ran("codex").filter { $0 == "features disable daemon_auto_start" }.count, 1, "turned off twice")
        released.remove("codex")
        XCTAssertEqual(sharedServerStartsItself, "false", "turned on under the other build")
        XCTAssertEqual(try state(development, "codex").sharedServerOff, true)
        // Set up again and taken out, with no other left: on again.
        development.remove("codex")
        released.install("codex")
        released.remove("codex")
        XCTAssertEqual(sharedServerStartsItself, "true")
    }

    /// A table Codex adds to its config.toml, written where Codex 0.169.1
    /// was seen to write one (2026-11-18, `[features]`): after its last
    /// table, above the comments the file ends with.
    private func codexAdds(_ table: String) throws {
        let file = home.appendingPathComponent(".codex/config.toml")
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        var end = lines.count
        while end > 0, lines[end - 1].hasPrefix("#") { end -= 1 }
        lines.insert(contentsOf: [""] + table.components(separatedBy: "\n"), at: end)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// SETUP-8 (#142): what Codex itself adds to its config.toml after
    /// AgentTerm's hooks is the user's: the hooks installed again, then
    /// taken out, leave it there, and leave nothing of their own.
    func testWhatCodexAddsAfterTheHooksIsNotTakenOutWithThem() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o3\"\n".write(to: config, atomically: true, encoding: .utf8)
        let setup = setup()
        setup.install("codex")
        try codexAdds("[projects.\"/work\"]\ntrust_level = \"trusted\"")

        setup.install("codex")
        var text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("[projects.\"/work\"]\ntrust_level = \"trusted\""), "installing again took out what Codex added:\n" + text)
        XCTAssertEqual(text.components(separatedBy: "[[hooks.Stop]]").count - 1, 1, "its hooks are there twice:\n" + text)
        XCTAssertEqual(try state(setup, "codex").hooks, true)

        try codexAdds("[mcp_servers.mine]\ncommand = \"mine\"")
        setup.remove("codex")
        text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(
            text, "model = \"o3\"\n\n[projects.\"/work\"]\ntrust_level = \"trusted\"\n\n[mcp_servers.mine]\ncommand = \"mine\"\n",
            "taking the hooks out changed what is not AgentTerm's")
        XCTAssertEqual(try state(setup, "codex").hooks, false)
    }

    /// SETUP-8: the hooks of a build before this one, which were written
    /// between two marks, are taken out by their own lines too, and their
    /// marks with them; what Codex put between the marks stays.
    func testHooksWrittenBetweenMarksAreTakenOutByTheirOwnLines() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tool = "/Apps/AgentTerm Dev.app/agenttermd"
        let hook = { (event: String) in "[[hooks.\(event)]]\nhooks = [{ type = \"command\", command = \"'\(tool)' hook codex \(event)\" }]" }
        try """
        model = "o3"

        # >>> AgentTerm's hooks (agentterm-dev), added by `'\(tool)' setup codex`; `--remove` takes them out.
        \(hook("SessionStart"))
        \(hook("Stop"))

        [features]
        daemon_auto_start = false
        # <<< AgentTerm's hooks (agentterm-dev)

        """.write(to: config, atomically: true, encoding: .utf8)
        let setup = setup()
        setup.remove("codex")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "model = \"o3\"\n\n[features]\ndaemon_auto_start = false\n")
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
