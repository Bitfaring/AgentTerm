import AgentTermProtocol
import XCTest

/// The pane of the Mac's window (#69): PANE-9, PANE-11 and PANE-12 in
/// docs/TESTING.md.
///
/// What a pane does is asked of the pane itself, as VoiceOver would, more
/// than of the Tab menu: the menu's items are made again whenever the tabs
/// change, and an item found a moment before may be gone when it is pressed.
final class PaneUITests: MacUITestCase {
    /// Starts a shell from the File menu, in the pane the keyboard is in,
    /// and returns it once the host lists it.
    @discardableResult
    private func newShell(_ phone: Device, count: Int) throws -> SessionInfo {
        app.menu(["File", "New Shell"])
        wait("shell \(count) to start") { phone.sessions.count == count }
        let shell = try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
        app.wait(for: .id("tab-\(shell.id)"))
        return shell
    }

    /// The tabs a pane's strip shows, by session.
    private func tabs(inPane pane: String) -> Set<SessionID> {
        let nodes = app.nodes()
        guard let index = nodes.firstIndex(where: { $0.identifier == "pane-\(pane)" }) else { return [] }
        let depth = nodes[index].depth
        var found: Set<SessionID> = []
        for node in nodes[(index + 1)...] {
            if node.depth <= depth { break }
            if node.identifier.hasPrefix("tab-"), let id = SessionID(node.identifier.dropFirst(4)) { found.insert(id) }
        }
        return found
    }

    /// PANE-9: the user does not split the window: no button in the strip,
    /// no action of the pane or of a tab, no item of the Tab menu does; the
    /// tabs are in its one pane.
    func testThePaneIsNotSplitByHand() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        XCTAssertEqual(tabs(inPane: "pane-1"), [first.id, second.id])
        XCTAssertFalse(app.exists(.button("New Tab")), "the strip has a button that starts a tab")
        XCTAssertFalse(app.exists(.button("Pane")), "the strip has a button that splits")
        for action in ["Split Right", "Split Down", "Close Pane", "Show This Pane Alone"] {
            XCTAssertFalse(app.offers(action, on: .id("pane-pane-1")), action)
        }
        for action in ["Move to New Pane Right", "Move to New Pane Below"] {
            XCTAssertFalse(app.offers(action, on: .id("tab-\(second.id)")), action)
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
        app.waitGone(.id("tab-\(mine.id)"))
        let theirs = try newShell(phone, count: 2)
        XCTAssertEqual(theirs.cwd, other.path)
        XCTAssertFalse(app.exists(.id("tab-\(mine.id)")), "another project's tab is shown")

        app.press(.text("project, folder"))
        app.wait(for: .id("tab-\(mine.id)"))
        XCTAssertFalse(app.exists(.id("tab-\(theirs.id)")))
        // Picking a session of the other project in the list shows its panes.
        app.press(.id("session-\(theirs.id)"))
        app.wait(for: .id("tab-\(theirs.id)"))
        XCTAssertFalse(app.exists(.id("tab-\(mine.id)")))
    }

    /// PANE-12: an agent's own shells show under it, not as tabs; closing
    /// their pane hides it, and the shell keeps running.
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
        app.wait(for: .text("server"))
        // The shell is in the agent's area, not a tab of the strip.
        XCTAssertTrue(app.exists(.id("tab-\(agent.id)")))
        XCTAssertFalse(app.exists(.id("tab-\(shell.id)")), "the agent's shell is a tab of its own")
        // In the list, right under its agent (set in: see the picture).
        let rows = app.nodes().map(\.identifier).filter { $0.hasPrefix("session-") || $0.hasPrefix("browser-row-") }
        XCTAssertEqual(rows, ["session-\(agent.id)", "session-\(shell.id)"])
        shot("agent-area")

        app.press(.button("Hide Shells"))
        app.waitGone(.id("agent-shells"))
        app.wait(for: .button("Show Shells (1)"))
        XCTAssertTrue(phone.sessions.contains { $0.id == shell.id }, "hiding the shells ended one")
        app.press(.button("Show Shells (1)"))
        app.wait(for: .id("agent-shells"))
        // There is no switch that makes it a tab of its own.
        app.press(.id("place-settings"))
        XCTAssertFalse(app.exists(.id("arrange-agent-panes")))
    }
}
