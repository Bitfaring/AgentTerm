import AgentTermProtocol
import XCTest

/// The agents' memory (#220): listed in the side panel and in Memory, read,
/// previewed as Markdown, changed and deleted.
final class MemoryTests: MacUITestCase {
    /// What Claude Code writes by itself for the project, under the home.
    private var notes: URL {
        home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + "/memory")
    }

    private let rules = "# Rules\n\n- **Be brief**\n- then `swift test`\n"

    /// The project's memories, the user's own, and a file no agent reads.
    override func beforeTheHostStarts() throws {
        try write(rules, to: "CLAUDE.md")
        try write("# For every agent\n", to: "AGENTS.md")
        try write("# Mine\n", to: ".claude/CLAUDE.md", in: home)
        try write("- [Tests](tests.md)\n", to: "MEMORY.md", in: notes)
    }

    /// MEM-9: the side panel's Memory lists the folder's memories and the
    /// user's own as two groups, each naming the agents that read it, and
    /// says what is not shown; one picked opens over Sessions.
    func testTheSidePanelListsTheFoldersMemoriesAndTheUsersOwn() throws {
        app.press(.id("panel-memory"))
        app.wait(for: .id("memory-CLAUDE.md"), timeout: 20)
        app.wait(for: .id("memory-AGENTS.md"))
        app.wait(for: .id("memory-memory/MEMORY.md"))
        app.wait(for: .id("memory-~/.claude/CLAUDE.md"))
        app.wait(for: .text("4 memories"))
        // Two groups: the folder's, then the user's own.
        app.wait(for: .text("\(MemoryWords.thisFolder), 3 memories, expanded"))
        app.wait(for: .text("\(MemoryWords.yours), 1 memory, expanded"))
        // Each says who reads it: one file read by several agents is one row.
        XCTAssertTrue(try XCTUnwrap(app.first(.id("memory-AGENTS.md"))).label.contains("Read by Codex, Antigravity and Copilot CLI"))
        XCTAssertTrue(try XCTUnwrap(app.first(.id("memory-CLAUDE.md"))).label.contains("Read by Claude Code and Copilot CLI"))
        // A file no agent is known to read is not a memory.
        XCTAssertFalse(app.exists(.id("memory-notes.txt")))
        XCTAssertFalse(app.exists(.id("memory-docs/guide.md")))
        // An agent whose memory is not known is said to be so.
        app.wait(for: .containing("What Codex saves by itself is not known"))
        shot("memory-panel")

        // Picked: whole, over Sessions, with where it is.
        app.press(.id("memory-memory/MEMORY.md"))
        app.wait(for: .id("memory-save"), timeout: 15)
        app.wait(for: .containing("Written by Claude Code itself"))
        app.wait(for: .containing("/memory/MEMORY.md"))
        shot("memory-sheet")
        app.press(.button("Close"))
        app.waitGone(.id("memory-save"))
    }

    /// MEM-10: in Memory, every listed folder's memories and the user's
    /// own; one is opened, previewed as Markdown, changed and saved to the
    /// file its agents read, and deleted after the question, to the Trash.
    func testAMemoryIsReadPreviewedChangedAndDeleted() throws {
        app.press(.id("place-memory"))
        app.wait(for: .id("memory-CLAUDE.md"), timeout: 20)
        // Each folder a group under its name, then the user's own.
        app.wait(for: .text("project, 3 memories, expanded"))
        app.wait(for: .text("\(MemoryWords.yours), 1 memory, expanded"))
        app.wait(for: .text(MemoryWords.choose))

        // Read: as it is written, in the app's editor.
        app.press(.id("memory-CLAUDE.md"))
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the memory's text") { self.app.value(of: editor) == self.rules }
        app.wait(for: .containing("Read by Claude Code and Copilot CLI"))
        XCTAssertFalse(app.exists(.id("memory-preview")))
        shot("memory")

        // Previewed, in History's words for the two.
        app.press(.button(ConversationDetails.previewMarkdown))
        app.wait(for: .id("memory-preview"))
        app.wait(for: .button(ConversationDetails.showAsText))
        XCTAssertFalse(app.exists(.containing("**Be brief**")), "the Markdown is not rendered")
        app.wait(for: .containing("Be brief"))
        shot("memory-markdown")
        app.press(.button(ConversationDetails.showAsText))
        wait("the editor again") { self.app.value(of: editor) == self.rules }

        // Changed: nothing is written before Save.
        let changed = rules + "- Be kind\n"
        app.write(changed, into: editor)
        app.wait(for: .id("memory-unsaved"))
        XCTAssertEqual(read("CLAUDE.md"), rules)
        app.press(.id("memory-save"))
        wait("the change written to the file") { self.read("CLAUDE.md") == changed }
        app.waitGone(.id("memory-unsaved"))

        // Deleted: asked first, saying where it goes and who reads it.
        app.press(.id("memory-delete"))
        app.wait(for: .containing("Delete “CLAUDE.md”?"))
        app.wait(for: .containing("Claude Code and Copilot CLI read it"))
        app.wait(for: .containing("moved to the Trash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("CLAUDE.md").path))
        app.press(.button("Delete Memory"))
        app.waitGone(.id("memory-CLAUDE.md"), timeout: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("CLAUDE.md").path))
        let trash = home.appendingPathComponent(".Trash-of-the-tests")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["CLAUDE.md"])
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("CLAUDE.md"), encoding: .utf8), changed)
        // The others stay.
        app.wait(for: .id("memory-AGENTS.md"))
        app.wait(for: .text("project, 2 memories, expanded"))
        app.wait(for: .text(MemoryWords.choose))
    }
}
