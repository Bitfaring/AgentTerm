import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What a shell says of its commands (OSC 133), as the host reads it for
/// `shell_run`: MCP-27 to MCP-29 in docs/TESTING.md.
final class ShellCommandsTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// MCP-27: the marks are found whole, ended either way, also when the
    /// output cuts one in two; other strings are not taken for them.
    func testTheMarksAreFoundInOutputAsItComes() {
        var marks = CommandMarks()
        let first = bytes("$ ls\r\n\u{1b}]133;C\u{07}a b\r\n\u{1b}]0;title\u{07}\u{1b}]133;D;")
        let found = marks.scan(first)
        XCTAssertEqual(found.map(\.kind), ["C"])
        XCTAssertEqual(found.first?.end, 14)
        let second = marks.scan(bytes("2\u{1b}\\\u{1b}]133;A\u{07}$ "))
        XCTAssertEqual(second.map(\.kind), ["D", "A"])
        XCTAssertEqual(second.first?.parameter, "2")
        XCTAssertEqual(second.first?.end, 3)
        XCTAssertTrue(marks.scan(bytes("plain text, no escape")).isEmpty)
        XCTAssertTrue(marks.scan(bytes("\u{1b}]1337;File=" + String(repeating: "x", count: 200) + "\u{07}")).isEmpty)
    }

    /// MCP-28: a command's output is what it wrote, drawn as a terminal
    /// shows it, and its exit code is kept once it ends.
    func testACommandsOutputAndExitCode() {
        let mirror = ScreenMirror(size: TermSize(cols: 40, rows: 5), scrollback: 100)
        mirror.feed(Data("\u{1b}]133;A\u{07}$ make\r\n".utf8))
        XCTAssertEqual(mirror.commands, AgentCommand(integrated: true))
        mirror.feed(Data("\u{1b}]133;C\u{07}building\r\n50%\r100%\r\n".utf8))
        var state = mirror.command(lines: 10)
        XCTAssertTrue(state.running)
        XCTAssertEqual(state.started, 1)
        XCTAssertEqual(state.output, "building\n100%")
        // More lines than the screen has rows, and the mark cut in two.
        mirror.feed(Data((1...8).map { "line \($0)\r\n" }.joined().utf8) + Data("\u{1b}]13".utf8))
        mirror.feed(Data("3;D;2\u{07}\u{1b}]133;A\u{07}$ ".utf8))
        state = mirror.command(lines: 3)
        XCTAssertFalse(state.running)
        XCTAssertEqual(state.exitCode, 2)
        XCTAssertEqual(state.output, "line 6\nline 7\nline 8")
        XCTAssertEqual(state.linesLeftOut, 7)
        // The prompt that follows is not the command's.
        XCTAssertFalse(mirror.command(lines: 100).output.contains("$"))
        // The next one starts afresh.
        mirror.feed(Data("ls\r\n\u{1b}]133;C\u{07}".utf8))
        state = mirror.command(lines: 10)
        XCTAssertEqual(state.started, 2)
        XCTAssertNil(state.exitCode)
        XCTAssertEqual(state.output, "")
    }

    /// MCP-29: the tools say which only look, and which one ends something.
    func testTheToolsSayWhatTheyDo() {
        let tools = AgentShellsMCP.tools + AgentShellsMCP.browserTools
        func annotations(_ name: String) -> [String: Any] {
            tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any] ?? [:]
        }
        for name in ["shell_list", "shell_read", "shell_wait", "browser_tabs", "browser_snapshot", "browser_screenshot", "browser_console"] {
            XCTAssertEqual(annotations(name)["readOnlyHint"] as? Bool, true, name)
        }
        for name in ["shell_run", "shell_send", "browser_click"] {
            XCTAssertEqual(annotations(name)["readOnlyHint"] as? Bool, false, name)
        }
        XCTAssertEqual(annotations("shell_close")["destructiveHint"] as? Bool, true)
        XCTAssertEqual(annotations("browser_close")["destructiveHint"] as? Bool, true)
        XCTAssertTrue(AgentShellsMCP.tools.allSatisfy { ($0["name"] as? String)?.hasPrefix("shell_") == true })
    }
}
