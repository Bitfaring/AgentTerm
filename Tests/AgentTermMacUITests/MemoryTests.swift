import AgentTermProtocol
import XCTest

/// The agents' memory (#220), what each saved by itself: every one on the
/// Mac in Memory, the folder's in the side panel, read, previewed as
/// Markdown, changed and deleted. An agent's instructions are not listed.
final class MemoryTests: MacUITestCase {
    /// What Claude Code writes by itself for the project, under the home.
    private var notes: URL {
        home.appendingPathComponent(".claude/projects/" + project.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() + "/memory")
    }

    /// A folder the app does not list, with a conversation that names it
    /// and a note Claude Code saved about it.
    private var elsewhere: URL { root.appendingPathComponent("never-listed") }
    private var notesElsewhere: URL {
        home.appendingPathComponent(".claude/projects/" + elsewhere.path.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())
    }

    private let index = "# Memory\n\n- [The tests](tests.md) — run them first\n"

    /// A note as Claude Code writes one: a front matter block, then Markdown.
    private let note = """
        ---
        name: tests
        description: "Run the tests before a commit"
        metadata:
          node_type: memory
          type: feedback
          originSessionId: 4f5c98ec-0000-4000-8000-000000000000
          modified: 2026-11-21T07:34:04.692Z
        ---

        - **Be brief**
        - then run `swift test`, see [[another-note]]

        """

