import AgentTermProtocol
import XCTest

/// A session in a worktree of its own (#23), and the side panel following
/// the worktree shown (#33).
final class WorktreeUITests: MacUITestCase {
    /// What the button that opens the worktrees says: the one on show (#217).
    private func pickerLabel() -> String { app.first(.id("worktree-picker"))?.label ?? "" }

    /// WT-7: the session is listed under its project with its branch;
    /// picking it shows its worktree's changes, not the project's.
    func testASessionInAWorktreeIsUnderItsProjectAndThePanelFollowsIt() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        phone.send(.createInWorktree(request: CreateRequest(command: "exec sleep 600", cwd: project.path, title: "in a worktree"), branch: "feature/try", from: nil))
        wait("the session", timeout: 20) { phone.sessions.first?.branch == "feature/try" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path), session.cwd)
        // A change of the worktree's own, that the project does not have.
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)

        app.wait(for: .containing("feature/try"), timeout: 15)
        app.press(.id("session-\(session.id)"))
        app.wait(for: .id("worktree-picker"), timeout: 15)
        app.wait("the worktrees' button to name the session's", timeout: 15) { self.pickerLabel().contains("feature/try") }
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("notes.txt")), "the project's own changes are not the worktree's")
        shot("worktree")
    }

    /// WT-17 (#43, #217): the worktrees' button is there for a folder with
    /// no worktree but its own; New Worktree, in its popup, suggests a
    /// branch named after the agent and starts it in a new worktree; the
    /// rows say what is changed in each, and a click makes the side panel
    /// about that one, the first about the folder again.
    func testAWorktreeIsMadeFromTheBarAndItsChipsSwitchThePanel() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .id("worktree-picker"), timeout: 15)
        XCTAssertTrue(pickerLabel().contains("main"), pickerLabel())
        app.wait(for: .containing("notes.txt"))

        app.press(.id("worktree-picker"))
        app.wait(for: .id("worktree-chip-main"))
        app.press(.id("worktree-add"))
        app.wait(for: .id("worktree-branch"))
        app.wait("the suggested name") { self.app.value(of: .id("worktree-branch")) == "agentterm/claude-1" }
        shot("new-worktree")
        app.press(.id("worktree-create"))
        wait("the session in its worktree", timeout: 30) { phone.sessions.first?.branch == "agentterm/claude-1" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertEqual(session.agent, "claude")
        XCTAssertEqual(session.cwd, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)

        // It is on show: the worktree has none of the folder's changes.
        app.wait("the worktrees' button to name the new one", timeout: 15) { self.pickerLabel().contains("agentterm/claude-1") }
        app.waitGone(.containing("notes.txt"), timeout: 15)
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        app.wait("the button to say what is changed in it", timeout: 15) {
            self.pickerLabel().contains("agentterm/claude-1, A worktree, 1 file changed, a session runs in it")
        }
        // Its row in the popup says the same.
        app.press(.id("worktree-picker"))
        app.wait(for: .id("worktree-chip-agentterm/claude-1"), timeout: 15)
        XCTAssertEqual(
            app.first(.id("worktree-chip-agentterm/claude-1"))?.label, "agentterm/claude-1, A worktree, 1 file changed, a session runs in it")
        shot("chips")

        // The first row goes back to the folder; the other to the worktree.
        app.press(.id("worktree-chip-main"))
        app.wait(for: .containing("notes.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("worktree-only.txt")))
        app.press(.id("worktree-picker"))
        app.press(.id("worktree-chip-agentterm/claude-1"))
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
    }

    /// WT-23 (#217): the worktrees are picked from a popup like the
    /// branch's. Outside it there is only the button that opens it, naming
    /// the worktree on show; inside, a search that narrows the rows down,
    /// a row for each, and New Worktree.
    func testWorktreesArePickedFromAPopupWithSearch() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        phone.send(.createInWorktree(request: CreateRequest(command: "exec sleep 600", cwd: project.path, title: "in a worktree"), branch: "feature/try", from: nil))
        wait("the session", timeout: 20) { phone.sessions.first?.branch == "feature/try" }
        let session = try XCTUnwrap(phone.sessions.first)
        try "only here\n".write(toFile: session.cwd + "/worktree-only.txt", atomically: true, encoding: .utf8)

        // The session's worktree is the one on show, and the button names it.
        app.press(.id("session-\(session.id)"))
        app.wait(for: .id("worktree-picker"), timeout: 15)
        app.wait("the worktrees' button to name the one on show", timeout: 15) { self.pickerLabel().contains("feature/try") }
        app.wait("the button to say what is changed in it", timeout: 15) { self.pickerLabel().contains("1 file changed") }
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
        // Outside the popup there is the button only: no rows, no "+", no "⋯".
        XCTAssertFalse(app.exists(.id("worktree-add")), "New Worktree is outside the popup")
        XCTAssertFalse(app.exists(.id("worktree-chip-main")), "a worktree is listed outside the popup")
        XCTAssertFalse(app.exists(.id("worktree-more-feature/try")), "a worktree's actions are outside the popup")

        // Opened, it lists both, the one on show marked, with "⋯" on the
        // one that is not the folder's own only.
        app.press(.id("worktree-picker"))
        app.wait(for: .id("worktree-search"))
        app.wait(for: .id("worktree-chip-main"))
        app.wait(for: .id("worktree-chip-feature/try"))
        XCTAssertTrue(app.isSelected(.id("worktree-chip-feature/try")), "the worktree on show is not marked")
        XCTAssertFalse(app.isSelected(.id("worktree-chip-main")))
        XCTAssertTrue(app.exists(.id("worktree-more-feature/try")))
        XCTAssertFalse(app.exists(.id("worktree-more-main")), "the folder's own has nothing to merge or throw away")
        XCTAssertTrue(app.exists(.id("worktree-add")))
        shot("worktrees-popup")

        // The search narrows them down, whatever the case.
        app.write("MAI", into: .id("worktree-search"))
        app.waitGone(.id("worktree-chip-feature/try"))
        XCTAssertTrue(app.exists(.id("worktree-chip-main")))
        shot("worktrees-popup-search")

        // Picking the one left makes the panel about it, and closes the popup.
        app.press(.id("worktree-chip-main"))
        app.waitGone(.id("worktree-search"))
        app.wait(for: .containing("notes.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("worktree-only.txt")))
        app.wait("the worktrees' button to name the folder's own", timeout: 15) { self.pickerLabel().contains("main") && !self.pickerLabel().contains("feature/try") }
        XCTAssertFalse(app.exists(.id("worktree-add")), "New Worktree is outside the popup")

        // New Worktree, inside, opens the sheet the bar's "+" opened.
        app.press(.id("worktree-picker"))
        app.press(.id("worktree-add"))
        app.wait(for: .id("worktree-branch"))
        app.waitGone(.id("worktree-search"))
        shot("worktrees-popup-new")
        app.press(.button("Cancel"))
        app.waitGone(.id("worktree-branch"))
    }

    /// WT-22 (#215): the worktrees are the host's, and are forgotten with
    /// the connection. When the host is lost and comes back, their button
    /// is there again, with nothing changed in the folder to ask for it.
    func testTheWorktreesAreShownAgainAfterTheHostCameBack() throws {
        app.wait(for: .text("project, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .id("worktree-picker"), timeout: 15)

        killHost(on: port)
        app.wait(for: .containing("and was started again"), timeout: 20)
        wait("a host on the port again") { !self.listeners(on: self.port).isEmpty }
        app.wait(for: .text("project, folder"), timeout: 15)

        app.wait(for: .id("worktree-picker"), timeout: 15)
    }

    /// HAND-8 (#150): New Worktree can begin by continuing a conversation of the
    /// folder: the worktree is made, the conversation handed off into it,
    /// and the agent started there, on its branch.
    func testANewWorktreeContinuesAConversation() throws {
        let history = home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"\#(project.path)","message":{"role":"user","content":"finish the parser"}}"#.appending("\n").write(
            to: history.appendingPathComponent("c-wt.jsonl"), atomically: true, encoding: .utf8)
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        app.press(.button("Git"))
        app.wait(for: .id("worktree-picker"), timeout: 15)

        app.press(.id("worktree-picker"))
        app.press(.id("worktree-add"))
        app.wait(for: .id("worktree-begin"))
        app.press(.id("worktree-begin"))
        app.press(.containing(WorktreeWords.continueConversation), menus: true)
        app.wait(for: .id("worktree-conversation"))
        app.wait(for: .text(WorktreeWords.continueAdvice))
        shot("new-worktree-continue")
        app.press(.id("worktree-create"))
        wait("the agent in its worktree", timeout: 30) { phone.sessions.first?.branch == "agentterm/claude-1" }
        let session = try XCTUnwrap(phone.sessions.first)
        XCTAssertEqual(session.cwd, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)
        let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: session.cwd + "/.agentterm/handoffs")) ?? []
        XCTAssertEqual(handoffs.count, 1, "the handoff file was not written in the new worktree")
        let text = try String(contentsOfFile: session.cwd + "/.agentterm/handoffs/" + (handoffs.first ?? ""), encoding: .utf8)
        XCTAssertTrue(text.contains("finish the parser"), "the conversation is not in the handoff")
        XCTAssertTrue(text.contains("a git worktree of the folder"), "the agent is not told it is in a worktree")
    }
}
