import AgentTermProtocol
import XCTest

/// Settings > Hooks & MCP, the onboarding, and the mark of an agent's
/// session (#129): HOOKS-1, ONBOARD-1 and LINK-6 in docs/TESTING.md. The
/// agents are the tests' stand-ins, set up in the test's home only.
final class HooksAndMCPUITests: MacUITestCase {
    override func setUpWithError() throws {
        // The onboarding's own test sees it; the others have it kept away.
        if name.contains("Onboarding") { appEnvironment["AGENTTERM_NO_ONBOARDING"] = nil }
        try super.setUpWithError()
    }

    /// How a stand-in was asked of its plugins, a line each time.
    private func asked(_ agent: String) -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("agents/plugins-\(agent).log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// What an element says: a text's value, or a control's label.
    private func label(_ id: String) -> String {
        guard let node = app.first(.id(id)) else { return "" }
        return node.label.isEmpty ? node.value : node.label
    }

    /// HOOKS-1: the pane lists each agent and what it has of AgentTerm's,
    /// asked of the agent; Install adds it with the agent's own commands
    /// and the pane says so; Remove takes it out; an agent not installed is
    /// said so, with no button.
    func testHooksAndMCPAreSetUpFromSettings() throws {
        app.press(.id("place-settings"))
        app.press(.id("settings-hooks"))
        app.wait(for: .id("setup-claude"), timeout: 20)
        app.wait("Claude Code's state") { self.label("setup-claude-Hooks") == "Hooks, not added" }
        XCTAssertEqual(label("setup-claude-MCP server"), "MCP server, not added")
        XCTAssertEqual(label("setup-claude-Status line"), "Status line, not added")
        XCTAssertFalse(app.exists(.id("setup-install-copilot")), "an agent that is not installed can be installed for")
        XCTAssertTrue(app.exists(.text(AgentSetupWords.notInstalled)))
        XCTAssertFalse(app.exists(.id("setup-remove-claude")), "nothing to remove, and Remove offered")
        // The commands, each part with its own: Claude Code's for the
        // server, then AgentTerm's for what Claude Code has no command for.
        XCTAssertTrue(label("setup-command-install-1-claude").hasPrefix("claude mcp add --scope user agentterm-dev -- "), label("setup-command-install-1-claude"))
        XCTAssertTrue(label("setup-command-install-1-claude").hasSuffix(" mcp"))
        XCTAssertTrue(label("setup-command-install-2-claude").hasSuffix(" setup claude"), label("setup-command-install-2-claude"))
        XCTAssertEqual(label("setup-command-remove-1-claude"), "claude mcp remove --scope user agentterm-dev")
        XCTAssertTrue(app.exists(.text(AgentSetupWords.serverStep("Claude Code"))))
        XCTAssertTrue(app.exists(.text(AgentSetupWords.ownStep(agent: "claude", name: "Claude Code"))))
        shot("hooks-pane")

        app.press(.id("setup-install-claude"))
        app.wait("Claude Code set up", timeout: 30) { self.label("setup-claude-Hooks") == "Hooks, added" }
        XCTAssertEqual(label("setup-claude-MCP server"), "MCP server, added")
        XCTAssertEqual(label("setup-claude-Status line"), "Status line, added")
        XCTAssertTrue(
            asked("claude").contains { $0.hasPrefix("mcp add --scope user agentterm-dev -- ") && $0.hasSuffix(" mcp") }, asked("claude").joined(separator: "\n"))
        XCTAssertTrue(asked("claude").contains { $0.hasPrefix("plugin marketplace add ") }, asked("claude").joined(separator: "\n"))
        XCTAssertTrue(asked("claude").contains("plugin install agentterm-dev@agentterm-dev --scope user"), asked("claude").joined(separator: "\n"))
        let settings = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        XCTAssertTrue(settings.contains("agenttermd") && settings.contains("statusline"), settings)

        app.press(.id("setup-remove-claude"))
        app.wait("Claude Code taken out", timeout: 30) { self.label("setup-claude-Hooks") == "Hooks, not added" }
        XCTAssertEqual(label("setup-claude-Status line"), "Status line, not added")
        XCTAssertEqual(label("setup-claude-MCP server"), "MCP server, not added")
        XCTAssertTrue(asked("claude").contains("mcp remove --scope user agentterm-dev"), asked("claude").joined(separator: "\n"))
        XCTAssertTrue(asked("claude").contains("plugin uninstall agentterm-dev@agentterm-dev --scope user"))
    }

    /// HOOKS-2 (#140): Codex's row says whether the background server its
    /// sessions share is in the way. Install turns it off with Codex's own
    /// command, which the row names before it is pressed; one that still
    /// runs is said, with what to do, and nothing is stopped for the user;
    /// Remove turns it on again.
    func testCodexsSharedServerIsTurnedOffFromSettings() throws {
        let codex = root.appendingPathComponent("agents/plugins-codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "true\n".write(to: codex.appendingPathComponent("shared-server"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: codex.appendingPathComponent("server-running").path, contents: nil)
        app.press(.id("place-settings"))
        app.press(.id("settings-hooks"))
        app.wait(for: .id("setup-codex"), timeout: 20)
        app.wait("Codex's shared server said on") { self.label("setup-codex-shared-server") == AgentSetupWords.sharedServer(off: false) }
        XCTAssertTrue(app.exists(.containing("codex features disable daemon_auto_start")), "what Install does to Codex is not said before it is pressed")
        XCTAssertFalse(app.exists(.id("setup-problem-codex")))
        // Its own commands first, the one for its shared server among them.
        XCTAssertTrue(label("setup-command-install-1-codex").hasPrefix("codex mcp add agentterm-dev -- "), label("setup-command-install-1-codex"))
        XCTAssertEqual(label("setup-command-install-2-codex"), "codex features disable daemon_auto_start")
        XCTAssertTrue(label("setup-command-install-3-codex").hasSuffix(" setup codex"), label("setup-command-install-3-codex"))
        XCTAssertEqual(label("setup-command-remove-2-codex"), "codex features enable daemon_auto_start")

        // Turned off, and one from before still runs.
        app.press(.id("setup-install-codex"))
        app.wait("Codex set up", timeout: 30) { self.label("setup-codex-Hooks") == "Hooks, added" }
        XCTAssertTrue(asked("codex").contains("features disable daemon_auto_start"), asked("codex").joined(separator: "\n"))
        app.wait("the one that runs said") { self.label("setup-problem-codex") == AgentSetupWords.sharedServerRunning }
        XCTAssertEqual(label("setup-codex-shared-server"), AgentSetupWords.sharedServer(off: false))
        XCTAssertFalse(asked("codex").contains { $0.hasPrefix("app-server daemon stop") }, "Codex's sessions were ended for the user")
        shot("hooks-codex-shared-server")

        // Stopped by the user: asked again, it is out of the way.
        try FileManager.default.removeItem(at: codex.appendingPathComponent("server-running"))
        app.press(.id("settings-shell"))
        app.press(.id("settings-hooks"))
        app.wait("Codex's shared server said off", timeout: 20) { self.label("setup-codex-shared-server") == AgentSetupWords.sharedServer(off: true) }
        XCTAssertFalse(app.exists(.id("setup-problem-codex")))

        app.press(.id("setup-remove-codex"))
        app.wait("Codex's taken out", timeout: 30) { self.label("setup-codex-Hooks") == "Hooks, not added" }
        XCTAssertTrue(asked("codex").contains("features enable daemon_auto_start"), asked("codex").joined(separator: "\n"))
        XCTAssertEqual(label("setup-codex-shared-server"), AgentSetupWords.sharedServer(off: false))
    }

    /// ONBOARD-1: the onboarding shows each time the app opens while an
    /// installed agent misses its hooks or MCP server, its steps one after
    /// the other; once every agent is set up from it, it does not; asked
    /// not to, it does not either; Settings shows it again.
    func testTheOnboardingShowsWhileAnAgentIsNotSetUp() throws {
        app.wait(for: .id("onboarding"), timeout: 30)
        XCTAssertTrue(app.exists(.containing("Welcome to")))
        app.press(.id("onboarding-next"))
        app.wait(for: .id("onboarding-add-folder"))
        app.press(.id("onboarding-next"))
        app.wait(for: .containing("Permissions"))
        app.press(.id("onboarding-next"))
        app.wait(for: .id("setup-claude"), timeout: 20)
        shot("onboarding-agents")
        app.press(.id("onboarding-next"))
        app.wait(for: .id("onboarding-pair"))
        // Closed: shown again the next time.
        app.press(.id("onboarding-skip"))
        app.waitGone(.id("onboarding"))
        try relaunchApp()
        app.wait(for: .id("onboarding"), timeout: 30)

        // Every agent set up from it: not shown again.
        app.press(.id("onboarding-step-3"))
        app.wait(for: .id("setup-all"), timeout: 20)
        app.press(.id("setup-all"))
        app.wait("both set up", timeout: 40) { self.label("setup-claude-Hooks") == "Hooks, added" && self.label("setup-codex-Hooks") == "Hooks, added" }
        app.press(.id("onboarding-skip"))
        try relaunchApp()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(app.exists(.id("onboarding")), "shown with every agent set up")

        // Settings has it again.
        app.press(.id("place-settings"))
        app.press(.id("settings-hooks"))
        app.press(.id("show-onboarding"))
        app.wait(for: .id("onboarding"))
        app.press(.id("onboarding-hide"))
        app.press(.id("onboarding-skip"))
        app.waitGone(.id("onboarding"))
    }

    /// LINK-8 (#129): a shell opened with the key of a shell of the user's,
    /// as an agent typed there does, is the user's: in the list and in the
    /// row of the Shells tab, not lost for want of an agent's tab.
    func testAShellOpenedFromAShellOfTheUsersIsTheUsers() throws {
        let phone = try device()
        app.menu(["File", "New Shell"])
        wait("the shell") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first)
        phone.send(.attach(session: shell.id, size: .default))
        let key = root.appendingPathComponent("key")
        phone.connection.sendInput(Data("printf '%s' \"$AGENTTERM_MCP\" > '\(key.path)'\r".utf8), to: shell.id)
        wait("its key") { ((try? String(contentsOf: key, encoding: .utf8)) ?? "").isEmpty == false }
        let server = try MCPServerProcess(tool: hostExecutable, variable: try String(contentsOf: key, encoding: .utf8), state: state)
        defer { server.stop() }
        let opened = server.text("shell_open", ["title": "from-the-shell"])
        XCTAssertFalse(opened.failed, opened.text)
        wait("the second shell") { phone.sessions.count == 2 }
        let second = try XCTUnwrap(phone.sessions.first { $0.id != shell.id })
        XCTAssertEqual(second.openedBy, shell.id)
        app.wait(for: .id("session-\(second.id)"), timeout: 15)
        app.press(.id("session-\(second.id)"))
        app.wait(for: .id("item-\(second.id)"))
        XCTAssertTrue(app.exists(.id("strip-shells")))
    }

    /// LINK-9 (#129): an agent typed in a shell of the user's is heard as one
    /// started from a button while it runs: the shell shows its usage band
    /// and the mark of its hooks and server; once it ends, a shell again.
    func testAnAgentTypedInAShellIsShownWhileItRuns() throws {
        let phone = try device()
        app.menu(["File", "New Shell"])
        wait("the shell") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first)
        phone.send(.attach(session: shell.id, size: .default))
        app.wait(for: .id("session-\(shell.id)"), timeout: 15)
        app.press(.id("session-\(shell.id)"))
        XCTAssertFalse(app.exists(.id("agent-link")), "a shell has the mark of an agent's")
        // A program named as Claude Code's, typed by its path, as LINK-4.
        let program = root.appendingPathComponent("typed/claude")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: program.path, withDestinationPath: "/bin/sleep")
        phone.connection.sendInput(Data("'\(program.path)' 600\r".utf8), to: shell.id)
        wait("the agent typed found") { phone.sessions.first?.typedAgent == "claude" }
        app.wait(for: .id("agent-link"), timeout: 15)
        phone.connection.sendInput(Data([3]), to: shell.id)
        wait("a shell again") { phone.sessions.first?.typedAgent == nil }
        wait("its mark gone") { !self.app.exists(.id("agent-link")) }
    }

    /// LINK-6: an agent's session has a mark that says whether its hooks
    /// and AgentTerm's MCP server are heard: missing for the stand-in, which
    /// has neither, with what to do.
    func testAnAgentsSessionShowsWhetherItsHooksAndServerAreHeard() throws {
        app.press(.button("Claude Code"))
        app.wait(for: .id("agent-link"), timeout: 20)
        app.wait("said missing", timeout: 15) { self.label("agent-link") == AgentLinkWords.summary(AgentLink(hooks: false, mcp: false)) }
        let value = app.first(.id("agent-link"))?.value ?? ""
        XCTAssertTrue(value.contains(AgentLinkWords.fix), value)
        shot("agent-link")
    }
}
