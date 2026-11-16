import AgentTermProtocol
import XCTest

/// Picking a tab or a session puts the keyboard in it: PANE-16 in
/// docs/TESTING.md. With a page beside an agent, PANE-17 in BrowserUITests.
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
        app.wait(for: .id("tab-\(shell.id)"))
        return shell
    }

    /// PANE-16: picking a tab, or a session in the list at the left, gives
    /// its terminal the keyboard.
    func testPickingGivesTheKeyboard() throws {
        let phone = try device()
        let first = try newShell(phone, count: 1)
        let second = try newShell(phone, count: 2)
        app.waitForKeyboard(in: "terminal-\(second.id)", "the new shell")

        app.press(.id("tab-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the tab picked")
        app.press(.id("session-\(second.id)"))
        app.waitForKeyboard(in: "terminal-\(second.id)", "the session picked in the list")
        app.press(.id("session-\(first.id)"))
        app.waitForKeyboard(in: "terminal-\(first.id)", "the session picked in the list")
        XCTAssertEqual(app.selectedRows(), ["session-\(first.id)"])
    }
}
