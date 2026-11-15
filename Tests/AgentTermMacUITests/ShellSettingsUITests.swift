import AgentTermProtocol
import XCTest

/// Settings > Shell (SHELL-4 in docs/TESTING.md).
final class ShellSettingsUITests: MacUITestCase {
    /// SHELL-4: the shells' switches are in Settings > Shell, not General;
    /// what is run first is saved to the host; the terminal's size is set
    /// there.
    func testTheShellsSettings() throws {
        let phone = try device()
        app.press(.id("place-settings"))
        app.press(.id("settings-general"))
        app.wait(for: .id("menu-bar"))
        for id in ["agent-shells", "agents-use-shells", "shell-marks"] {
            XCTAssertFalse(app.exists(.id(id)), "\(id) is still in General")
        }
        app.press(.id("settings-shell"))
        app.wait(for: .id("shell-program"))
        // The switches of the agents' shells are there when the host has
        // AgentTerm's MCP server set up, which the host of the tests does
        // not; the marks' switch is always there.
        for id in ["shell-marks", "terminal-font", "terminal-cursor", "terminal-scrollback"] {
            app.wait(for: .id(id))
        }
        app.write("export FROM_SETTINGS=1", into: .id("shell-startup"))
        app.press(.id("shell-startup-save"))
        wait("the host to keep it") {
            phone.messages.contains { if case .shellSettings(let settings, _, _) = $0 { return settings.startup == "export FROM_SETTINGS=1" } else { return false } }
        }
        let size = app.value(of: .id("terminal-font-size")) ?? app.first(.id("terminal-font-size"))?.text
        app.press(.button("Larger"))
        app.wait("the size to change from \(size ?? "")") {
            (self.app.value(of: .id("terminal-font-size")) ?? self.app.first(.id("terminal-font-size"))?.text) != size
        }
        shot("shell-settings")
    }
}
