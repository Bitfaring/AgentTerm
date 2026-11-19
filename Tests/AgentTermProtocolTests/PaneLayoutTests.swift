import XCTest

@testable import AgentTermProtocol

/// The panes of the Mac's window (#69): PANE-1 to PANE-8 in docs/TESTING.md.
final class PaneLayoutTests: XCTestCase {
    /// One pane with three tabs, "b" in front.
    private func three() -> PaneLayout {
        var layout = PaneLayout()
        layout.sync(with: ["a", "b", "c"])
        layout.show("b")
        return layout
    }

    func testNewTabsGoToThePaneTheKeyboardIsIn() {
        var layout = three()
        let right = layout.split(layout.focused, .sideBySide)!
        layout.sync(with: ["a", "b", "c", "d"])
        XCTAssertEqual(layout.pane(right)?.tabs, ["d"])
        XCTAssertEqual(layout.pane(right)?.front, "d")
        XCTAssertEqual(layout.panes.first?.tabs, ["a", "b", "c"])
    }

    /// BROWSER-47 (#170): the one Browser comes into a new folder's strip
    /// behind: nothing is in front until the folder has a tab of its own,
    /// which then is.
    func testTheBrowserComesIntoANewFolderBehind() {
        var layout = PaneLayout()
        layout.sync(with: ["browser"], behind: ["browser"])
        XCTAssertEqual(layout.focusedPane.tabs, ["browser"])
        XCTAssertNil(layout.focusedPane.front, "the Browser stood in front of a new folder")
        layout.sync(with: ["browser", "shell-1"], behind: ["browser"])
        XCTAssertEqual(layout.focusedPane.front, "shell-1")
        layout.show("browser")
        layout.sync(with: ["browser", "shell-1", "shell-2"], behind: ["browser"])
        XCTAssertEqual(layout.focusedPane.front, "browser", "shown by the user, it stays in front")
    }

    /// PANE-1: a tab is in one pane at most.
    func testATabIsInOnePaneOnly() {
        var layout = three()
        let first = layout.focused
        let right = layout.split(first, .sideBySide, moving: "b")!
        XCTAssertEqual(layout.pane(first)?.tabs, ["a", "c"])
        XCTAssertEqual(layout.pane(first)?.front, "a")
        XCTAssertEqual(layout.pane(right)?.tabs, ["b"])
        layout.show("b", in: first)
        XCTAssertEqual(layout.allTabs.filter { $0 == "b" }.count, 1)
        XCTAssertEqual(layout.pane(first)?.front, "b")
        // The pane it left is empty and goes.
        XCTAssertNil(layout.pane(right))
        XCTAssertFalse(layout.isSplit)
    }

    func testShowingATabMovesTheKeyboardToItsPane() {
        var layout = three()
        let first = layout.focused
        let right = layout.split(first, .sideBySide, moving: "c")!
        layout.focus(first)
        layout.show("c")
        XCTAssertEqual(layout.focused, right)
        XCTAssertEqual(layout.pane(first)?.front, "b")
    }

    /// PANE-3: closing a pane closes no tab; they join the pane nearest.
    func testClosingAPaneKeepsItsTabs() {
        var layout = three()
        let first = layout.focused
        let right = layout.split(first, .sideBySide, moving: "c")!
        let below = layout.split(right, .stacked, moving: "b")!
        layout.close(right)
        XCTAssertEqual(Set(layout.allTabs), ["a", "b", "c"])
        XCTAssertEqual(layout.panes.count, 2)
        // Its neighbour below took them, and the keyboard.
        XCTAssertEqual(Set(layout.pane(below)?.tabs ?? []), ["b", "c"])
        XCTAssertEqual(layout.focused, below)
        layout.close(below)
        layout.close(first)
        XCTAssertEqual(layout.panes.count, 1, "the only pane stays")
        XCTAssertEqual(Set(layout.allTabs), ["a", "b", "c"])
    }

    func testASplitOffPaneStaysEmptyUntilGivenATab() {
        var layout = three()
        let new = layout.split(layout.focused, .stacked)!
        layout.sync(with: ["a", "b", "c"])
        XCTAssertNotNil(layout.pane(new))
        XCTAssertEqual(layout.focused, new)
        layout.show("a", in: new)
        XCTAssertEqual(layout.pane(new)?.tabs, ["a"])
        // Once it had a tab, losing its last one closes it.
        layout.sync(with: ["b", "c"])
        XCTAssertNil(layout.pane(new))
    }

