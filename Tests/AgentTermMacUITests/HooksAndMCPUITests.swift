import AgentTermProtocol
import XCTest

/// Settings > Hooks & MCP, the onboarding, and the mark of an agent's
/// session (#129): HOOKS-1, ONBOARD-1 and LINK-6 in docs/TESTING.md. The
/// agents are the tests' stand-ins, set up in the test's home only.
final class HooksAndMCPUITests: MacUITestCase {
    override func setUpWithError() throws {
        // The onboarding's own test sees it; the others have it kept away.
        if name.contains("Onboarding") { appEnvironment["AGENTTERM_NO_ONBOARDING"] = nil }
        // Long enough to see what is still being checked (LINK-15).
        if name.contains("WhileItIsOpen") { linkGrace = "30" }
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

    /// HOOKS-2 (#140, #153): Codex's row says whether the background server
    /// its sessions share is in the way. Install turns it off with Codex's
    /// own command and stops the one that runs with another, both named in
    /// the row before it is pressed, Install All at the top of the list;
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
        XCTAssertEqual(label("setup-command-install-3-codex"), "codex app-server daemon stop")
        XCTAssertTrue(label("setup-command-install-4-codex").hasSuffix(" setup codex"), label("setup-command-install-4-codex"))
        XCTAssertEqual(label("setup-command-remove-2-codex"), "codex features enable daemon_auto_start")
        // Install All above the agents, in sight (#153).
        let all = try XCTUnwrap(app.frame(of: .id("setup-all")))
        let first = try XCTUnwrap(app.frame(of: .id("setup-codex")))
        XCTAssertLessThan(all.minY, first.minY, "Install All is under the agents")
        shot("hooks-codex-shared-server")

        // Turned off, and the one that runs stopped, with Codex's own command.
        app.press(.id("setup-install-codex"))
        app.wait("Codex set up", timeout: 30) { self.label("setup-codex-Hooks") == "Hooks, added" }
        XCTAssertTrue(asked("codex").contains("features disable daemon_auto_start"), asked("codex").joined(separator: "\n"))
        XCTAssertTrue(asked("codex").contains("app-server daemon stop"), asked("codex").joined(separator: "\n"))
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
        // Notifications among them, asked here up front (#180).
        app.wait(for: .containing("Tells you when an agent is done"))
        shot("onboarding-permissions")
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
        app.press(.id("onboarding-step-4"))
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

    /// ONBOARD-2: at the first launch of a build that reports, what may be
    /// sent is a step of the onboarding, which shows at once, alone: never
    /// two sheets one over the other (the owner's decision, 2026-11-21).
    /// Its Next answers it; answered, it is not a step any more.
    func testTheReportingQuestionIsAStepOfTheOnboarding() throws {
        appEnvironment["AGENTTERM_REPORTING_PREVIEW"] = "agentterm-ui-test-\(UUID().uuidString)"
        try relaunchApp()
        app.wait(for: .id("onboarding"), timeout: 15)
        app.press(.id("onboarding-next"))
        app.wait(for: .id("reporting-choices"), timeout: 15)
        // Long enough for the host to have said the agents miss their setup.
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(app.all(.id("onboarding")).count, 1, "more than one onboarding")
        shot("onboard-2-reports-step")
        app.press(.id("onboarding-next"))
        app.wait(for: .id("onboarding-add-folder"))
        app.press(.id("onboarding-skip"))
        app.waitGone(.id("onboarding"))
        try relaunchApp()
        app.wait(for: .id("onboarding"), timeout: 30)
        XCTAssertFalse(app.exists(.id("onboarding-step-1")), "the reports step, once answered")
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
        // Instructions saved for Claude Code: a test's host gives none by
        // default, having no MCP server of its own to give.
        let phone = try device()
        phone.send(.setAgentPrompt(agent: "claude", text: "Run your commands in AgentTerm's shells."))
        wait("the instructions saved") {
            phone.last { if case .agentPrompts(let custom, _) = $0 { return custom } else { return nil } }?["claude"] != nil
        }
        app.press(.button("Claude Code"))
        app.wait(for: .id("agent-link"), timeout: 20)
        app.wait("said missing", timeout: 15) { self.label("agent-link") == AgentLinkWords.summary(AgentLink(hooks: false, mcp: false)) }
        let value = app.first(.id("agent-link"))?.value ?? ""
        XCTAssertTrue(value.contains(AgentLinkWords.fix), value)
        // LINK-13 (#172): three rows, Hooks, MCP and System Prompt, each
        // with its state: Claude Code's instructions come through its MCP
        // server, which did not start, so they were not given.
        XCTAssertTrue(value.contains("\(AgentLinkWords.hooksRow): \(AgentLinkWords.hooksStatus(false))"), value)
        XCTAssertTrue(value.contains("\(AgentLinkWords.mcpRow): \(AgentLinkWords.mcpStatus(false))"), value)
        XCTAssertTrue(value.contains("\(AgentLinkWords.promptRow): \(AgentLinkWords.promptStatus(.missing))"), value)
        app.press(.id("agent-link"))
        app.wait(for: .id("agent-link-prompt"), timeout: 10)
        shot("agent-link")
    }

    /// A stand-in Antigravity for LINK-16, there before the host looks for
    /// the agents.
    override func makeFixtures() throws {
        try super.makeFixtures()
        guard name.contains("Unverified") else { return }
        let agy = root.appendingPathComponent("agents/agy")
        try "#!/bin/sh\nexec cat\n".write(to: agy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
    }

    /// Instructions saved for an agent, as Settings > Agents saves them.
    private func saveInstructions(_ text: String, for agent: String, _ phone: Device) {
        phone.send(.setAgentPrompt(agent: agent, text: text))
        wait("the instructions saved for \(agent)") {
            phone.last { if case .agentPrompts(let custom, _) = $0 { return custom } else { return nil } }?[agent] == text
        }
    }

    /// What the session's mark says of each of its three rows.
    private func says(_ row: String, _ status: String) -> Bool {
        (app.first(.id("agent-link"))?.value ?? "").contains("\(row): \(status) ") || (app.first(.id("agent-link"))?.value ?? "").hasSuffix("\(row): \(status)")
    }

    /// LINK-15 (#172): the mark's popover, open from the start, follows the
    /// session as it goes: everything being checked; the hooks heard, the
    /// MCP server still being checked; then the server heard and the
    /// instructions given, all green.
    func testTheMarksPopoverFollowsTheSessionWhileItIsOpen() throws {
        let phone = try device()
        saveInstructions("Run your commands in AgentTerm's shells.", for: "claude", phone)
        let hooksNow = root.appendingPathComponent("hooks-now")
        let mcpNow = root.appendingPathComponent("mcp-now")
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let event = #"printf '{"agent":"claude","event":"SessionStart","at":%s,"input":{}}' "$(date +%s)" > "$\#(AppChannel.current.eventsVariable)""#
        // A stand-in Claude Code that is heard when the test says so.
        try """
        #!/bin/sh
        while [ ! -e '\(hooksNow.path)' ]; do sleep 0.2; done
        \(event)
        while [ ! -e '\(mcpNow.path)' ]; do sleep 0.2; done
        ( printf '%s\\n' '\(initialize)'; sleep 600 ) | '\(hostExecutable.path)' mcp > /dev/null 2>&1 &
        exec cat
        """.write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        app.press(.button("Claude Code"))
        app.wait(for: .id("agent-link"), timeout: 20)
        app.press(.id("agent-link"))
        app.wait(for: .id("agent-link-prompt"), timeout: 10)
        XCTAssertTrue(says(AgentLinkWords.hooksRow, AgentLinkWords.checking), app.first(.id("agent-link"))?.value ?? "")
        XCTAssertTrue(says(AgentLinkWords.mcpRow, AgentLinkWords.checking))
        XCTAssertTrue(says(AgentLinkWords.promptRow, AgentLinkWords.checking))
        shot("popover-checking")
        try Data().write(to: hooksNow)
        app.wait("the hooks heard, the popover still open", timeout: 15) {
            self.says(AgentLinkWords.hooksRow, AgentLinkWords.hooksStatus(true)) && self.app.exists(.id("agent-link-prompt"))
        }
        XCTAssertTrue(says(AgentLinkWords.mcpRow, AgentLinkWords.checking), "the MCP server said heard before it started")
        XCTAssertTrue(app.first(.id("agent-link-hooks"))?.value.contains(AgentLinkWords.hooksStatus(true)) == true, "the popover's row is not the mark's")
        shot("popover-hooks-heard")
        try Data().write(to: mcpNow)
        app.wait("the server heard and the instructions given, the popover still open", timeout: 15) {
            self.says(AgentLinkWords.mcpRow, AgentLinkWords.mcpStatus(true)) && self.says(AgentLinkWords.promptRow, AgentLinkWords.promptStatus(.given))
                && self.app.exists(.id("agent-link-prompt"))
        }
        XCTAssertTrue(app.first(.id("agent-link-prompt"))?.value.contains(AgentLinkWords.promptStatus(.given)) == true)
        shot("popover-all-given")
    }

    /// LINK-16 (#172): a session whose hooks are heard and whose MCP server
    /// is not: green, red, and its instructions, which come through the
    /// server, not given. No instructions saved for the agent: disabled.
    /// Antigravity, which is given them in a way AgentTerm cannot see for
    /// one session: unverified.
    func testThePopoverSaysHooksWithoutTheServerDisabledAndUnverified() throws {
        let phone = try device()
        saveInstructions("Run your commands in AgentTerm's shells.", for: "claude", phone)
        let event = #"printf '{"agent":"claude","event":"SessionStart","at":%s,"input":{}}' "$(date +%s)" > "$\#(AppChannel.current.eventsVariable)""#
        try "#!/bin/sh\n\(event)\nexec cat\n".write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        app.press(.button("Claude Code"))
        app.wait(for: .id("agent-link"), timeout: 20)
        app.wait("hooks heard, the server not", timeout: 15) {
            self.says(AgentLinkWords.hooksRow, AgentLinkWords.hooksStatus(true)) && self.says(AgentLinkWords.mcpRow, AgentLinkWords.mcpStatus(false))
        }
        XCTAssertTrue(says(AgentLinkWords.promptRow, AgentLinkWords.promptStatus(.missing)), app.first(.id("agent-link"))?.value ?? "")
        app.press(.id("agent-link"))
        app.wait(for: .id("agent-link-mcp"), timeout: 10)
        shot("popover-hooks-without-server")
        app.press(.id("agent-link"))

        // No instructions for Claude Code: a new session says them disabled.
        saveInstructions("", for: "claude", phone)
        // The session that runs still says what it was given when it
        // started, whatever is saved since.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(says(AgentLinkWords.promptRow, AgentLinkWords.promptStatus(.missing)), "a settings edit changed what a running session says")
        let first = phone.sessions.map(\.id)
        app.press(.button("Claude Code"))
        wait("a second session") { phone.sessions.count == first.count + 1 }
        app.wait("disabled", timeout: 15) { self.says(AgentLinkWords.promptRow, AgentLinkWords.promptStatus(.disabled)) }

        // Antigravity, with instructions: unverified.
        saveInstructions("Run your commands in AgentTerm's shells.", for: "agy", phone)
        app.press(.button("Antigravity"))
        wait("Antigravity's session") { phone.sessions.contains { $0.agent == "agy" } }
        app.wait("unverified", timeout: 15) { self.says(AgentLinkWords.promptRow, AgentLinkWords.promptStatus(.unverified)) }
        app.press(.id("agent-link"))
        app.wait(for: .id("agent-link-prompt"), timeout: 10)
        XCTAssertTrue(app.first(.id("agent-link-prompt"))?.value.contains(AgentLinkWords.promptStatus(.unverified)) == true)
        shot("popover-unverified")
    }
}
