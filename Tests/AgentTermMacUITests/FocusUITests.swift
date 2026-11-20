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
