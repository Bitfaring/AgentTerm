import AgentTermProtocol
import XCTest

/// Starting sessions from the Mac app, and what it shows of the Mac.
final class SessionTests: MacUITestCase {
    func testTheWindowShowsTheFolderTheAgentsAndTheMac() throws {
        // WIN-1: the folder of the host's list.
        app.wait(for: .text("project, folder"))
        // LAUNCH-1: a button for each agent in the header; one that is not
        // installed is there too, said to be not installed (#50).
        app.wait(for: .button("Claude Code"))
        XCTAssertTrue(app.exists(.button("Codex")))
        XCTAssertTrue(app.exists(.button("Shell")))
        XCTAssertTrue(app.exists(.button("Antigravity, not installed")), "an agent that is not installed has no button in the header")
        XCTAssertTrue(app.exists(.button("Copilot CLI, not installed")))
        XCTAssertFalse(app.exists(.button("Antigravity")))
        // SYS-2: how the Mac is doing.
        for figure in ["system-cpu", "system-memory", "system-down", "system-up", "system-temperature", "system-battery", "system-uptime", "system-memory-used"] {
            app.wait(for: .id(figure), timeout: 15)
        }
        XCTAssertTrue(app.first(.id("system-cpu"))?.label.hasPrefix("CPU ") ?? false)
        // #154: the memory in gigabytes too, as the iPhone has it ("12.4/32 GB").
        let memory = app.first(.id("system-memory-used"))?.label ?? ""
        XCTAssertNotNil(memory.range(of: #"^Memory \d+\.\d/\d+ GB$"#, options: .regularExpression), memory)
    }

    /// LAUNCH-6 (#50): an agent that is not installed, pressed in the
    /// header, says how to install it: its maker's command; looked for
    /// again, it is still missing and says why that may be; Install in a
    /// New Shell opens a shell with the command typed in and not run.
    /// Nothing is ever run here: Return is not pressed, and the shell is ended.
    func testAnAgentThatIsNotInstalledSaysHowToInstallIt() throws {
        let phone = try device()
        app.press(.button("Antigravity, not installed"))
        app.wait(for: .text("Install Antigravity"))
        XCTAssertTrue(app.exists(.text("curl -fsSL https://antigravity.google/cli/install.sh | bash")), "the maker's command is not shown")
        XCTAssertTrue(app.exists(.id("install-docs")))
        app.press(.button("Look Again"))
        app.wait(for: .id("install-still-missing"), timeout: 20)
        shot("install-guide")
        XCTAssertEqual(phone.sessions, [], "a session was started before it was asked for")

        app.press(.button("Install in a New Shell"))
        // The sheet goes; the shell's tab has its name.
        app.waitGone(.button("Install in a New Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first)
        XCTAssertNil(shell.agent)
        phone.send(.attach(session: shell.id, size: .default, have: nil, history: nil))
        wait("the command typed at its prompt") { phone.text(shell.id).contains("antigravity.google/cli/install.sh") }
        phone.send(.kill(session: shell.id))
        wait("the shell ended, the command not run") { phone.sessions.isEmpty }
    }

    /// TEST-1: the host and the app a test starts, and the login shells they
    /// start in turn, use the test's home folder, so no startup file of
    /// the person running the tests is read.
    func testTheShellsOfATestUseTheTestsHome() throws {
        let phone = try device()
        let seen = root.appendingPathComponent("seen-home")
        // Started by the app's host, through the login shell, as every session is.
        phone.send(.create(CreateRequest(command: "printf '%s' \"$HOME\" > '\(seen.path)'; sleep 600", cwd: project.path, title: "home")))
        wait("the session to write its home") { FileManager.default.fileExists(atPath: seen.path) }
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), home.path)
    }

    /// AGENT-9: what an agent says it is doing shows next to its session,
    /// in the folder list and on its tab, and its folder says it waits.
    func testTheStateOfAnAgentShowsWithItsSession() throws {
        let phone = try device()
        // A stand-in for Claude Code, under its name: it tells its hooks, as
        // Claude Code does, that it waits for permission to run a command.
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        let event = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make test"}}"#
        try "#!/bin/sh\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude PermissionRequest\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "review")))
        wait("the host to know it waits") { phone.sessions.first?.state?.isWaiting == true }
        let id = try XCTUnwrap(phone.sessions.first?.id)

        app.wait(for: .containing("review, session, waiting for permission"), timeout: 15)
        app.wait(for: .containing("project, folder, a session waits"))
        app.press(.id("session-\(id)"))
        app.wait(for: .containing("review, waiting for permission"))
        shot("waiting")
    }

    /// NOTE-4: an agent of a session that is not in front that comes to
    /// wait is told in a banner, which opens it.
    func testAnAgentThatWaitsInAnotherSessionIsToldInABanner() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        // A stand-in for Claude Code that asks permission a moment after it starts.
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        let event = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make deploy"}}"#
        try "#!/bin/sh\nsleep 2\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude PermissionRequest\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "deploy")))
        wait("the agent's session") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell }?.id)
        // The shell is the one in front, and the window on History: the
        // banner shows over every place, and Open goes to Sessions.
        app.press(.id("session-\(shell)"))
        app.press(.id("place-history"))
        app.wait(for: .text("HISTORY"))

