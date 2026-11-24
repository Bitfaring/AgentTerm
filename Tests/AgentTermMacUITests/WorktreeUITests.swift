import AgentTermProtocol
import XCTest

/// A session in a worktree of its own (#23), and the side panel following
/// the worktree shown (#33).
final class WorktreeUITests: MacUITestCase {
    /// What the button that opens the worktrees says: the one on show (#217).
    private func pickerLabel() -> String { app.first(.id("worktree-picker"))?.label ?? "" }

    /// WT-21 (#216): a submodule opened as a folder has worktrees of its
    /// own, the first its own folder: the button names its branch and
    /// counts what is changed in it. Before the fix the first was the
    /// parent's `.git/modules` folder, where nothing is ever changed.
    func testASubmoduleOpenedAsAFolderHasItsOwnWorktrees() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        let parent = root.appendingPathComponent("parent")
        try makeRepository(parent, remote: nil)
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", project.path, "sub", in: parent)
        git("commit", "-q", "-m", "sub", in: parent)
        let sub = parent.appendingPathComponent("sub")
        try "changed here\n".write(to: sub.appendingPathComponent("in-the-submodule.txt"), atomically: true, encoding: .utf8)

        phone.send(.addFolder(path: sub.path))
        app.wait(for: .text("sub, folder"))
        app.press(.text("sub, folder"))
        app.press(.button("Git"))
        app.wait(for: .id("worktree-picker"), timeout: 15)
        app.wait(for: .containing("in-the-submodule.txt"), timeout: 15)
        app.wait("the worktrees' button to count the submodule's change", timeout: 15) { self.pickerLabel().contains("1 file changed") }
        shot("submodule")
    }

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

    /// SES-32 (#299): after a launch the host refused, the next session
    /// someone else starts (here a device) does not come in front, nor
    /// take the keyboard: the session that was in front stays.
    func testASessionStartedAfterARefusedLaunchDoesNotComeInFront() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        phone.send(.create(CreateRequest(command: "exec sleep 600", cwd: project.path, title: "in front")))
        wait("the session", timeout: 20) { phone.sessions.contains { $0.title == "in front" } }
        let inFront = try XCTUnwrap(phone.sessions.first { $0.title == "in front" })
        app.press(.id("session-\(inFront.id)"), timeout: 15)
        app.wait("it in front") { self.app.selectedRows() == ["session-\(inFront.id)"] }

        // A worktree on the branch the folder has checked out: git refuses it.
        app.press(.button("Git"))
        app.press(.id("worktree-picker"), timeout: 15)
        app.press(.id("worktree-add"))
        app.write("main", into: .id("worktree-branch"))
        app.press(.id("worktree-create"))
        app.wait(for: .containing("The worktree could not be made"), timeout: 20)

        phone.send(.create(CreateRequest(command: "exec sleep 600", cwd: project.path, title: "from the phone")))
        wait("the phone's session", timeout: 20) { phone.sessions.contains { $0.title == "from the phone" } }
        let later = try XCTUnwrap(phone.sessions.first { $0.title == "from the phone" })
        app.wait(for: .id("session-\(later.id)"), timeout: 15)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(app.selectedRows(), ["session-\(inFront.id)"], "the session the device started came in front")
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
            self.pickerLabel().contains("Worktree claude-1, A worktree, on agentterm/claude-1, 1 file changed, a session runs in it")
        }
        // Its row in the popup says the same.
        app.press(.id("worktree-picker"))
        app.wait(for: .id("worktree-chip-agentterm/claude-1"), timeout: 15)
        XCTAssertEqual(
            app.first(.id("worktree-chip-agentterm/claude-1"))?.label, "claude-1, A worktree, on agentterm/claude-1, 1 file changed, a session runs in it")
        shot("chips")

        // The first row goes back to the folder; the other to the worktree.
        app.press(.id("worktree-chip-main"))
        app.wait(for: .containing("notes.txt"), timeout: 15)
        XCTAssertFalse(app.exists(.containing("worktree-only.txt")))
        app.press(.id("worktree-picker"))
        app.press(.id("worktree-chip-agentterm/claude-1"))
        app.wait(for: .containing("worktree-only.txt"), timeout: 15)
    }

    /// WT-25 (#244): a worktree being made is shown under its folder, with
    /// what is being done, from the moment it is asked for until its
    /// session takes its place.
    func testAWorktreeBeingMadeIsShownWithWhatIsBeingDone() throws {
        let phone = try device()
        app.wait(for: .text("project, folder"), timeout: 15)
        // A checkout that takes a while: git runs the project's hook in the
        // new worktree once it is checked out.
        let hook = project.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\nsleep 4\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        phone.send(.createInWorktree(request: CreateRequest(command: "exec sleep 600", cwd: project.path, title: "slow"), branch: "feature/slow", from: nil))
        let row = try XCTUnwrap(app.wait(for: .containing("Making the worktree…"), timeout: 10))
        XCTAssertEqual(row.label, "feature/slow, Making the worktree…", "named by the branch asked for")
        XCTAssertTrue(row.identifier.hasPrefix("worktree-in-progress-"), row.identifier)
        shot("worktree-in-progress")

        wait("the session in its worktree", timeout: 30) { phone.sessions.first?.branch == "feature/slow" }
        app.waitGone(.containing("Making the worktree…"), timeout: 10)
        app.wait(for: .containing("feature/slow"), timeout: 10)
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
        // A right click on the row has what "⋯" has, as a branch's row does
        // (the owner's decision, 2026-11-22).
        XCTAssertTrue(app.offers("AXShowMenu", on: .id("worktree-chip-feature/try")), "a right click on the row has no menu")
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
