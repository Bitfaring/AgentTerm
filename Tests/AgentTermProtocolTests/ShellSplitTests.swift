import XCTest

@testable import AgentTermProtocol

/// A Shells tab split in three (the owner's request, 2026-11-21):
/// SHELL-SPLIT-2 to SHELL-SPLIT-7 in docs/TESTING.md.
final class ShellSplitTests: XCTestCase {
    /// What each part shows, the left first.
    private func shown(_ split: ShellSplit, _ picked: String?, _ members: [String]) -> [ShellPart: String] {
        var all: [ShellPart: String] = [:]
        for part in split.parts(in: members) { all[part] = split.shell(in: part, picked: picked, members: members) }
        return all
    }

    /// No shell in two parts.
    private func assertNoneTwice(_ split: ShellSplit, _ picked: String?, _ members: [String], file: StaticString = #filePath, line: UInt = #line) {
        let shells = split.parts(in: members).compactMap { split.shell(in: $0, picked: picked, members: members) }
        XCTAssertEqual(shells.count, Set(shells).count, "a shell in two parts: \(shown(split, picked, members))", file: file, line: line)
    }

    /// SHELL-SPLIT-2 (#188): the left's shell shown on the right, which was
    /// off, leaves the left the shell not on show; picked or not.
    func testTheLeftsShellMovedToAPartThatWasOffLeavesItAnother() {
        for initial in ["a", nil] as [String?] {
            var split = ShellSplit()
            var picked = initial
            XCTAssertTrue(split.show("a", in: .right, picked: &picked, members: ["a", "b"]))
            XCTAssertEqual(shown(split, picked, ["a", "b"]), [.main: "b", .right: "a"], "picked \(initial ?? "none")")
            assertNoneTwice(split, picked, ["a", "b"])
        }
        // Below, beside a right that is on: the left takes the third.
        var split = ShellSplit(right: "b")
        var picked: String? = "a"
        XCTAssertTrue(split.show("a", in: .below, picked: &picked, members: ["a", "b", "c"]))
        XCTAssertEqual(shown(split, picked, ["a", "b", "c"]), [.main: "c", .right: "b", .below: "a"])
    }

    /// SHELL-SPLIT-3 (#188): with no shell free to take its place, the
    /// left's is not moved, and the caller says why.
    func testTheLeftsShellIsNotMovedWhenNoneCanTakeItsPlace() {
        var split = ShellSplit()
        var picked: String? = "a"
        XCTAssertFalse(split.show("a", in: .right, picked: &picked, members: ["a"]))
        XCTAssertEqual(split, ShellSplit())
        XCTAssertEqual(picked, "a")
        // The other shell already on the right: none free for the left.
        split = ShellSplit(right: "b")
        XCTAssertFalse(split.show("a", in: .below, picked: &picked, members: ["a", "b"]))
        XCTAssertEqual(shown(split, picked, ["a", "b"]), [.main: "a", .right: "b"])
    }

    /// SHELL-SPLIT-2 (#188): shown in a part that is on, the two change
    /// places, as before; from below to a right that was off, below closes.
    func testAShellMovedBetweenPartsNeverShowsTwice() {
        var split = ShellSplit(right: "b", below: "c")
        var picked: String? = "a"
        XCTAssertTrue(split.show("a", in: .right, picked: &picked, members: ["a", "b", "c"]))
        XCTAssertEqual(shown(split, picked, ["a", "b", "c"]), [.main: "b", .right: "a", .below: "c"])

        split = ShellSplit(below: "b")
        picked = "a"
        XCTAssertTrue(split.show("b", in: .right, picked: &picked, members: ["a", "b"]))
        XCTAssertEqual(shown(split, picked, ["a", "b"]), [.main: "a", .right: "b"])
        assertNoneTwice(split, picked, ["a", "b"])
    }

