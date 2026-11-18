import AgentTermProtocol
import XCTest

/// The pane of the Mac's window (#69, #127): PANE-9, PANE-11 and PANE-12
/// in docs/TESTING.md.
///
/// What a pane does is asked of the pane itself, as VoiceOver would, more
/// than of the Tab menu: the menu's items are made again whenever the tabs
/// change, and an item found a moment before may be gone when it is pressed.
final class PaneUITests: MacUITestCase {
    /// Starts a shell from the File menu, in the pane the keyboard is in,
    /// and returns it once the host lists it and the row of the Shells tab
    /// shows it (#127).
    @discardableResult
    private func newShell(_ phone: Device, count: Int) throws -> SessionInfo {
        app.menu(["File", "New Shell"])
        wait("shell \(count) to start") { phone.sessions.count == count }
        let shell = try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
        app.wait(for: .id("item-\(shell.id)"))
        return shell
    }

    /// The sessions a pane's row shows, the items of its tab in front.
    private func items(inPane pane: String) -> Set<SessionID> {
        let nodes = app.nodes()
        guard let index = nodes.firstIndex(where: { $0.identifier == "pane-\(pane)" }) else { return [] }
        let depth = nodes[index].depth
        var found: Set<SessionID> = []
        for node in nodes[(index + 1)...] {
            if node.depth <= depth { break }
            if node.identifier.hasPrefix("item-"), let id = SessionID(node.identifier.dropFirst(5)) { found.insert(id) }
        }
        return found
    }

    /// TABS-6 (#152): the list on the left marks the row the user picked:
    /// a folder itself, not the shell its panes show in front; the Shells
    /// row itself, with a menu that ends its shells; a shell, alone.
    func testTheListMarksTheRowPicked() throws {
        let phone = try device()
        let shell = try newShell(phone, count: 1)
        let folder = "folder-\(project.path)"
        app.wait("the shell picked") { self.app.isSelected(.id("session-\(shell.id)")) }
        app.press(.id(folder))
        app.wait("the folder picked") { self.app.isSelected(.id(folder)) }
        XCTAssertFalse(app.isSelected(.id("session-\(shell.id)")), "the shell is marked, not the folder")
        XCTAssertTrue(app.exists(.id("terminal-\(shell.id)")), "the folder's panes are not shown as they were left")
        app.press(.id("sidebar-shells"))
        app.wait("the Shells row picked") { self.app.isSelected(.id("sidebar-shells")) }
        XCTAssertFalse(app.isSelected(.id(folder)))
        XCTAssertFalse(app.isSelected(.id("session-\(shell.id)")), "the shell is marked, not the Shells row")
        XCTAssertTrue(app.offers(CloseWords.groupAction(.shells), on: .id("sidebar-shells")), "the Shells row has no way to end its shells")
        app.press(.id("session-\(shell.id)"))
        app.wait("the shell picked again") { self.app.isSelected(.id("session-\(shell.id)")) }
        XCTAssertFalse(app.isSelected(.id("sidebar-shells")))
        XCTAssertFalse(app.isSelected(.id(folder)))
    }

    /// TABS-3 (#145): the Shells tab's × ends every shell it holds, asked
    /// first; cancelled, they all run on.
    func testClosingTheShellsTabEndsAllItsShells() throws {
        let phone = try device()
        try newShell(phone, count: 1)
        try newShell(phone, count: 2)
        app.perform(CloseWords.groupAction(.shells), on: .id("strip-shells"))
        app.wait(for: .text(CloseWords.groupQuestion(.shells, count: 2)))
        app.press(.button("Cancel"))
        XCTAssertEqual(phone.sessions.count, 2, "a shell ended though the question was cancelled")
        app.perform(CloseWords.groupAction(.shells), on: .id("strip-shells"))
        app.press(.button(CloseWords.groupButton(.shells, count: 2)))
        wait("both shells ended") { phone.sessions.isEmpty }
        app.wait("the Shells tab gone") { !self.app.exists(.id("strip-shells")) }
    }

