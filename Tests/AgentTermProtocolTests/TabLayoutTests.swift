import AgentTermProtocol
import XCTest

final class TabLayoutTests: XCTestCase {
    private func layout(_ ids: String...) -> TabLayout {
        var layout = TabLayout()
        layout.sync(with: ids)
        return layout
    }

    func testNewTabsGoToTheEndAndGoneOnesDisappear() {
        var tabs = layout("a", "b", "c")
        tabs.move("c", before: "a")
        tabs.sync(with: ["a", "b", "c", "d"])
        XCTAssertEqual(tabs.order, ["c", "a", "b", "d"], "the order chosen is kept; the new tab is last")
        tabs.setPinned("b", true)
        tabs.sync(with: ["a", "d"])
        XCTAssertEqual(tabs.order, ["a", "d"])
        XCTAssertEqual(tabs.pinned, [])
    }

    func testDraggingATabPutsItBeforeTheOneItIsDroppedOn() {
        var tabs = layout("a", "b", "c", "d")
        tabs.move("d", before: "b")
        XCTAssertEqual(tabs.order, ["a", "d", "b", "c"])
        tabs.move("a", before: nil)
        XCTAssertEqual(tabs.order, ["d", "b", "c", "a"], "dropped past the last tab")
        tabs.move("b", before: "b")
        tabs.move("nope", before: "a")
        XCTAssertEqual(tabs.order, ["d", "b", "c", "a"])
    }

    func testPinnedTabsComeFirst() {
        var tabs = layout("a", "b", "c", "d")
        tabs.setPinned("c", true)
        tabs.setPinned("d", true)
        XCTAssertEqual(tabs.order, ["c", "d", "a", "b"])
        // Dropped among the pinned, a tab is pinned; dropped after them, it is not.
        tabs.move("a", before: "d")
        XCTAssertEqual(tabs.order, ["c", "a", "d", "b"])
        XCTAssertEqual(tabs.pinned, ["a", "c", "d"])
        tabs.move("c", before: "b")
        XCTAssertEqual(tabs.order, ["a", "d", "c", "b"])
        XCTAssertFalse(tabs.isPinned("c"))
        tabs.setPinned("a", false)
        XCTAssertEqual(tabs.order, ["d", "a", "c", "b"], "unpinned, it sits right after the pinned ones")
    }

    func testMovingByOnePlace() {
        var tabs = layout("a", "b", "c")
        tabs.move("a", by: 1)
        XCTAssertEqual(tabs.order, ["b", "a", "c"])
        tabs.move("a", by: 1)
        tabs.move("a", by: 1)
        XCTAssertEqual(tabs.order, ["b", "c", "a"], "it stops at the end")
        tabs.move("a", by: -1)
        XCTAssertEqual(tabs.order, ["b", "a", "c"])
    }

    func testAClientThatKnowsOnlySessionsLeavesOtherTabsAlone() {
        var tabs = layout("s:1:10", "h:files:/p", "s:2:20")
        tabs.setPinned("h:files:/p", true)
        // The phone: session 1 ended, session 3 is new. The Files tab is the Mac's.
        tabs.sync(with: ["s:2:20", "s:3:30"], owns: SessionInfo.isLayoutID)
        XCTAssertEqual(tabs.order, ["h:files:/p", "s:2:20", "s:3:30"])
        XCTAssertTrue(tabs.isPinned("h:files:/p"))
    }

    /// TABS-1 (#127): only the agents have tabs of their own; a shell is in
    /// its agent's tab while the agent runs, or in the user's Shells tab.
    func testOnlyTheAgentsSessionsHaveTabsOfTheirOwn() {
        func session(_ id: SessionID, agent: String?, openedBy: SessionID? = nil) -> SessionInfo {
            var info = SessionInfo(id: id, title: "t", cwd: "/p", size: .default, createdAt: Date(timeIntervalSince1970: 10), agent: agent)
            info.openedBy = openedBy
            return info
        }
        let agent = session(1, agent: "claude")
        let itsShell = session(2, agent: nil, openedBy: 1)
        let usersShell = session(3, agent: nil)
        let orphan = session(4, agent: nil, openedBy: 99)
        XCTAssertEqual(SessionInfo.withTabs([agent, itsShell, usersShell, orphan]).map(\.id), [1])
    }

    func testTheLayoutSurvivesBeingSaved() throws {
        var tabs = layout("a", "b", "c")
        tabs.setPinned("c", true)
        let restored = try JSONDecoder().decode(TabLayout.self, from: JSONEncoder().encode(tabs))
        XCTAssertEqual(restored, tabs)
    }
}
