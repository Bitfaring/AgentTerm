import XCTest

@testable import AgentTermProtocol

/// A Shells tab split in three (the owner's request, 2026-11-21):
/// SHELL-SPLIT-2 to SHELL-SPLIT-5 in docs/TESTING.md.
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
    /// first new shell came: each gets one of the new shells, in turn.
    func testEachPartWaitsForANewShellOfItsOwn() {
        var split = ShellSplit()
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.right, picked: picked, members: ["a"]), .waiting)
        XCTAssertEqual(split.turnOn(.below, picked: picked, members: ["a"]), .waiting)
        XCTAssertEqual(split.takeNew("b", picked: picked, members: ["a", "b"]), .right)
        // The second comes without being put in front: the row has it.
        split.tidy(picked: &picked, members: ["a", "b", "c"])
        XCTAssertEqual(shown(split, picked, ["a", "b", "c"]), [.main: "a", .right: "b", .below: "c"])
        XCTAssertTrue(split.waits.isEmpty)
    }

    /// SHELL-SPLIT-5 (#189): a shell the tab had when the part was turned
    /// on is not the one it waits for, put in front or not.
    func testAWaitingPartTakesNoShellTheTabHad() {
        var split = ShellSplit(right: "b")
        var picked: String? = "a"
        XCTAssertEqual(split.turnOn(.below, picked: picked, members: ["a", "b"]), .waiting)
        split.turnOff(.right)
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        split.tidy(picked: &picked, members: ["a", "b"])
        XCTAssertNil(split.below)
        XCTAssertEqual(split.takeNew("c", picked: picked, members: ["a", "b", "c"]), .below)
        // Turned off, or the launch failed: it waits no more.
        split = ShellSplit()
        _ = split.turnOn(.right, picked: picked, members: ["a"])
        split.turnOff(.right)
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
        _ = split.turnOn(.right, picked: picked, members: ["a"])
        split.stopWaiting()
        XCTAssertNil(split.takeNew("b", picked: picked, members: ["a", "b"]))
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