    /// PANE-9: the user does not split the window: no button in the strip,
    /// no action of the pane or of a tab, no item of the Tab menu does; the
    /// tabs are in its one pane, the user's shells in its Shells tab.
    func testThePaneIsNotSplitByHand() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        XCTAssertEqual(items(inPane: "pane-1"), [first.id, second.id])
        XCTAssertEqual(app.first(.id("strip-shells"))?.label, "Shells, 2 shells")
        XCTAssertFalse(app.exists(.button("New Tab")), "the strip has a button that starts a tab")
        XCTAssertFalse(app.exists(.button("Pane")), "the strip has a button that splits")
        for action in ["Split Right", "Split Down", "Close Pane", "Show This Pane Alone"] {
            XCTAssertFalse(app.offers(action, on: .id("pane-pane-1")), action)
        }
        for action in ["Move to New Pane Right", "Move to New Pane Below"] {
            XCTAssertFalse(app.offers(action, on: .id("strip-shells")), action)
        }
        let menu = app.nodes(menus: true).map(\.title)
        for item in ["Split Right", "Split Down", "Go to Pane", "Close Pane", "Move Tab to New Pane Right"] {
            XCTAssertFalse(menu.contains(item), "the menu bar has \(item)")
        }
        shot("one-pane")
    }

    /// PANE-11: each project has panes of its own; picking its folder shows
    /// them, and none of another project's tabs.
    func testEachProjectHasItsOwnPanes() throws {
        let phone = try device()
        let other = root.appendingPathComponent("other")
        try makeRepository(other, remote: nil)
        phone.send(.addFolder(path: other.path))
        app.wait(for: .text("other, folder"))
        let mine = try newShell(phone, count: 1)

        app.press(.text("other, folder"))
        app.waitGone(.id("item-\(mine.id)"))
        let theirs = try newShell(phone, count: 2)
        XCTAssertEqual(theirs.cwd, other.path)
        XCTAssertFalse(app.exists(.id("item-\(mine.id)")), "another project's shell is shown")

        app.press(.text("project, folder"))
        app.wait(for: .id("item-\(mine.id)"))
        XCTAssertFalse(app.exists(.id("item-\(theirs.id)")))
        // Picking a session of the other project in the list shows its panes.
        app.press(.id("session-\(theirs.id)"))
        app.wait(for: .id("item-\(theirs.id)"))
        XCTAssertFalse(app.exists(.id("item-\(mine.id)")))
    }

    /// PANE-12 (#69, #127): an agent's own shells are in its tab: shown
    /// under it, in its area, and in its row after it; not tabs of their
    /// own, nor in the user's Shells tab; in the list right under it. The
    /// button at the end of its row hides its shells, which run on and stay
    /// in the row, and shows them again; so does picking one in the row.
    func testAnAgentsShellsShowUnderIt() throws {
        let phone = try device()
        // A stand-in Claude Code that opens a shell through AgentTerm's MCP
        // server, as the real one does, then waits.
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"shell_open","arguments":{"command":"cat","title":"server"}}}"#
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        try """
        #!/bin/sh
        echo "stand-in claude started"
        ( printf '%s\\n' '\(initialize)' '\(call)'; sleep 3 ) | '\(hostExecutable.path)' mcp > /dev/null 2>&1 &
        exec cat
        """.write(to: root.appendingPathComponent("agents/claude"), atomically: true, encoding: .utf8)
        app.press(.button("Claude Code"))
        wait("the agent and its shell") { phone.sessions.count == 2 }
        let agent = try XCTUnwrap(phone.sessions.first { $0.agent == "claude" })
        let shell = try XCTUnwrap(phone.sessions.first { $0.openedBy == agent.id })
        app.wait(for: .id("agent-shells"))
        app.wait(for: .id("item-\(shell.id)"))
        // The shell is in the agent's tab, not a tab of the strip.
        XCTAssertTrue(app.exists(.id("tab-\(agent.id)")))
        XCTAssertFalse(app.exists(.id("tab-\(shell.id)")), "the agent's shell is a tab of its own")
        XCTAssertFalse(app.exists(.id("strip-shells")), "the agent's shell is in the user's Shells tab")
        // Both on show: the agent, and its shell under it.
        XCTAssertTrue(app.exists(.id("terminal-\(agent.id)")), "the agent is not shown with its shell")
        XCTAssertTrue(app.exists(.id("terminal-\(shell.id)")), "the agent's shell is not shown under it")
        // In the list, right under its agent (set in: see the picture).
        let rows = app.nodes().map(\.identifier).filter { $0.hasPrefix("session-") || $0.hasPrefix("browser-row-") }
        XCTAssertEqual(rows, ["session-\(agent.id)", "session-\(shell.id)"])
        shot("agent-area")

        // Hidden from the row: the shell runs on, and is still in the row.
        XCTAssertEqual(app.first(.id("agent-part-shells"))?.value, "shown")
        app.press(.id("agent-part-shells"))
        app.waitGone(.id("agent-shells"))
        XCTAssertEqual(app.first(.id("agent-part-shells"))?.value, "hidden")
        XCTAssertTrue(app.exists(.id("item-\(shell.id)")), "a hidden shell left the agent's row")
        XCTAssertTrue(app.exists(.id("terminal-\(agent.id)")))
        XCTAssertTrue(phone.sessions.contains { $0.id == shell.id }, "hiding the shells ended one")
        app.press(.id("agent-part-shells"))
        app.wait(for: .id("agent-shells"))
        // Hidden again, the shell picked in the row is shown.
        app.press(.id("agent-part-shells"))
        app.waitGone(.id("agent-shells"))
        app.press(.id("item-\(shell.id)"))
        app.wait(for: .id("agent-shells"))
        app.waitForKeyboard(in: "terminal-\(shell.id)", "the shell picked in the row")
        // There is no switch that makes it a tab of its own.
        app.press(.id("place-settings"))
        XCTAssertFalse(app.exists(.id("arrange-agent-panes")))
    }
}
