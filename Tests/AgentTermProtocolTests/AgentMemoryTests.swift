import AgentTermProtocol
import XCTest

/// MEM-8 (#220): how the agents' memories are grouped in the two lists,
/// the words both apps say about them, and the messages that carry them.
final class AgentMemoryTests: XCTestCase {
    private let names: [(id: String, name: String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("agy", "Antigravity"), ("copilot", "Copilot CLI")]

    private func memory(_ name: String, _ agents: [String], folder: String? = nil, writtenByAgent: Bool = false) -> AgentMemory {
        AgentMemory(
            path: (folder ?? "/Users/me") + "/" + name, name: name, agents: agents, scope: folder == nil ? .user : .folder, folder: folder,
            writtenByAgent: writtenByAgent, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000.25), size: 12)
    }

    func testTheFoldersAndTheUsersOwnAreTwoGroups() {
        let app = "/Users/me/Dev/app"
        let list = [memory("CLAUDE.md", ["claude"], folder: app), memory("AGENTS.md", ["codex"], folder: app), memory("~/.claude/CLAUDE.md", ["claude"])]
        let groups = AgentMemory.groups(list, ofFolder: app)
        XCTAssertEqual(groups.map(\.title), ["This Folder", "Yours, for Every Folder"])
        XCTAssertEqual(groups.map(\.id), ["folder:" + app, AgentMemory.userGroup])
        XCTAssertEqual(groups.map { $0.memories.map(\.name) }, [["CLAUDE.md", "AGENTS.md"], ["~/.claude/CLAUDE.md"]])
        // A group with none is left out; another folder's are not this folder's.
        XCTAssertEqual(AgentMemory.groups([list[2]], ofFolder: app).map(\.title), ["Yours, for Every Folder"])
        XCTAssertEqual(AgentMemory.groups(list, ofFolder: "/Users/me/Dev/other").map(\.title), ["Yours, for Every Folder"])
        XCTAssertEqual(AgentMemory.groups([], ofFolder: app), [])
    }

    func testEveryFoldersAreGroupedByFolderInTheFoldersOrderThenTheUsersOwn() {
        let app = "/Users/me/Dev/app"
        let site = "/Users/me/Dev/site"
        let gone = "/Users/me/Dev/gone"
        let list = [
            memory("~/.codex/AGENTS.md", ["codex"]), memory("AGENTS.md", ["codex"], folder: gone), memory("CLAUDE.md", ["claude"], folder: app),
            memory("GEMINI.md", ["agy"], folder: site), memory("AGENTS.md", ["codex"], folder: app),
        ]
        let groups = AgentMemory.groups(list, folders: [site, "/Users/me/Dev/empty", app])
        XCTAssertEqual(groups.map(\.title), ["site", "app", "gone", "Yours, for Every Folder"])
        XCTAssertEqual(groups.map { $0.memories.map(\.name) }, [["GEMINI.md"], ["CLAUDE.md", "AGENTS.md"], ["AGENTS.md"], ["~/.codex/AGENTS.md"]])
        XCTAssertEqual(groups.last?.id, AgentMemory.userGroup)
    }

    func testTheWordsNameEveryAgentThatReadsAMemory() {
        let one = memory("CLAUDE.local.md", ["claude"], folder: "/p")
        let two = memory("GEMINI.md", ["agy", "copilot"], folder: "/p")
        let three = memory("AGENTS.md", ["codex", "agy", "copilot"], folder: "/p")
        XCTAssertEqual(MemoryWords.readers(of: one, agentNames: names), "Read by Claude Code")
        XCTAssertEqual(MemoryWords.readers(of: two, agentNames: names), "Read by Antigravity and Copilot CLI")
        XCTAssertEqual(MemoryWords.readers(of: three, agentNames: names), "Read by Codex, Antigravity and Copilot CLI")
        // An agent this build has no name for is called by its id.
        XCTAssertEqual(MemoryWords.readers(of: memory("X.md", ["other"], folder: "/p"), agentNames: names), "Read by other")
        XCTAssertNil(MemoryWords.writer(of: one, agentNames: names))
        XCTAssertEqual(MemoryWords.writer(of: memory("memory/MEMORY.md", ["claude"], folder: "/p", writtenByAgent: true), agentNames: names), "Written by Claude Code itself")
        XCTAssertEqual(MemoryWords.count(1), "1 memory")
        XCTAssertEqual(MemoryWords.count(4), "4 memories")
        XCTAssertEqual(MemoryWords.size(1), "1 byte")
        XCTAssertEqual(MemoryWords.size(340), "340 bytes")
        XCTAssertEqual(MemoryWords.size(1536), "1.5 KB")
    }

    /// The question before a memory is deleted says where it goes and who
    /// reads it; what is not shown is said for each agent it is true of.
    func testTheQuestionBeforeDeletingAndWhatIsNotShown() {
        let question = DeleteMemoryQuestion(memory("AGENTS.md", ["codex", "copilot"], folder: "/p"), agentNames: names)
        XCTAssertEqual(question.title, "Delete “AGENTS.md”?")
        XCTAssertEqual(
            question.message, "Codex and Copilot CLI read it, and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back.")
        XCTAssertEqual(question.confirm, "Delete Memory")
        let own = DeleteMemoryQuestion(memory("~/.claude/CLAUDE.md", ["claude"]), agentNames: names)
        XCTAssertEqual(
            own.message, "Claude Code reads it in every folder, and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back.")

        XCTAssertEqual(MemoryWords.notShown.map(\.agent), ["codex", "agy", "copilot", nil])
        XCTAssertTrue(MemoryWords.notShown.allSatisfy { $0.text.contains("not ") })
        XCTAssertTrue(MemoryWords.changedMeanwhile("CLAUDE.md").contains("nothing was written"))
    }

    /// The messages are of protocol 38: a host of an earlier release is not
    /// sent them (#214), and they are read back as they were written.
    func testTheMessagesAreOfProtocol38AndAreReadBack() throws {
        XCTAssertGreaterThanOrEqual(agenttermProtocolVersion, 38)
        let seen = Date(timeIntervalSince1970: 1_800_000_000.25)
        let asked: [ClientMessage] = [
            .memories(path: nil), .memories(path: "/p"), .readMemory(path: "/p/CLAUDE.md", folder: "/p"),
            .writeMemory(path: "/p/CLAUDE.md", folder: nil, text: "# Rules\n", seen: seen), .deleteMemory(path: "/p/CLAUDE.md", folder: "/p"),
        ]
        for message in asked {
            XCTAssertEqual(message.since, 38, "\(message)")
            XCTAssertFalse(message.isKnown(toHostAt: 37))
            XCTAssertTrue(message.isKnown(toHostAt: 38))
            XCTAssertEqual(MessageCoding.decode(ClientMessage.self, from: MessageCoding.encode(message)), message)
        }
        let one = memory("CLAUDE.md", ["claude", "copilot"], folder: "/p")
        let answered: [ServerMessage] = [
            .memories(path: nil, list: [one, memory("~/.claude/CLAUDE.md", ["claude"])]),
            .memoryRead(path: one.path, content: AgentMemoryContent(memory: one, text: "# Rules\n"), problem: nil),
            .memoryRead(path: "/etc/hosts", content: nil, problem: MemoryWords.notAMemory), .memorySaved(one), .memoryDeleted(path: one.path),
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
