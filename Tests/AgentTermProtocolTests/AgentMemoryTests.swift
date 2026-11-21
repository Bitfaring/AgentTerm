import AgentTermProtocol
import XCTest

/// MEM-7 (#220): how the agents' memories are grouped in the lists, the
/// words both apps say about them, and the messages that carry them.
final class AgentMemoryTests: XCTestCase {
    private let names: [(id: String, name: String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("agy", "Antigravity"), ("copilot", "Copilot CLI")]

    private func memory(_ name: String, _ agent: String = "claude", folder: String? = "/Users/me/Dev/app", project: String = "-Users-me-Dev-app") -> AgentMemory {
        AgentMemory(
            path: "/Users/me/.\(agent)/" + project + "/" + name, name: name, agent: agent, folder: folder, project: project,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25), size: 12)
    }

    /// As History groups its conversations: by agent, in the agents' order.
    func testMemoriesAreGroupedByAgentInTheAgentsOrder() {
        let site = "/Users/me/Dev/site"
        let list = [memory("MEMORY.md"), memory("notes.md", "codex"), memory("feedback.md"), memory("MEMORY.md", folder: site, project: "-Users-me-Dev-site"), memory("x.md", "other")]
        let groups = AgentMemory.groups(list, agentNames: names)
        XCTAssertEqual(groups.map(\.title), ["Claude Code", "Codex", "other"])
        XCTAssertEqual(groups.map(\.id), ["agent:claude", "agent:codex", "agent:other"])
        // Each group's as the host listed them: a folder's together, its index first.
        XCTAssertEqual(groups.first?.memories.map { MemoryWords.folder(of: $0) + "/" + $0.name }, ["app/MEMORY.md", "app/feedback.md", "site/MEMORY.md"])
        // An agent with none has no group.
        XCTAssertEqual(AgentMemory.groups([], agentNames: names), [])
    }

    func testTheWordsCountAndSize() {
        XCTAssertEqual(MemoryWords.count(1), "1 memory")
        XCTAssertEqual(MemoryWords.count(4), "4 memories")
        XCTAssertEqual(MemoryWords.size(1), "1 byte")
        XCTAssertEqual(MemoryWords.size(340), "340 bytes")
        XCTAssertEqual(MemoryWords.size(1536), "1.5 KB")
        XCTAssertTrue(MemoryWords.changedMeanwhile("MEMORY.md").contains("nothing was written"))
        // A row's folder: its name, or that it is not known, with what its agent calls it.
        XCTAssertEqual(MemoryWords.folder(of: memory("MEMORY.md")), "app")
        XCTAssertEqual(MemoryWords.folder(of: memory("MEMORY.md", folder: nil, project: "-Users-me-x-y")), "Folder not known: -Users-me-x-y")
        // The empty lists say one short line, as History's do.
        XCTAssertEqual(MemoryWords.noneAnywhere, "No agent has saved a memory on this Mac yet.")
        XCTAssertEqual(MemoryWords.noneInFolder, "No agent has saved a memory of this folder yet.")
    }

    /// The question before a memory is deleted says whose it is, of which
    /// folder, and where it goes; of one whose folder is not known, that.
    func testTheQuestionBeforeDeleting() {
        let question = DeleteMemoryQuestion(memory("feedback.md"), agentName: "Claude Code")
        XCTAssertEqual(question.title, "Delete “feedback.md”?")
        XCTAssertEqual(
            question.message, "Claude Code saved it about “app”, and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back.")
        XCTAssertEqual(question.confirm, "Delete Memory")
        let unknown = DeleteMemoryQuestion(memory("MEMORY.md", folder: nil, project: "-Users-me-x-y"), agentName: "Claude Code")
        XCTAssertEqual(
            unknown.message,
            "Claude Code saved it about a folder that is not known (-Users-me-x-y), and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back."
        )
    }

