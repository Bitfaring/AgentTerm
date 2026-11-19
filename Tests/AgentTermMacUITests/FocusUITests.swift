import AgentTermProtocol
import XCTest

/// Picking a shell or a session puts the keyboard in it: PANE-16 in
/// docs/TESTING.md. With a page in an agent's tab, PANE-17 in BrowserUITests.
///
/// A click of the mouse is not tried: the tests press through
/// accessibility, and the mouse's own events cannot be given to the app
/// without moving the pointer of the person at the Mac.
final class FocusUITests: MacUITestCase {
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
