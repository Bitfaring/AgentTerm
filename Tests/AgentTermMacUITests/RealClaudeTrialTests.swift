import AgentTermProtocol
import AppKit
import XCTest

/// The trials of #320 and #321 with the real Claude Code, run by hand only
/// (`AGENTTERM_REAL_AGENTS=1 scripts/test-mac.sh RealClaudeTrialTests`): it
/// is the user's own, signed in, at the version installed, with Haiku. It
/// runs in a folder of the test's own, whose trust question the user
/// answers in the window (rule 1 of CLAUDE.md); the host has a state folder
/// and a port of its own and the user's home, and gives the agent its hooks
/// for the session only (`--settings`), changing none of its configuration.
final class RealClaudeTrialTests: MacUITestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_REAL_AGENTS"] != nil, "spends the user's account: run by hand")
        try super.setUpWithError()
    }

    override var hostHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    override func beforeTheHostStarts() throws {
        let folder = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let found = try XCTUnwrap(RealAgentsTests.which("claude"), "claude is not installed")
        // The hooks, as Settings > Hooks & MCP would install them, but for
        // this session only (`--plugin-dir`): the user's Claude Code has the
        // released build's plugin, whose hooks speak to the released host.
        let plugin = root.appendingPathComponent("claude-plugin")
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "agentterm-trial", "version": "0.0.0", "description": "The trial's hooks"])
            .write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        var hooks: [String: Any] = [:]
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Notification", "Stop"] {
            hooks[event] = [["hooks": [["type": "command", "command": "'\(hostExecutable.path)' hook claude \(event)"]]]]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: plugin.appendingPathComponent("hooks/hooks.json"))
        let link = folder.appendingPathComponent("claude")
        try? FileManager.default.removeItem(at: link)
        try "#!/bin/sh\nexec '\(found)' --model haiku --effort low --plugin-dir '\(plugin.path)' \"$@\"\n".write(to: link, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.path)
    }

    /// #320: what Claude Code shows after a question's choices, and what
    /// the host takes of it. #321: the question answered by a key typed in
    /// the session's terminal moves the agent on, and its notice is handled
    /// and read on the devices. What was seen is printed as `MEASURE`.
    func testClaudeAsksAndIsAnsweredInItsTerminal() throws {
        // One folder for every run, so that its trust is answered once.
        let trial = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-claude-trial")
        try FileManager.default.createDirectory(at: trial, withIntermediateDirectories: true)
        print("MEASURE claude version: \(RealAgentsTests.said("claude --version").joined(separator: " "))")
        let phone = try device()
        phone.send(.create(CreateRequest(command: root.appendingPathComponent("agents/claude").path, cwd: trial.path, title: "real-claude")))
        wait("the session", timeout: 20) { phone.sessions.contains { $0.title == "real-claude" } }
        let id = try XCTUnwrap(phone.sessions.first { $0.title == "real-claude" }?.id)
        // Its screen, to read what Claude Code shows.
        phone.send(.attach(session: id, size: .default))
        bringAppToFront()
        app.press(.id("session-\(id)"), timeout: 15)

        // The user answers the folder's trust question in the window.
        print("MEASURE waiting for the user to answer Claude Code's trust question in the test's window")
        wait("Claude Code ready for a prompt (the trust question answered)", timeout: 300) {
            // Its screen's words, without the escapes between them.
            let words = phone.text(id).replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            return words.contains("shift+tab") || words.contains("shortcuts")
        }
        Thread.sleep(forTimeInterval: 2)

        phone.connection.sendInput(
            Data("Use the AskUserQuestion tool once to ask me which color I prefer, with exactly two options: Red and Blue. Do nothing else.".utf8), to: id)
        Thread.sleep(forTimeInterval: 1)
        phone.connection.sendInput(Data("\r".utf8), to: id)

        var question: AgentQuestion?
        var seen: [String] = []
        let asking = Date().addingTimeInterval(120)
        while question == nil, Date() < asking {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let info = phone.sessions.first { $0.id == id }
            let now = "state=\(info?.state.map { "\($0)" } ?? "none") link=\(info?.link.map { "\($0)" } ?? "none")"
            if seen.last != now { seen.append(now) }
            if case .waitingForAnswer(let asked)? = info?.state { question = asked }
        }
        print("MEASURE what the host was told of the session, in order:\n" + seen.joined(separator: "\n"))
        guard question != nil else {
            shot("claude-not-asking")
            return XCTFail("the host never took the session for asking")
        }
        Thread.sleep(forTimeInterval: 2)
        print("MEASURE #320 question: \(question?.text ?? "none"); choices the host took: \(question?.choices ?? [])")
        let screen = String(phone.text(id).suffix(1500))
        print("MEASURE #320 the end of the terminal while it asks:\n\(screen)")
        shot("claude-asks")
        let notice = phone.messages.lazy.compactMap { message -> Notice? in
            if case .notice(let notice) = message, notice.session == id, case .agent(.waitingForAnswer) = notice.kind { return notice }
            return nil
        }.first
        print("MEASURE #321 notice for the question: \(notice.map { "id \($0.id)" } ?? "none")")

        // Answered in the terminal: the first choice, with Return.
        phone.connection.sendInput(Data("\r".utf8), to: id)
        wait("the agent to move on", timeout: 120) {
            if case .waitingForAnswer? = phone.sessions.first(where: { $0.id == id })?.state { return false }
            return true
        }
        Thread.sleep(forTimeInterval: 3)
        print("MEASURE #321 state after the answer: \(phone.sessions.first { $0.id == id }?.state.map { "\($0)" } ?? "none")")
        if let notice {
            let handled = phone.messages.compactMap { message -> Notice.Handled? in
                if case .noticeHandled(notice.id, let handled) = message { return handled }
                return nil
            }.first
            let read = phone.messages.contains { if case .noticesRead(let ids) = $0 { return ids.contains(notice.id) } else { return false } }
            print("MEASURE #321 notice handled: \(handled.map { $0.how.rawValue } ?? "no"); told read: \(read)")
            XCTAssertNotNil(handled, "the notice of the question answered in the terminal was not handled")
        }
        shot("claude-answered")
        phone.send(.kill(session: id))
    }
}