    /// MEM-12: a note's front matter is taken apart from its body, by
    /// lines and leniently; a text with none is all body.
    func testANotesFrontMatterIsTakenApartFromItsBody() throws {
        let note = """
            ---
            name: no-tests-while-talking
            description: "One line that says what the note is about"
            metadata:
              node_type: memory
              type: feedback
              originSessionId: 4f5c98ec-0000
              modified: 2026-11-21T07:34:04.692Z
            ---

            Body in Markdown, with **bold**, and [[another-note]].

            ---

            After a rule.
            """
        let parts = MemoryText(note)
        XCTAssertTrue(parts.hasFrontMatter)
        XCTAssertEqual(parts.description, "One line that says what the note is about")
        XCTAssertEqual(parts.name, "no-tests-while-talking")
        XCTAssertEqual(parts.type, "feedback")
        XCTAssertEqual(try XCTUnwrap(parts.modified).timeIntervalSince1970, 1_795_246_444.692, accuracy: 0.001)
        // Only the body, its own rule untouched, and `[[…]]` left as text.
        XCTAssertEqual(parts.body, "\nBody in Markdown, with **bold**, and [[another-note]].\n\n---\n\nAfter a rule.")
        // The facts: type and date; the name only when it is not the file's; never the ids.
        let changed = try XCTUnwrap(parts.modified).formatted(date: .abbreviated, time: .shortened)
        XCTAssertEqual(parts.facts(fileName: "no-tests-while-talking.md").map { $0.name + "=" + $0.value }, ["Type=feedback", "Changed=" + changed])
        XCTAssertEqual(parts.facts(fileName: "other.md").map(\.name), ["Name", "Type", "Changed"])
        XCTAssertFalse(parts.facts(fileName: "other.md").contains { $0.value.contains("4f5c98ec") || $0.value == "memory" })

        // No front matter, as the index has: all body, no facts.
        let index = "- [Tests](tests.md) — run them first\n- [Style](style.md)\n"
        XCTAssertEqual(MemoryText(index).body, index)
        XCTAssertFalse(MemoryText(index).hasFrontMatter)
        XCTAssertTrue(MemoryText(index).facts(fileName: "MEMORY.md").isEmpty)
        XCTAssertNil(MemoryText(index).description)
        // An opening that is never closed is no front matter; nor is `---` further down, or a longer line.
        let unclosed = "---\nname: x\ndescription: y\n\nBody"
        XCTAssertEqual(MemoryText(unclosed).body, unclosed)
        XCTAssertNil(MemoryText(unclosed).description)
        let rule = "Title\n\n---\n\nname: x\n\n---\n"
        XCTAssertEqual(MemoryText(rule).body, rule)
        XCTAssertNil(MemoryText(rule).name)
        XCTAssertEqual(MemoryText("----\nname: x\n---\nBody").body, "----\nname: x\n---\nBody")
        // Quoted either way, or not; a top-level type and date; lines it cannot read are left out.
        let loose = MemoryText("---\ndescription: 'single: with a colon'\ntype: project\nmodified: 2026-11-21T07:34:04Z\nnot a pair\n- a list item\nname:\n---\nBody")
        XCTAssertEqual(loose.description, "single: with a colon")
        XCTAssertEqual(loose.type, "project")
        XCTAssertEqual(loose.modified, Date(timeIntervalSince1970: 1_795_246_444))
        XCTAssertNil(loose.name)
        XCTAssertEqual(loose.body, "Body")
        XCTAssertEqual(MemoryText("---\ndescription: plain words\nmodified: last week\n---\n").description, "plain words")
        XCTAssertNil(MemoryText("---\nmodified: last week\n---\n").modified, "a date it cannot read is left out")
        // `metadata.type` before a top-level one; what is indented under another key is not metadata's.
        XCTAssertEqual(MemoryText("---\ntype: top\nmetadata:\n  type: inner\n---\n").type, "inner")
        XCTAssertNil(MemoryText("---\nother:\n  type: not-this\n---\n").type)
        // Windows line ends.
        let windows = MemoryText("---\r\nname: n\r\ndescription: \"d\"\r\nmetadata:\r\n  type: user\r\n---\r\nBody\r\nmore\r\n")
        XCTAssertEqual(windows.description, "d")
        XCTAssertEqual(windows.type, "user")
        XCTAssertEqual(windows.body, "Body\nmore\n")
        // An empty front matter: taken off, with nothing to show.
        let empty = MemoryText("---\n---\nBody")
        XCTAssertEqual(empty.body, "Body")
        XCTAssertTrue(empty.hasFrontMatter)
        XCTAssertTrue(empty.facts(fileName: "x.md").isEmpty)
        XCTAssertNil(empty.description)
        XCTAssertEqual(MemoryText("").body, "")
    }

    /// The messages are of protocol 38: a host of an earlier release is not
    /// sent them (#214), and they are read back as they were written.
    func testTheMessagesAreOfProtocol38AndAreReadBack() throws {
        XCTAssertGreaterThanOrEqual(agenttermProtocolVersion, 38)
        let seen = Date(timeIntervalSince1970: 1_800_000_000.25)
        let one = memory("MEMORY.md")
        let asked: [ClientMessage] = [
            .memories(path: nil), .memories(path: one.folder), .readMemory(path: one.path),
            .writeMemory(path: one.path, text: "# Notes\n", seen: seen), .deleteMemory(path: one.path),
        ]
        for message in asked {
            XCTAssertEqual(message.since, 38, "\(message)")
            XCTAssertFalse(message.isKnown(toHostAt: 37))
            XCTAssertTrue(message.isKnown(toHostAt: 38))
            XCTAssertEqual(MessageCoding.decode(ClientMessage.self, from: MessageCoding.encode(message)), message)
        }
        let answered: [ServerMessage] = [
            .memories(path: nil, list: [one, memory("MEMORY.md", folder: nil, project: "-Users-me-Dev-site")]),
            .memoryRead(path: one.path, content: AgentMemoryContent(memory: one, text: "# Notes\n"), problem: nil),
            .memoryRead(path: "/Users/me/Dev/app/CLAUDE.md", content: nil, problem: MemoryWords.notAMemory), .memorySaved(one), .memoryDeleted(path: one.path),
            .memoryRefused(path: one.path, problem: MemoryWords.changedMeanwhile(one.name)),
        ]
        for message in answered {
            XCTAssertEqual(MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(message)), message)
        }
        // The date a change is sent back with is the one that was read.
        guard case .memorySaved(let back)? = MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(ServerMessage.memorySaved(one))) else {
            return XCTFail("not read back")
        }
        XCTAssertEqual(back.modifiedAt.timeIntervalSince1970, one.modifiedAt.timeIntervalSince1970, accuracy: 0.0005)
    }
}