    /// The project's instructions, the user's own, and what Claude Code
    /// saved for the project: only the last are memories.
    override func beforeTheHostStarts() throws {
        try write("# Rules\n", to: "CLAUDE.md")
        try write("# For every agent\n", to: "AGENTS.md")
        try write("# Mine\n", to: ".claude/CLAUDE.md", in: home)
        try write(index, to: "MEMORY.md", in: notes)
        try write(note, to: "tests.md", in: notes)
        try write("Deploys on Fridays.\n", to: "deploys.md", in: notesElsewhere.appendingPathComponent("memory"))
        try write(#"{"type":"user","cwd":"\#(elsewhere.path)","message":{"role":"user","content":"deploy it"}}"# + "\n", to: "c-9.jsonl", in: notesElsewhere)
    }

    /// MEM-8: the side panel's Memory lists what the agents saved about the
    /// folder on show only, under their agent, not the instructions
    /// written for them, and nothing is said under the rows; one picked
    /// opens over Sessions.
    func testTheSidePanelListsWhatTheAgentsSavedAboutTheFolder() throws {
        app.press(.id("panel-memory"))
        app.wait(for: .id("memory-MEMORY.md"), timeout: 20)
        app.wait(for: .id("memory-tests.md"))
        app.wait(for: .text("2 memories"))
        // Grouped by agent, as History is.
        app.wait(for: .text("Claude Code, 2 memories, expanded"))
        // Instructions written for the agents are not memories.
        XCTAssertFalse(app.exists(.id("memory-CLAUDE.md")))
        XCTAssertFalse(app.exists(.id("memory-AGENTS.md")))
        XCTAssertFalse(app.exists(.id("memory-~/.claude/CLAUDE.md")))
        XCTAssertFalse(app.exists(.id("memory-notes.txt")))
        // Another folder's memory is not this folder's.
        XCTAssertFalse(app.exists(.id("memory-deploys.md")))
        // Nothing is explained under a list that has rows.
        XCTAssertFalse(app.exists(.containing("What Codex saves by itself")))
        XCTAssertFalse(app.exists(.containing("Not shown")))
        XCTAssertFalse(app.exists(.containing("An agent's instructions")))
        shot("memory-panel")

        // Picked: whole, over Sessions, with where it is.
        app.press(.id("memory-tests.md"))
        app.wait(for: .id("memory-save"), timeout: 15)
        app.wait(for: .containing("/memory/tests.md"))
        shot("memory-sheet")

        // Changed there too, as text, in the same editor as in Memory's middle, and saved.
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the note's text in the sheet's editor") { self.app.value(of: editor) == self.note }
        let file = notes.appendingPathComponent("tests.md")
        let changed = note + "- Be kind\n"
        app.write(changed, into: editor)
        app.wait(for: .id("memory-unsaved"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), note, "written before Save")
        app.press(.id("memory-save"))
        wait("the change written to the file") { (try? String(contentsOf: file, encoding: .utf8)) == changed }
        app.waitGone(.id("memory-unsaved"))

        // In the preview nothing is typed, and nothing suggests it: no editor, no Save.
        app.press(.button(ConversationDetails.previewMarkdown))
        app.wait(for: .id("memory-preview"))
        XCTAssertFalse(app.exists(.id("memory-text")))
        XCTAssertFalse(app.exists(editor), "the preview has an editor")
        XCTAssertFalse(app.exists(.id("memory-save")), "Save is offered where nothing can be changed")
        app.wait(for: .text(MemoryWords.changeAsText))
        app.wait(for: .containing("Be kind"))
        app.press(.button(ConversationDetails.showAsText))
        wait("the editor again, with what was saved") { self.app.value(of: editor) == changed }
        app.wait(for: .id("memory-save"))

        app.press(.button("Close"))
        app.waitGone(.id("memory-save"))
    }

    /// MEM-9: in Memory, every memory on the Mac, of a folder the app does
    /// not list too, each row naming its folder; one is opened, previewed as Markdown, changed and saved
    /// to the file its agent reads, and deleted after the question, to the
    /// Trash. The project's instructions are as they were.
    func testAMemoryIsReadPreviewedChangedAndDeleted() throws {
        app.press(.id("place-memory"))
        app.wait(for: .id("memory-tests.md"), timeout: 20)
        app.wait(for: .text("Claude Code, 3 memories, expanded"))
        // Each row says which folder it is about: one of a folder the app does not list too.
        app.wait(for: .text("tests.md, project"))
        app.wait(for: .text("deploys.md, never-listed"))
        XCTAssertFalse(app.exists(.containing("What Codex saves by itself")))
        XCTAssertFalse(app.exists(.containing("Not shown")))
        app.wait(for: .text(MemoryWords.choose))
        XCTAssertFalse(app.exists(.id("memory-CLAUDE.md")))

        // Read: as it is written, in the app's editor.
        app.press(.id("memory-tests.md"))
        let editor = MacDriver.Query.role(kAXTextAreaRole as String)
        wait("the memory's text") { self.app.value(of: editor) == self.note }
        XCTAssertFalse(app.exists(.id("memory-preview")))
        shot("memory")

        // Previewed, in History's words for the two.
        app.press(.button(ConversationDetails.previewMarkdown))
        app.wait(for: .id("memory-preview"))
        app.wait(for: .button(ConversationDetails.showAsText))
        XCTAssertFalse(app.exists(.containing("**Be brief**")), "the Markdown is not rendered")
        app.wait(for: .containing("Be brief"))
        // Its front matter is not drawn as text: what it is about, its type, and not its ids.
        app.wait(for: .text("Run the tests before a commit"))
        app.wait(for: .text("feedback"))
        XCTAssertFalse(app.exists(.containing("originSessionId")), "the front matter's ids are shown")
        XCTAssertFalse(app.exists(.containing("name:")), "the front matter is drawn as text")
        XCTAssertFalse(app.exists(.containing("node_type")))
        // Nothing is changed in the preview: no editor, no Save.
        XCTAssertFalse(app.exists(editor), "the preview has an editor")
        XCTAssertFalse(app.exists(.id("memory-save")), "Save is offered where nothing can be changed")
        shot("memory-markdown")
        app.press(.button(ConversationDetails.showAsText))
        wait("the editor again") { self.app.value(of: editor) == self.note }
        // As it is written, front matter included: that is what is changed and saved.
        XCTAssertTrue(app.value(of: editor)?.hasPrefix("---\nname: tests\n") == true)
        XCTAssertTrue(app.value(of: editor)?.contains("originSessionId") == true)

        // Changed: nothing is written before Save.
        let file = notes.appendingPathComponent("tests.md")
        let changed = note + "- Be kind\n"
        app.write(changed, into: editor)
        app.wait(for: .id("memory-unsaved"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), note)
        app.press(.id("memory-save"))
        wait("the change written to the file") { (try? String(contentsOf: file, encoding: .utf8)) == changed }
        app.waitGone(.id("memory-unsaved"))

        // Deleted: asked first, saying whose it is and where it goes.
        app.press(.id("memory-delete"))
        app.wait(for: .containing("Delete “tests.md”?"))
        app.wait(for: .containing("Claude Code saved it about “project”"))
        app.wait(for: .containing("moved to the Trash"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        app.press(.button("Delete Memory"))
        app.waitGone(.id("memory-tests.md"), timeout: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let trash = home.appendingPathComponent(".Trash-of-the-tests")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["tests.md"])
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("tests.md"), encoding: .utf8), changed)
        // The other stays, and so do the instructions.
        app.wait(for: .id("memory-MEMORY.md"))
        app.wait(for: .id("memory-deploys.md"))
        app.wait(for: .text("Claude Code, 2 memories, expanded"))
        app.wait(for: .text(MemoryWords.choose))
        XCTAssertEqual(read("CLAUDE.md"), "# Rules\n")
        XCTAssertEqual(read("AGENTS.md"), "# For every agent\n")
    }
}

/// MEM-10 (#220): with no memory, each list says one short line, as
/// History's do, and nothing else.
final class NoMemoryTests: MacUITestCase {
    /// Instructions only: none of them is a memory.
    override func beforeTheHostStarts() throws {
        try write("# Rules\n", to: "CLAUDE.md")
        try write("# Mine\n", to: ".claude/CLAUDE.md", in: home)
    }

    func testAListWithNoMemorySaysOneShortLine() throws {
        app.press(.id("panel-memory"))
        app.wait(for: .text(MemoryWords.noneInFolder), timeout: 20)
        app.wait(for: .text("0 memories"))
        XCTAssertFalse(app.exists(.containing("What Codex saves by itself")))
        XCTAssertFalse(app.exists(.containing("Not shown")))
        XCTAssertFalse(app.exists(.id("memory-CLAUDE.md")))
        shot("memory-none")

        app.press(.id("place-memory"))
        app.wait(for: .text(MemoryWords.noneAnywhere), timeout: 20)
        XCTAssertFalse(app.exists(.containing("What Codex saves by itself")))
        XCTAssertFalse(app.exists(.containing("Not shown")))
    }
}
