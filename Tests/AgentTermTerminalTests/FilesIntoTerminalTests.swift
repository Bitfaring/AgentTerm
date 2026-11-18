#if os(macOS)
import AppKit
import SwiftTerm
import XCTest

@testable import AgentTermTerminal

/// SES-28 (#160): what a terminal of the Mac takes of files: their paths,
/// quoted for the shell as Terminal.app quotes them; a picture is left to
/// the agent, which takes it from the clipboard on Control V.
@MainActor
final class FilesIntoTerminalTests: XCTestCase {
    func testAPathIsQuotedOnlyWhenTheShellNeedsIt() {
        XCTAssertEqual(FileTakingTerminalView.quoted("/Users/me/Desktop/shot.png"), "/Users/me/Desktop/shot.png")
        XCTAssertEqual(FileTakingTerminalView.quoted("/Users/me/Desktop/Screenshot 2026-11-18 at 9.41.00 PM.png"), "'/Users/me/Desktop/Screenshot 2026-11-18 at 9.41.00 PM.png'")
        XCTAssertEqual(FileTakingTerminalView.quoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }

    /// The Finder's files, read from a pasteboard of the test's own: the
    /// user's clipboard is not touched (rule 3).
    func testTheFilesOfAPasteboardAreRead() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("agentterm-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertEqual(FileTakingTerminalView.fileURLs(on: board), [])
        let files = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b c.txt")]
        board.writeObjects(files as [NSURL])
        XCTAssertEqual(FileTakingTerminalView.fileURLs(on: board).map(\.path), ["/tmp/a.png", "/tmp/b c.txt"])
    }

    /// The Mac's terminal is the one that takes them, and registers for files dropped on it.
    func testTheMacsTerminalTakesFiles() {
        let controller = TerminalController(session: 1)
        let view = controller.view as? FileTakingTerminalView
        XCTAssertNotNil(view, "the Mac's terminal is not the one that takes files")
        XCTAssertTrue(view?.registeredDraggedTypes.contains(.fileURL) ?? false, "files dropped on it are not taken")
    }
}
#endif