        // Named after the conversation the stand-in folder's history gives it.
        app.wait(for: .containing("needs permission"), timeout: 15)
        app.wait(for: .containing("make deploy"))
        shot("notice")
        app.press(.button("Open"))
        app.waitGone(.containing("needs permission"))
        app.wait(for: .text("FOLDERS"))
        app.wait(for: .id("session-\(agent)"))
    }

    /// A shell in front and a stand-in agent in another session that comes
    /// to ask for permission, with the banner that says so on screen.
    private func aBannerForAnAgentBehindAShell(
        _ phone: Device, hook: String = "PermissionRequest",
        event: String = #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make deploy"}}"#, says: String = "needs permission"
    ) throws -> (shell: SessionID, agent: SessionID) {
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        let folder = root.appendingPathComponent("stand-in")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        try "#!/bin/sh\nsleep 2\nprintf '%s' '\(event)' | '\(hostExecutable.path)' hook claude \(hook)\nexec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "deploy")))
        wait("the agent's session") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell }?.id)
        app.press(.id("session-\(shell)"))
        app.wait(for: .containing(says), timeout: 15)
        return (shell, agent)
    }

    /// A stand-in for an agent, Claude Code unless said, under its name,
    /// that tells its hooks one event a moment after it starts.
    private func standInAgent(_ name: String, agent: String = "claude", hook: String, event: String) throws -> URL {
        try standInAgent(name, agent: agent, events: [(hook, event)])
    }

    /// A stand-in that tells its hooks the events of a turn, a second apart.
    private func standInAgent(_ name: String, agent: String, events: [(hook: String, event: String)]) throws -> URL {
        let folder = root.appendingPathComponent("stand-in-\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent(agent)
        let told = events.map { "sleep 1\nprintf '%s' '\($0.event)' | '\(hostExecutable.path)' hook \(agent) \($0.hook)\n" }.joined()
        try "#!/bin/sh\n\(told)exec sleep 600\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// INBOX-3 (#67, #66): the Inbox is this Mac's history of what it was
    /// told, with how many are unread on its place in the rail; the item
    /// picked is shown in the middle, the terminals hidden as in History,
    /// and read, without being seen; Open shows its session in Sessions,
    /// which sees it on every device, and it stays, as opened; Delete takes
    /// one out here only; what waits cannot be deleted.
    func testTheInboxListsWhatNeedsTheUser() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        let asks = try standInAgent(
            "asks", hook: "PermissionRequest", event: #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"make deploy"}}"#)
        func done(_ name: String, _ said: String, agent: String = "claude") throws -> URL {
            try standInAgent(name, agent: agent, hook: "Stop", event: #"{"hook_event_name":"Stop","last_assistant_message":"\#(said)"}"#)
        }
        phone.send(.create(CreateRequest(command: asks.path, cwd: project.path, title: "deploy")))
        phone.send(.create(CreateRequest(command: try done("tests", "All tests pass.").path, cwd: project.path, title: "tests")))
        // Codex, with the events Codex 0.169.0 told its hooks for a turn
        // that ran a command (2026-11-17).
        let codex = try standInAgent(
            "docs", agent: "codex",
            events: [
                ("UserPromptSubmit", #"{"hook_event_name":"UserPromptSubmit","prompt":"Write the docs.","turn_id":"t-1"}"#),
                ("PreToolUse", #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make docs"},"tool_use_id":"exec-1","turn_id":"t-1"}"#),
                (
                    "PostToolUse",
                    #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"make docs"},"tool_response":"ok","tool_use_id":"exec-1","turn_id":"t-1"}"#
                ),
                ("Stop", #"{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The docs are written.","turn_id":"t-1"}"#),
            ])
        phone.send(.create(CreateRequest(command: codex.path, cwd: project.path, title: "docs")))
        phone.send(.create(CreateRequest(command: try done("notes", "The notes are tidied.").path, cwd: project.path, title: "notes")))
        wait("the four agents' states", timeout: 20) { phone.sessions.filter { $0.state?.isWorking == false }.count == 4 }
        func id(_ title: String) throws -> SessionID { try XCTUnwrap(phone.sessions.first { $0.title == title }?.id) }
        let deploy = try id("deploy"), tests = try id("tests"), docs = try id("docs"), notes = try id("notes")
        // The shell is in front: none of them is seen.
        bringAppToFront()
        app.press(.id("session-\(shell)"))
        app.wait(for: .containing("Inbox, 4 items"), timeout: 15)

        app.press(.id("place-inbox"))
        app.wait(for: .id(phone.inboxRow(deploy)))
        XCTAssertTrue(app.first(.id(phone.inboxRow(deploy)))?.label.contains("needs permission") == true)
        XCTAssertTrue(app.first(.id(phone.inboxRow(tests)))?.label.contains("All tests pass.") == true)
        XCTAssertNil(app.first(.id("terminal-\(shell)")), "a terminal shows in the Inbox")
        // What waits cannot be deleted: it stays until it is answered.
        app.press(.id(phone.inboxRow(deploy)))
        app.wait(for: .id("inbox-detail-text"))
        XCTAssertTrue(app.first(.id("inbox-detail-text"))?.text.contains("make deploy") == true)
        XCTAssertNil(app.first(.id("inbox-dismiss")))
        shot("inbox")

        // Picked: shown in the middle, read here, and not seen for that.
        app.press(.id(phone.inboxRow(tests)))
        app.wait(for: .containing("All tests pass."))
        XCTAssertTrue(app.first(.id("inbox-detail-text"))?.text.contains("All tests pass.") == true)
        shot("inbox-done")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(phone.sessions.first { $0.id == tests }?.unseen, true, "picking an item saw its session")
        app.wait(for: .containing("Inbox, 2 items"))
        // Opened: in Sessions, and seen on every device.
        app.press(.id("inbox-open"))
        app.wait(for: .id("terminal-\(tests)"))
        wait("seen, as the phone is told") { phone.sessions.first { $0.id == tests }?.unseen != true }

        // Kept after it is read, with how it was handled.
        app.press(.id("place-inbox"))
        app.wait(for: .id(phone.inboxRow(tests)))
        wait("handled, as opened") { app.first(.id(phone.inboxRow(tests)))?.label.contains("Opened") == true }
        // Deleted: from this Mac's Inbox only; the phone still has it unseen.
        app.press(.id(phone.inboxRow(docs)))
        app.wait(for: .containing("The docs are written."))
        app.press(.id("inbox-dismiss"))
        app.waitGone(.id(phone.inboxRow(docs)), timeout: 15)
        XCTAssertEqual(phone.sessions.first { $0.id == docs }?.unseen, true, "deleted here, as seen everywhere")
        // Seen on another device: handled here too, and kept.
        phone.send(.noticeSeen(session: notes, state: .done(said: "The notes are tidied.")))
        wait("handled, as seen elsewhere") { app.first(.id(phone.inboxRow(notes)))?.label.contains("Opened") == true }
        // Delete All takes everything but what still waits.
        app.press(.id("inbox-menu"))
        app.press(.button(InboxWords.deleteAll))
        app.wait(for: .id("inbox-delete-all"))
        app.press(.id("inbox-delete-all"))
        app.waitGone(.id(phone.inboxRow(notes)), timeout: 15)
        XCTAssertNotNil(app.first(.id(phone.inboxRow(deploy))), "what waits for an answer was deleted")
    }

    /// INBOX-6 (#71): a done agent's item shows what its turn came to: what
    /// it was asked, what it said, the commands of its record with their
    /// exit codes, the files that changed while it worked, and that another
    /// agent worked in the same repository meanwhile; Open Diff shows the
    /// session with the folder's changes beside it; Continue types the next
    /// instruction into the other's session, which then leaves the Inbox.
    func testADoneItemShowsWhatTheTurnCameTo() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try [
            #"{"type":"user","message":{"role":"user","content":"Tidy the notes"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"make lint"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 2\nlint failed"}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("stand-in-turn")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("claude")
        let hook = "'\(hostExecutable.path)' hook claude"
        let stop = #"{"hook_event_name":"Stop","last_assistant_message":"The notes are tidied; lint fails.","transcript_path":"\#(transcript.path)"}"#
        try """
        #!/bin/sh
        sleep 1
        printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"Tidy the notes"}' | \(hook) UserPromptSubmit
        sleep 2
        printf 'tidied\\n' >> notes.txt; printf 'new\\n' > turn.txt
        printf '%s' '\(stop)' | \(hook) Stop
        exec cat
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // Two of them in the same repository, at the same time.
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "notes")))
        phone.send(.create(CreateRequest(command: script.path, cwd: project.path, title: "again")))
        wait("the agents' sessions") { phone.sessions.count == 3 }
        let notes = try XCTUnwrap(phone.sessions.first { $0.title == "notes" }?.id)
        let again = try XCTUnwrap(phone.sessions.first { $0.title == "again" }?.id)
        bringAppToFront()
        app.press(.id("session-\(shell)"))
        func told(_ id: SessionID) -> Bool { phone.messages.contains { if case .turnResult(id, _) = $0 { return true } else { return false } } }
        wait("what the turns came to", timeout: 20) { told(notes) && told(again) }

        app.press(.id("place-inbox"))
        app.press(.id(phone.inboxRow(notes)))
        app.wait(for: .id("inbox-request"))
        XCTAssertTrue(app.first(.id("inbox-request"))?.text.contains("Tidy the notes") == true)
        XCTAssertTrue(app.first(.id("inbox-detail-text"))?.text.contains("lint fails") == true)
        let commands = app.nodes().filter { $0.identifier == "inbox-command" }.map(\.text)
        XCTAssertEqual(commands.count, 2, "\(commands)")
        XCTAssertTrue(commands.first?.contains("swift test") == true && commands.first?.contains("exit 0") == true, "\(commands)")
        XCTAssertTrue(commands.last?.contains("make lint") == true && commands.last?.contains("exit 2") == true, "\(commands)")
        let files = app.nodes().filter { $0.identifier == "inbox-file" }.map(\.text)
        XCTAssertTrue(files.contains { $0.contains("notes.txt") && $0.contains("already changed before") }, "\(files)")
        XCTAssertTrue(files.contains { $0.contains("turn.txt") && $0.contains("??") }, "\(files)")
        XCTAssertNotNil(app.first(.id("inbox-shared")), "another agent in the same repository is not said")
        shot("result")

        // Open Diff: the session in Sessions, its folder's changes beside it.
        app.press(.id("inbox-open-diff"))
        app.wait(for: .id("terminal-\(notes)"))
        app.wait(for: .id("panel-git"))
        shot("open-diff")

        // Continue: the next instruction, typed into the other's session.
        phone.send(.attach(session: again, size: TermSize(cols: 80, rows: 24)))
        app.press(.id("place-inbox"))
        app.press(.id(phone.inboxRow(again)))
        app.write("Now fix lint", into: .id("inbox-continue"))
        app.press(.id("inbox-send"))
        wait("the instruction typed into the session") { phone.text(again).contains("Now fix lint") }
    }

    /// NOTE-13 (#62): a banner tells the end of what an agent said, and
    /// opens out to all of it.
    func testABannerOpensOutToAllOfWhatTheAgentSaid() throws {
        let phone = try device()
        let said = "The beginning of it all. " + String(repeating: "Then one more thing was done and checked. ", count: 30) + "And that is the end of it."
        _ = try aBannerForAnAgentBehindAShell(
            phone, hook: "Stop", event: #"{"hook_event_name":"Stop","last_assistant_message":"\#(said)"}"#, says: "is done")
        app.wait(for: .containing("And that is the end of it."))
        XCTAssertNil(app.first(.containing("The beginning of it all.")), "the end of it, until it is opened out")
        shot("short")
        app.press(.id("agent-notice-more"))
        app.wait(for: .containing("The beginning of it all."))
        shot("all")
        app.press(.id("agent-notice-more"))
        app.waitGone(.containing("The beginning of it all."))
    }

    /// NOTE-9 (#60): a banner hides by itself once its session is the one
    /// in front, however the user got there, and does not come back; the
    /// other devices are told that it was seen.
    func testABannerHidesWhenItsSessionIsOpenedFromTheList() throws {
        let phone = try device()
        let (shell, agent) = try aBannerForAnAgentBehindAShell(phone)
        bringAppToFront()

        // Not the banner's Open: the session's own row.
        app.press(.id("session-\(agent)"))
        app.waitGone(.containing("needs permission"))
        shot("gone")
        wait("the phone to be told that it was seen") {
            phone.last { if case .noticeSeen(let session, _) = $0 { return session } else { return nil } } == agent
        }
        // Leaving the session does not bring it back: it was seen.
        app.press(.id("session-\(shell)"))
        Thread.sleep(forTimeInterval: 1)
        app.waitGone(.containing("needs permission"))
    }

    /// NOTE-11 (#60): a session chosen in a window that is behind another
    /// app's is not before the user's eyes: its banner stays until the app
    /// is used again.
    func testABannerStaysWhileTheAppIsBehindAnother() throws {
        let phone = try device()
        let (_, agent) = try aBannerForAnAgentBehindAShell(phone)
        // Finder in front, as when the user works in another app.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
        let deadline = Date().addingTimeInterval(5)
        while appIsInFront && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        try XCTSkipIf(appIsInFront, "the app could not be put behind another: macOS did not let the tests bring Finder to the front")

        app.press(.id("session-\(agent)"))
        Thread.sleep(forTimeInterval: 1)
        app.wait(for: .containing("needs permission"))
        XCTAssertNil(phone.last { if case .noticeSeen(let session, _) = $0 { return session } else { return nil } }, "not seen yet")

        bringAppToFront()
        app.waitGone(.containing("needs permission"))
    }

    func testStartingSessionsAndFindingThemAgainAfterReopeningTheApp() throws {
        let phone = try device()
        // SES-2: a shell from the launch buttons.
        app.press(.button("Shell"))
        wait("the shell to start") { phone.sessions.count == 1 }
        let shell = phone.sessions[0]
        XCTAssertEqual(shell.cwd, project.path, "the session did not start in the selected folder")
        // SES-3: an agent, named after it.
        app.press(.button("Claude Code"))
        wait("the agent to start") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.id != shell.id })
        XCTAssertEqual(agent.title, "Claude Code")
        // TAB-1: each is a tab.
        app.wait(for: .containing("Claude Code"))

        // SES-6: what the program writes reaches another device too.
        phone.send(.attach(session: agent.id, size: .default))
        wait("the agent's first words on the other device") { phone.text(agent.id).contains("stand-in claude started") }

        // SES-12: what is typed and not sent is still there after the app
        // was closed. Typed from the other device: the app only has to show it.
        phone.send(.attach(session: shell.id, size: .default))
        phone.connection.sendInput(Data("echo not-sent-yet".utf8), to: shell.id)
        wait("the typing echoed") { phone.text(shell.id).contains("not-sent-yet") }

        // SES-4: the sessions outlive the app.
        try relaunchApp()
        wait("both sessions after reopening") { self.app.all(.containing("Claude Code")).count >= 1 && phone.sessions.count == 2 }
        XCTAssertEqual(phone.sessions.map(\.id).sorted(), [shell.id, agent.id].sorted())
        // And what was typed is what a device that opens the session now is shown.
        let later = try device("later")
        later.send(.attach(session: shell.id, size: .default))
        wait("what was typed, replayed") { later.text(shell.id).contains("not-sent-yet") }
    }

    func testASessionAnotherDeviceIsUsingIsShownAtThatDevicesSize() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        // Only shown on the phone, the session keeps the Mac's size.
        phone.send(.attach(session: id, size: TermSize(cols: 40, rows: 20)))
        wait("the Mac's size, told to the phone") { (phone.size(of: id)?.cols ?? 0) > 40 }
        XCTAssertFalse(app.exists(.button("Use This Size")))
        // SIZE-4: used on the phone, it has the phone's size, and the Mac says so and offers to take it back.
        phone.send(.takeControl(session: id, size: TermSize(cols: 40, rows: 20)))
        wait("the phone's size") { phone.size(of: id) == TermSize(cols: 40, rows: 20) }
        app.wait(for: .button("Use This Size"), timeout: 15)
        // SIZE-10 (#120): named, as the device named itself.
        app.wait(for: .containing("In use on iPhone · 40×20"))
        app.press(.button("Use This Size"))
        app.waitGone(.button("Use This Size"), timeout: 15)
        wait("the Mac's size again") { (phone.size(of: id)?.cols ?? 0) > 40 }
    }

    /// SIZE-9: a session another device uses at a grid larger than its
    /// pane here, an iPad's, is shown whole, scaled down to fit: its last
    /// rows, where the prompt is, are not cut off under the pane.
    func testALargerDevicesSessionIsShownWhole() throws {
        let pad = try device("iPad")
        app.press(.button("Shell"))
        wait("the shell") { pad.sessions.count == 1 }
        let id = pad.sessions[0].id
        let large = TermSize(cols: 300, rows: 100)
        pad.send(.attach(session: id, size: large))
        pad.send(.takeControl(session: id, size: large))
        wait("the iPad's size") { pad.size(of: id) == large }
        app.wait(for: .button("Use This Size"), timeout: 15)
        app.wait(for: .containing("In use on iPad · 300×100"))
        // Something on the last row, to look at in the picture.
        pad.connection.sendInput(Data("clear; tput cup 99 0; printf LAST-ROW\n".utf8), to: id)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("larger-device")
        XCTAssertEqual(app.first(.id("terminal-view"))?.help, "whole grid in sight")
        // Taken back, it fills the pane again.
        app.press(.button("Use This Size"))
        app.waitGone(.button("Use This Size"), timeout: 15)
        app.wait("the terminal whole at the window's size") { self.app.first(.id("terminal-view"))?.help == "whole grid in sight" }
    }

    /// SIZE-10 (#167): a session a phone uses at a grid narrower than the
    /// pane but taller, stays in the middle, as SIZE-5 has it, and none of
    /// it is cut off: its first row and its last are in sight.
    func testANarrowButTallDevicesSessionIsShownWhole() throws {
        let phone = try device("iPhone")
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        let tall = TermSize(cols: 45, rows: 120)
        phone.send(.attach(session: id, size: tall))
        phone.send(.takeControl(session: id, size: tall))
        wait("the phone's size") { phone.size(of: id) == tall }
        app.wait(for: .button("Use This Size"), timeout: 15)
        phone.connection.sendInput(Data("clear; printf FIRST-ROW; tput cup 119 0; printf LAST-ROW\n".utf8), to: id)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("narrow-tall-device")
        XCTAssertEqual(app.first(.id("terminal-view"))?.help, "whole grid in sight")
    }

    /// SIZE-11 (#167): a phone that uses a session at a grid that fits, then
    /// at one taller than the pane, as when it is turned or its keyboard
    /// goes: the new grid is laid out again, whole.
    func testADevicesGridThatGrowsIsLaidOutAgain() throws {
        let phone = try device("iPhone")
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let id = phone.sessions[0].id
        let small = TermSize(cols: 45, rows: 20)
        phone.send(.attach(session: id, size: small))
        phone.send(.takeControl(session: id, size: small))
        wait("the phone's size") { phone.size(of: id) == small }
        app.wait(for: .button("Use This Size"), timeout: 15)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let tall = TermSize(cols: 45, rows: 120)
        phone.send(.resize(session: id, size: tall))
        wait("the phone's new size") { phone.size(of: id) == tall }
        phone.connection.sendInput(Data("clear; printf FIRST-ROW; tput cup 119 0; printf LAST-ROW\n".utf8), to: id)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot("grown-device")
        XCTAssertEqual(app.first(.id("terminal-view"))?.help, "whole grid in sight")
    }

    func testTheSSHMenuListsTheHostsOfTheConfiguration() throws {
        // LAUNCH-2: the hosts, without the patterns.
        app.press(.button("SSH"))
        app.wait(for: .button("build-server"), menus: true)
        XCTAssertFalse(app.nodes(menus: true).contains { $0.title.contains("internal") }, "a pattern is offered as a host")
    }
}