    /// PANE-4: a tab that ends leaves the one before it in front.
    func testATabThatEndsLeavesTheOneBeforeItInFront() {
        var layout = three()
        layout.show("c")
        layout.sync(with: ["a", "b"])
        XCTAssertEqual(layout.focusedPane.front, "b")
        layout.show("a")
        layout.sync(with: ["b"])
        XCTAssertEqual(layout.focusedPane.front, "b")
    }

    func testTabsKeepTheOrderOfTheStrip() {
        var layout = PaneLayout()
        layout.sync(with: ["c", "a", "b"])
        layout.sync(with: ["a", "b", "c"])
        XCTAssertEqual(layout.focusedPane.tabs, ["a", "b", "c"])
    }

    /// PANE-5: moving between panes by direction.
    func testNeighbours() {
        // [ a | [ b / c ] ]
        var layout = three()
        let a = layout.focused
        let b = layout.split(a, .sideBySide, moving: "b")!
        let c = layout.split(b, .stacked, moving: "c")!
        XCTAssertEqual(layout.neighbour(of: a, .right), b)
        XCTAssertEqual(layout.neighbour(of: b, .left), a)
        XCTAssertEqual(layout.neighbour(of: c, .left), a)
        XCTAssertEqual(layout.neighbour(of: b, .down), c)
        XCTAssertEqual(layout.neighbour(of: c, .up), b)
        XCTAssertNil(layout.neighbour(of: a, .left))
        XCTAssertNil(layout.neighbour(of: a, .up))
        XCTAssertNil(layout.neighbour(of: c, .right))
    }

    /// PANE-6: one pane shown alone, and the others back.
    func testMaximized() {
        var layout = three()
        let a = layout.focused
        let b = layout.split(a, .sideBySide, moving: "b")!
        layout.toggleMaximized(b)
        XCTAssertEqual(layout.maximized, b)
        layout.toggleMaximized(b)
        XCTAssertNil(layout.maximized)
        layout.toggleMaximized(a)
        layout.focus(b)
        XCTAssertNil(layout.maximized, "another pane taking the keyboard shows them all again")
        layout.toggleMaximized(b)
        layout.close(b)
        XCTAssertNil(layout.maximized)
    }

    func testFractionsStayWithinReach() {
        var layout = three()
        layout.split(layout.focused, .sideBySide, moving: "c")
        guard case .split(let id, _, _, _, _) = layout.root else { return XCTFail("not split") }
        layout.setFraction(id, 0.99)
        guard case .split(_, _, let fraction, _, _) = layout.root else { return XCTFail("not split") }
        XCTAssertEqual(fraction, 0.9)
    }

    /// PANE-7: the layout is kept as JSON, for each host and project.
    func testItIsKeptAndReadBack() throws {
        var layout = three()
        layout.split(layout.focused, .stacked, moving: "a")
        let read = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(read, layout)
        // A new pane after reading it back gets a name of its own.
        var more = read
        let new = more.split(more.focused, .sideBySide)!
        XCTAssertEqual(Set(more.panes.map(\.id)).count, 3)
        XCTAssertFalse(layout.panes.map(\.id).contains(new))
    }

    func testAStripShowsItsOwnTabs() {
        var tabs = TabLayout()
        tabs.sync(with: ["a", "b", "c", "d"])
        tabs.move("c", before: "a")
        XCTAssertEqual(tabs.strip(among: ["a", "c"]), ["c", "a"])
        XCTAssertEqual(tabs.strip(among: ["d"]), ["d"])
    }

    /// PANE-21 (#69, #127): an agent's area shows the shell and the page
    /// picked while they are there, the last of them otherwise.
    func testAnAgentAreaShowsAShellThatRuns() {
        var area = AgentArea()
        XCTAssertEqual(area.shownShell(among: ["s1", "s2"]), "s2")
        area.shellFront = "s1"
        XCTAssertEqual(area.shownShell(among: ["s1", "s2"]), "s1")
        XCTAssertEqual(area.shownShell(among: ["s2"]), "s2")
        XCTAssertNil(area.shownShell(among: []))
        area.browserFront = "b:1"
        XCTAssertEqual(area.shownBrowser(among: ["b:1", "b:2"]), "b:1")
        XCTAssertEqual(area.shownBrowser(among: ["b:2", "b:3"]), "b:3")
    }
}