    /// SHELL-SPLIT-4 (#189): the right and then below turned on before the
    /// first new shell came: each gets the shell launched for it.
    func testEachPartWaitsForANewShellOfItsOwn() {
        var split = ShellSplit()
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.right, picked: picked, members: ["a"], request: 1), .waiting)
        XCTAssertEqual(split.turnOn(.below, picked: picked, members: ["a"], request: 2), .waiting)
        XCTAssertTrue(split.launched(request: 1, shell: "b"))
        XCTAssertEqual(split.takeNew("b", picked: picked, members: ["a", "b"]), .right)
        // The second comes without being put in front: the row has it.
        XCTAssertTrue(split.launched(request: 2, shell: "c"))
        split.tidy(picked: &picked, members: ["a", "b", "c"])
        XCTAssertEqual(shown(split, picked, ["a", "b", "c"]), [.main: "a", .right: "b", .below: "c"])
        XCTAssertTrue(split.waits.isEmpty)
    }

    /// SHELL-SPLIT-5 (#189): a shell the tab had when the part was turned
    /// on is not the one it waits for, put in front or not.
    func testAWaitingPartTakesNoShellTheTabHad() {
        var split = ShellSplit(right: "b")
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.below, picked: picked, members: ["a", "b"], request: 1), .waiting)
        split.turnOff(.right)
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        split.tidy(picked: &picked, members: ["a", "b"])
        XCTAssertNil(split.below)
        XCTAssertTrue(split.launched(request: 1, shell: "c"))
        XCTAssertEqual(split.takeNew("c", picked: picked, members: ["a", "b", "c"]), .below)
        // Turned off, or the launch failed, or the connection went: it
        // waits no more.
        split = ShellSplit()
        _ = split.turnOn(.right, picked: picked, members: ["a"], request: 2)
        split.turnOff(.right)
        XCTAssertFalse(split.launched(request: 2, shell: "b"))
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        _ = split.turnOn(.right, picked: picked, members: ["a"], request: 3)
        split.stopWaiting(request: 3)
        XCTAssertFalse(split.launched(request: 3, shell: "b"))
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        _ = split.turnOn(.right, picked: picked, members: ["a"], request: 4)
        split.stopWaiting()
        XCTAssertFalse(split.launched(request: 4, shell: "b"))
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        // Its shell not in the tab once the host said which it is: it
        // ended before it was shown, or was started in another folder.
        _ = split.turnOn(.right, picked: picked, members: ["a"], request: 5)
        XCTAssertTrue(split.launched(request: 5, shell: "z"))
        split.tidy(picked: &picked, members: ["a"])
        XCTAssertTrue(split.waits.isEmpty)
        XCTAssertNil(split.right)
    }

    /// SHELL-SPLIT-6 (#189): a shell new to the tab that was not launched
    /// for the waiting part (File > New Shell, the iPhone, while it waits)
    /// is not taken, put in front or only in the row; the part takes the
    /// one whose request the host gave back. Before, it took the first new.
    func testAWaitingPartTakesOnlyTheShellLaunchedForIt() {
        var split = ShellSplit()
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.right, picked: picked, members: ["a"], request: 7), .waiting)
        // Started elsewhere meanwhile: new to the tab, not the part's own.
        XCTAssertFalse(split.launched(request: 8, shell: "x"))
        XCTAssertNil(split.takeNew("x", picked: picked, members: ["a", "x"]), "took a shell launched for no part")
        split.tidy(picked: &picked, members: ["a", "x"])
        XCTAssertNil(split.right, "took a shell new to the tab from the row")
        XCTAssertEqual(split.waits.map(\.part), [.right])
        // Its own, once the host said which it is.
        XCTAssertTrue(split.launched(request: 7, shell: "b"))
        XCTAssertNil(split.takeNew("x", picked: picked, members: ["a", "x", "b"]))
        XCTAssertEqual(split.takeNew("b", picked: picked, members: ["a", "x", "b"]), .right)
        XCTAssertEqual(shown(split, picked, ["a", "x", "b"]), [.main: "a", .right: "b"])
        XCTAssertTrue(split.waits.isEmpty)
    }

    /// SHELL-SPLIT-7 (#189): the host's error for one part's launch ends
    /// that wait alone: the other part still takes its own shell. Before,
    /// any error ended every wait.
    func testTheErrorOfAnotherRequestDoesNotEndAWait() {
        var split = ShellSplit()
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.right, picked: picked, members: ["a"], request: 1), .waiting)
        XCTAssertEqual(split.turnOn(.below, picked: picked, members: ["a"], request: 2), .waiting)
        split.stopWaiting(request: 2)
        XCTAssertEqual(split.waits.map(\.part), [.right], "an error for below's launch ended the right's wait")
        // A request no part of this tab made ends nothing.
        split.stopWaiting(request: 9)
        XCTAssertEqual(split.waits.map(\.part), [.right])
        XCTAssertFalse(split.launched(request: 2, shell: "c"))
        XCTAssertTrue(split.launched(request: 1, shell: "b"))
        split.tidy(picked: &picked, members: ["a", "b", "c"])
        XCTAssertEqual(shown(split, picked, ["a", "b", "c"]), [.main: "a", .right: "b"])
    }

    /// SHELL-SPLIT-2 (#188): the left's shell ended while every other one
    /// is on show: the right's moves to the left, rather than be in both.
    func testTheLeftTakesTheRightsShellWhenItsOwnEnded() {
        var split = ShellSplit(right: "b", below: "c")
        var picked: String? = nil
        split.tidy(picked: &picked, members: ["b", "c"])
        XCTAssertEqual(shown(split, picked, ["b", "c"]), [.main: "b", .below: "c"])
        assertNoneTwice(split, picked, ["b", "c"])
    }
}
