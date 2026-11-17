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
}
