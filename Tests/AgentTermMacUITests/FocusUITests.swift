import AgentTermProtocol
import XCTest

/// Picking a shell or a session puts the keyboard in it: PANE-16 in
/// docs/TESTING.md. With a page in an agent's tab, PANE-17 in BrowserUITests.
///
/// A click of the mouse is not tried: the tests press through
/// accessibility, and the mouse's own events cannot be given to the app
/// without moving the pointer of the person at the Mac.
final class FocusUITests: MacUITestCase {
    /// SHELL-SPLIT-1: a Shells tab split as an agent's area is (the owner's
    /// request, 2026-11-21): a shell on the right, the one not shown yet;
    /// one below, a new shell when none is left; each with the keyboard as
    /// it comes; picking one in the row puts the keyboard in its part; its
    /// menu's Show on the Right puts it there, the two changing places;
    /// turned off, its shell keeps running in the row.
    func testAShellsTabSplitsInThree() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        app.press(.id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first shell")
        // The right: the shell not on show.
        app.press(.id("shells-part-right"))
        app.wait(for: .id("terminal-\(second.id)"), timeout: 10)
        XCTAssertTrue(app.exists(.id("terminal-\(first.id)")), "the left's shell went")
        app.waitForKeyboard(in: "terminal-\(second.id)", "the shell on the right")
        // Below: none left, a new one, there.
        app.press(.id("shells-part-below"))
        wait("a third shell") { phone.sessions.count == 3 }
        let third = try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
        app.wait(for: .id("terminal-\(third.id)"), timeout: 15)
        app.waitForKeyboard(in: "terminal-\(third.id)", "the shell below")
        XCTAssertTrue(app.exists(.id("terminal-\(first.id)")) && app.exists(.id("terminal-\(second.id)")), "not all three shown")
        shot("shells-in-three")
        // Picked in the row: the keyboard goes to its part, nothing moves.
        app.press(.id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the left again")
        XCTAssertTrue(app.exists(.id("terminal-\(second.id)")) && app.exists(.id("terminal-\(third.id)")))
        // From its menu: the left's shell on the right, the two changing places.
        app.perform("Show on the Right", on: .id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first, now on the right")
        wait("the first on the right of the second") {
            guard let left = self.app.frame(of: .id("terminal-\(second.id)")), let right = self.app.frame(of: .id("terminal-\(first.id)")) else { return false }
            return right.minX > left.maxX - 1
        }
        // The right off: its shell runs, in the row, not on show.
        app.press(.id("shells-part-right"))
        app.waitGone(.id("terminal-\(first.id)"))
        XCTAssertTrue(app.exists(.id("item-\(first.id)")), "the shell on the right left the row")
        XCTAssertEqual(phone.sessions.count, 3, "turning the right off ended its shell")
    }

    /// SHELL-SPLIT-2 (#188): the left's shell shown on the right, which was
    /// off, is there alone, with the keyboard, and the left shows the other
    /// shell. Before the fix it was in both parts, one of them blank, and
    /// the keyboard went back to the left.
    func testTheLeftsShellShownOnTheRightLeavesTheLeftAnother() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        app.press(.id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first shell")
        XCTAssertEqual(app.first(.id("shells-part-right"))?.value, "hidden")
        app.perform(ShellSplitWords.right, on: .id("item-\(first.id)"))
        app.wait(for: .id("terminal-\(second.id)"), timeout: 10)
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first, now on the right")
        XCTAssertEqual(app.all(.id("terminal-\(first.id)")).count, 1, "the first shell is in two parts")
        XCTAssertEqual(app.first(.id("shells-part-right"))?.value, "shown")
        wait("the second on the left of the first") {
            guard let left = self.app.frame(of: .id("terminal-\(second.id)")), let right = self.app.frame(of: .id("terminal-\(first.id)")) else { return false }
            return right.minX > left.maxX - 1
        }
        shot("left-to-right")
        // Below's shell shown on a right that is off: there alone, and
        // below closes.
        app.press(.id("shells-part-below"))
        wait("a third shell") { phone.sessions.count == 3 }
        let third = try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
        app.wait(for: .id("terminal-\(third.id)"), timeout: 15)
        app.press(.id("shells-part-right"))
        app.waitGone(.id("terminal-\(first.id)"))
        app.perform(ShellSplitWords.right, on: .id("item-\(third.id)"))
        app.waitForKeyboard(in: "terminal-\(third.id)", "the third, now on the right")
        XCTAssertEqual(app.all(.id("terminal-\(third.id)")).count, 1, "the third shell is in two parts")
        XCTAssertEqual(app.first(.id("shells-part-right"))?.value, "shown")
        XCTAssertEqual(app.first(.id("shells-part-below"))?.value, "hidden")
        wait("the second on the left of the third") {
            guard let left = self.app.frame(of: .id("terminal-\(second.id)")), let right = self.app.frame(of: .id("terminal-\(third.id)")) else { return false }
            return right.minX > left.maxX - 1
        }
        shot("below-to-right")
    }

    /// SHELL-SPLIT-8 (#188): the keys that pick an item of the row (⌥⌘ and
    /// its number, ⌥⌘→, ⌥⌘←) move no shell between parts. One shown in a
    /// part takes the keyboard there; one not shown takes the place of the
    /// shell in the part with the keyboard, which goes back to the row. No
    /// shell is ever in two parts.
    func testTheKeysThatPickAnItemMoveNoShellBetweenParts() throws {
        let phone = try device()
        let shells = [try newShell(phone, count: 1), try newShell(phone, count: 2), try newShell(phone, count: 3)]
        app.press(.id("item-\(shells[0].id)"))
        app.waitForKeyboard(in: "terminal-\(shells[0].id)", "the first shell")
        app.press(.id("shells-part-right"))
        wait("a shell on the right") { shells.dropFirst().contains { self.app.exists(.id("terminal-\($0.id)")) } }
        let right = try XCTUnwrap(shells.dropFirst().first { app.exists(.id("terminal-\($0.id)")) })
        let free = try XCTUnwrap(shells.dropFirst().first { $0.id != right.id })
        app.waitForKeyboard(in: "terminal-\(right.id)", "the shell on the right")
        func assertEachOnce(_ when: String) {
            for shell in shells { XCTAssertLessThanOrEqual(app.all(.id("terminal-\(shell.id)")).count, 1, "shell \(shell.id) in two parts \(when)") }
        }
        func number(_ shell: SessionInfo) -> Int { (shells.firstIndex { $0.id == shell.id } ?? 0) + 1 }
        // The left's shell, by its number: the keyboard goes there.
        app.menu(["View", "Item \(number(shells[0])) in Group"])
        app.waitForKeyboard(in: "terminal-\(shells[0].id)", "the left's shell, by its number")
        XCTAssertTrue(app.exists(.id("terminal-\(right.id)")), "the right's shell went")
        assertEachOnce("after the left's was picked by its number")
        // The right's, by its number, from the left: the keyboard goes
        // there, and it stays on the right.
        app.menu(["View", "Item \(number(right)) in Group"])
        app.waitForKeyboard(in: "terminal-\(right.id)", "the right's shell, by its number")
        XCTAssertTrue(app.exists(.id("terminal-\(shells[0].id)")), "the left's shell went")
        assertEachOnce("after the right's was picked by its number")
        wait("the right's shell still on the right") {
            guard let left = self.app.frame(of: .id("terminal-\(shells[0].id)")), let shown = self.app.frame(of: .id("terminal-\(right.id)")) else { return false }
            return shown.minX > left.maxX - 1
        }
        // The one not shown, from the right: in the right's place, the
        // right's back in the row, the left as it was.
        app.menu(["View", "Item \(number(free)) in Group"])
        app.waitForKeyboard(in: "terminal-\(free.id)", "the free shell, on the right")
        app.waitGone(.id("terminal-\(right.id)"))
        XCTAssertTrue(app.exists(.id("terminal-\(shells[0].id)")), "the left's shell went")
        XCTAssertTrue(app.exists(.id("item-\(right.id)")), "the right's shell left the row")
        assertEachOnce("after the free one was picked by its number")
        // The arrows go the same way: from the free one, the next in the
        // row and then back.
        let next = shells[number(free) % shells.count]
        app.menu(["View", "Next Item in Group"])
        app.waitForKeyboard(in: "terminal-\(next.id)", "the next in the row")
        assertEachOnce("after Next Item in Group")
        app.menu(["View", "Previous Item in Group"])
        app.waitForKeyboard(in: "terminal-\(free.id)", "the one before it")
        assertEachOnce("after Previous Item in Group")
        XCTAssertTrue(app.exists(.id("terminal-\(shells[0].id)")), "the left's shell went")
        XCTAssertEqual(phone.sessions.count, 3, "a shell was started")
        shot("keys")
    }

    /// SHELL-SPLIT-3 (#188): the one shell of the tab, on the left, cannot
    /// be shown on the right, which would leave the left with none: the
    /// app says so at once, and nothing moves.
    func testTheLeftsOnlyShellStaysAndTheAppSaysWhy() throws {
        let phone = try device()
        let only = try newShell(phone, count: 1)
        app.waitForKeyboard(in: "terminal-\(only.id)", "the shell")
        app.perform(ShellSplitWords.right, on: .id("item-\(only.id)"))
        app.wait(for: .text(ShellSplitWords.leftKeepsIt))
        shot("refused")
        app.press(.button("OK"))
        app.waitGone(.text(ShellSplitWords.leftKeepsIt))
        XCTAssertEqual(app.all(.id("terminal-\(only.id)")).count, 1)
        XCTAssertEqual(app.first(.id("shells-part-right"))?.value, "hidden")
        app.waitForKeyboard(in: "terminal-\(only.id)", "the shell, still on the left")
        XCTAssertEqual(phone.sessions.count, 1, "a shell was started")
    }

    /// PANE-26 (#171): each of the first nine items of the row says the
    /// keys that pick it, always, at its end, as each tab of the strip says
    /// its ⌘ and number (the owner's decision, 2026-11-21). Before, only a
    /// number while ⌥⌘ was held, set above the chip, where the row's scroll
    /// view cut it off under the strip.
    func testEachItemSaysItsKeys() throws {
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        app.press(.button("new.txt"), timeout: 15)
        app.wait(for: .idEnding("new.txt", prefix: "item-"), timeout: 15)
        for (number, file) in [(1, "notes.txt"), (2, "new.txt")] {
            app.wait(for: .id("row-shortcut-\(number)"), timeout: 10)
            XCTAssertEqual(app.first(.id("row-shortcut-\(number)"))?.value, "⌥⌘\(number)")
            let shortcut = try XCTUnwrap(app.frame(of: .id("row-shortcut-\(number)")))
            let chip = try XCTUnwrap(app.frame(of: .idEnding(file, prefix: "item-")))
            XCTAssertTrue(chip.contains(shortcut), "the shortcut of \(file) is not within its chip: \(shortcut) over \(chip)")
        }
        shot("row-shortcuts")
    }

    @discardableResult
    private func newShell(_ phone: Device, count: Int) throws -> SessionInfo {
        app.menu(["File", "New Shell"])
        wait("shell \(count) to start") { phone.sessions.count == count }
        let shell = try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
        app.wait(for: .id("item-\(shell.id)"))
        return shell
    }

    /// PANE-16: picking a shell in the row of the Shells tab (#127), or a
    /// session in the list at the left, gives its terminal the keyboard;
    /// so do the View menu's Next and Previous Item in Group (⌥⌘→, ⌥⌘←),
    /// which go round the shells the tab holds, one shown at a time.
    func testPickingGivesTheKeyboard() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        app.waitForKeyboard(in: "terminal-\(second.id)", "the new shell")

        app.press(.id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the shell picked in the row")
        app.press(.id("session-\(second.id)"))
        app.waitForKeyboard(in: "terminal-\(second.id)", "the session picked in the list")
        app.press(.id("session-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the session picked in the list")
        XCTAssertEqual(app.selectedRows(), ["session-\(first.id)"])

        app.menu(["View", "Next Item in Group"])
        app.waitForKeyboard(in: "terminal-\(second.id)", "the next shell of the tab")
        XCTAssertFalse(app.exists(.id("terminal-\(first.id)")), "two shells of the user's are shown at once")
        app.menu(["View", "Next Item in Group"])
        app.waitForKeyboard(in: "terminal-\(first.id)", "round to the first")
        app.menu(["View", "Previous Item in Group"])
        app.waitForKeyboard(in: "terminal-\(second.id)", "the one before it")
    }

    /// PANE-22 (#171): ⌥⌘ and a number picks that item of the row of the
    /// group in front, left to right, and gives it the keyboard.
    func testOptionCommandANumberPicksAnItemOfTheRow() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        let third = try newShell(phone, count: 3)
        app.waitForKeyboard(in: "terminal-\(third.id)", "the new shell")
        app.menu(["View", "Item 1 in Group"])
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first item of the row")
        app.menu(["View", "Item 3 in Group"])
        app.waitForKeyboard(in: "terminal-\(third.id)", "the third item of the row")
        app.menu(["View", "Item 2 in Group"])
        app.waitForKeyboard(in: "terminal-\(second.id)", "the second item of the row")
    }

    /// PANE-25 (#171): the same in the Files tab and in the Diffs tab: the
    /// file or the diff of that number shown, with the keyboard; the next
    /// one by the shortcut that moves by one, as before.
    func testOptionCommandANumberPicksAFileOrADiff() throws {
        /// Whether the text that has the keyboard is this file's, or this diff's.
        func keyboard(in text: String) -> Bool { app.keyboardPath().role == kAXTextAreaRole as String && app.keyboardValue().contains(text) }
        app.press(.button("Files"))
        app.press(.button("notes.txt"), timeout: 15)
        app.wait(for: .idEnding("notes.txt", prefix: "item-"), timeout: 15)
        app.press(.button("new.txt"))
        app.wait(for: .idEnding("new.txt", prefix: "item-"), timeout: 15)
        app.menu(["View", "Item 1 in Group"])
        app.wait("the first file by its number, with the keyboard") { keyboard(in: "second line") }
        app.menu(["View", "Item 2 in Group"])
        app.wait("the second file by its number, with the keyboard") { keyboard(in: "a file that is new") }
        app.menu(["View", "Previous Item in Group"])
        app.wait("the one before it, as before") { keyboard(in: "second line") }

        app.press(.button("Git"))
        app.press(.id("change-notes.txt"), timeout: 15)
        app.press(.id("change-new.txt"), timeout: 15)
        app.wait("two diffs in the row") { self.app.nodes().filter { $0.identifier.hasPrefix("item-") }.count == 2 }
        app.menu(["View", "Item 1 in Group"])
        app.wait("the first diff by its number, with the keyboard") { keyboard(in: "second line") && !keyboard(in: "a file that is new") }
        app.menu(["View", "Item 2 in Group"])
        app.wait("the second diff by its number, with the keyboard") { keyboard(in: "a file that is new") }
        app.menu(["View", "Next Item in Group"])
        app.wait("round to the first, as before") { keyboard(in: "second line") && !keyboard(in: "a file that is new") }
    }
}

/// A Shells tab's parts waiting for new shells while the host's answers
/// are held back (`SlowProxy`), so that what comes in between is certain:
/// SHELL-SPLIT-4 and SHELL-SPLIT-5 in docs/TESTING.md (#189).
final class ShellSplitWaitTests: MacUITestCase {
    private var proxy: SlowProxy!
    private var proxyPort: UInt16 = 0
    override var appPort: UInt16 { proxyPort }

    override func beforeTheAppStarts() throws {
        // As fast as the host: held only while a test says so.
        proxy = try SlowProxy(to: port, bytesPerSecond: 50_000_000)
        proxyPort = proxy.start()
    }

    override func tearDown() {
        // The app quit first: with the proxy gone under it, it started a
        // host of its own on the proxy's port, which its picture showed.
        super.tearDown()
        proxy?.stop()
    }

    @discardableResult
    private func newShell(_ phone: Device, count: Int) throws -> SessionInfo {
        app.menu(["File", "New Shell"])
        let shell = try started(phone, count: count)
        app.wait(for: .id("item-\(shell.id)"))
        return shell
    }

    /// The host has a new shell, whether the app was told yet or not.
    private func started(_ phone: Device, count: Int) throws -> SessionInfo {
        wait("shell \(count) to start on the host") { phone.sessions.count == count }
        return try XCTUnwrap(phone.sessions.max { $0.id < $1.id })
    }

    /// What the test is about: while held, the app has not heard of the
    /// new shell. Once, a receive the proxy had asked for before it was
    /// held let the next answer through, and the app had the shell.
    private func assertNotHeardOf(_ shell: SessionInfo, file: StaticString = #filePath, line: UInt = #line) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(app.exists(.id("item-\(shell.id)")), "the app heard of shell \(shell.id) while the host's answers were held", file: file, line: line)
    }

    /// SHELL-SPLIT-4: the right and then below turned on before the first
    /// new shell is in the app: each shows a new shell of its own. Before
    /// the fix below took the right's wait, and the right stayed off.
    func testTheRightAndBelowEachGetANewShell() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        app.waitForKeyboard(in: "terminal-\(first.id)", "the shell")
        proxy.hold(true)
        app.press(.id("shells-part-right"))
        let second = try started(phone, count: 2)
        assertNotHeardOf(second)
        app.press(.id("shells-part-below"))
        let third = try started(phone, count: 3)
        assertNotHeardOf(third)
        proxy.hold(false)
        app.wait(for: .id("terminal-\(second.id)"), timeout: 15)
        app.wait(for: .id("terminal-\(third.id)"), timeout: 15)
        XCTAssertTrue(app.exists(.id("terminal-\(first.id)")), "the left's shell went")
        XCTAssertEqual(app.first(.id("shells-part-right"))?.value, "shown")
        XCTAssertEqual(app.first(.id("shells-part-below"))?.value, "shown")
        wait("the second on the right, the third below") {
            guard let left = self.app.frame(of: .id("terminal-\(first.id)")), let right = self.app.frame(of: .id("terminal-\(second.id)")),
                let below = self.app.frame(of: .id("terminal-\(third.id)"))
            else { return false }
            return right.minX > left.maxX - 1 && below.minY > left.maxY - 1 && below.minY > right.maxY - 1
        }
        shot("each-its-own")
    }

    /// SHELL-SPLIT-5: while below waits for its new shell, a shell the tab
    /// already had, picked in the row, is not taken for it: it is shown
    /// where the keyboard is, and below gets the new one. Before the fix
    /// below took the shell picked.
    func testAWaitingPartTakesOnlyItsNewShell() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        app.press(.id("item-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the first shell")
        app.press(.id("shells-part-right"))
        app.waitForKeyboard(in: "terminal-\(second.id)", "the shell on the right")
        proxy.hold(true)
        app.press(.id("shells-part-below"))
        let third = try started(phone, count: 3)
        assertNotHeardOf(third)
        // The right off, then its shell picked in the row: the left shows it.
        app.press(.id("shells-part-right"))
        app.waitGone(.id("terminal-\(second.id)"))
        app.press(.id("item-\(second.id)"))
        app.waitForKeyboard(in: "terminal-\(second.id)", "the second, picked")
        app.waitGone(.id("terminal-\(first.id)"))
        XCTAssertEqual(app.first(.id("shells-part-below"))?.value, "hidden", "below took a shell the tab had")
        proxy.hold(false)
        app.wait(for: .id("terminal-\(third.id)"), timeout: 15)
        XCTAssertEqual(app.first(.id("shells-part-below"))?.value, "shown")
        XCTAssertEqual(app.all(.id("terminal-\(second.id)")).count, 1, "the second is in two parts")
        wait("the third below the second") {
            guard let top = self.app.frame(of: .id("terminal-\(second.id)")), let below = self.app.frame(of: .id("terminal-\(third.id)")) else { return false }
            return below.minY > top.maxY - 1
        }
        shot("below-its-own")
    }
}
