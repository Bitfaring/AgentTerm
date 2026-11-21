import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// MEM-1 to MEM-6 (#220): the agents' memory, what each saved by itself,
/// listed from a home of the test's own, and read, written and
/// deleted only where it is listed. An agent's instructions are no memory.
final class AgentMemoriesTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var folder: URL!
    private var trash: URL!

    override func setUpWithError() throws {
        // As real paths: a memory is given by where its file really is.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-memory-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        folder = root.appendingPathComponent("Dev/app")
        trash = root.appendingPathComponent("trash")
        for directory in [home!, folder!, trash!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        setenv(FileBrowser.trashVariable, trash.path, 1)
    }

    override func tearDown() {
        unsetenv(FileBrowser.trashVariable)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, to path: String, in directory: URL? = nil, modified: Date? = nil) throws -> String {
        let url = (directory ?? folder).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url.path
    }

    private func listed() -> [AgentMemory] { AgentMemories.memories(of: folder.path, home: home.path) }

    /// Claude Code's own folder of notes for a folder.
    private func notes(of directory: URL? = nil) -> String {
        ".claude/projects/" + AgentHistory.claudeProjectName(for: (directory ?? folder).path) + "/memory"
    }

    /// The instructions a person writes for each agent, in the folder and
    /// in the home: none of them is a memory.
    private func writeInstructions() throws -> [String] {
        var paths: [String] = []
        for path in [
            "CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", ".claude/rules/style.md", "AGENTS.md", "AGENTS.override.md", "GEMINI.md",
            ".agents/rules/tests.md", ".github/copilot-instructions.md", ".github/instructions/swift.instructions.md",
        ] { paths.append(try write("instructions", to: path)) }
        for path in [
            ".claude/CLAUDE.md", ".claude/rules/always.md", ".codex/AGENTS.md", ".gemini/GEMINI.md", ".gemini/config/rules/a.md",
            ".copilot/copilot-instructions.md", ".copilot/instructions/mine.instructions.md",
        ] { paths.append(try write("instructions", to: path, in: home)) }
        return paths
    }

    /// MEM-1: what Claude Code saved by itself for a folder is its memory,
    /// `MEMORY.md` first; the instructions written for the agents, in the
    /// folder and in the home, are not, nor is anything else an agent keeps.
    func testOnlyWhatAnAgentSavedByItselfIsListed() throws {
        XCTAssertEqual(listed(), [], "nothing is there yet: nothing is listed")
        _ = try writeInstructions()
        XCTAssertEqual(listed(), [], "an agent's instructions are not its memory")

        try write("note", to: notes() + "/feedback.md", in: home)
        try write("- [x](feedback.md)", to: notes() + "/MEMORY.md", in: home)
        try write("another", to: notes() + "/architecture.md", in: home)
        // Not memories: what is not a note, a conversation, the agent's settings.
        try write("x", to: notes() + "/notes.txt", in: home)
        try write("x", to: notes() + "/.hidden.md", in: home)
        try write("{}", to: notes() + "/../c-1.jsonl", in: home)
        try write("{}", to: ".claude/settings.json", in: home)
        try write("another folder's", to: ".claude/projects/-Users-me-other/memory/MEMORY.md", in: home)

        let found = listed()
        XCTAssertEqual(found.map(\.name), ["MEMORY.md", "architecture.md", "feedback.md"])
        XCTAssertTrue(found.allSatisfy { $0.agent == "claude" && $0.folder == folder.path })
        XCTAssertEqual(found.first?.path, home.appendingPathComponent(notes() + "/MEMORY.md").path)
        XCTAssertEqual(found.first?.size, 18)
    }

    /// A conversation of Claude Code that ran in `directory`, kept under `project`.
    private func writeConversation(in directory: String, project: String, named name: String = "c-1", modified: Date? = nil) throws {
        try write(
            #"{"type":"summary","summary":"x"}"# + "\n" + #"{"type":"user","cwd":"\#(directory)","message":{"role":"user","content":"hello"}}"# + "\n",
            to: ".claude/projects/\(project)/\(name).jsonl", in: home, modified: modified)
    }

    /// MEM-2: every memory on the Mac is listed, whatever folder it is
    /// about and whether or not the app lists that folder, as History lists
    /// every conversation. Its folder is the one a conversation of that
    /// project recorded; with no conversation to tell it, it is not known,
    /// not guessed from the project's name. An empty `memory` lists nothing.
    func testEveryMemoryOnTheMacIsListedWithTheFolderAConversationRecorded() throws {
        // Two projects whose names cannot be turned back into their folders.
        let app = "/Users/me/Dev/my.app"
        let web = "/Users/me/Dev/apps-web"
        try write("app", to: ".claude/projects/-Users-me-Dev-my-app/memory/MEMORY.md", in: home)
        try write("note", to: ".claude/projects/-Users-me-Dev-my-app/memory/feedback.md", in: home)
        try writeConversation(in: app, project: "-Users-me-Dev-my-app")
        try write("web", to: ".claude/projects/-Users-me-Dev-apps-web/memory/MEMORY.md", in: home)
        // The newest conversation there moved elsewhere and names another folder: the one before it tells.
        try writeConversation(in: web, project: "-Users-me-Dev-apps-web", named: "c-old", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try writeConversation(in: "/somewhere/else", project: "-Users-me-Dev-apps-web", named: "c-new", modified: Date(timeIntervalSince1970: 1_800_000_000))
        // A project with notes and no conversation, and one whose conversations are of another folder.
        try write("alone", to: ".claude/projects/-Users-me-Dev-alone/memory/MEMORY.md", in: home)
        try write("moved", to: ".claude/projects/-Users-me-Dev-moved/memory/MEMORY.md", in: home)
        try writeConversation(in: "/Users/me/Dev/other", project: "-Users-me-Dev-moved")
        // A project with an empty `memory`, and one with conversations only.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-Users-me-Dev-empty/memory"), withIntermediateDirectories: true)
        try writeConversation(in: "/Users/me/Dev/empty", project: "-Users-me-Dev-empty")
        try writeConversation(in: "/Users/me/Dev/none", project: "-Users-me-Dev-none")
        _ = try writeInstructions()

        let every = AgentMemories.allMemories(home: home.path)
        XCTAssertEqual(
            every.map { "\($0.project)/\($0.name) \($0.folder ?? "not known")" },
            [
                "-Users-me-Dev-alone/MEMORY.md not known", "-Users-me-Dev-apps-web/MEMORY.md /Users/me/Dev/apps-web",
                "-Users-me-Dev-moved/MEMORY.md not known", "-Users-me-Dev-my-app/MEMORY.md /Users/me/Dev/my.app",
                "-Users-me-Dev-my-app/feedback.md /Users/me/Dev/my.app",
            ])
        XCTAssertTrue(every.allSatisfy { $0.agent == "claude" })
        // One whose folder is not known is read and deleted as the others.
        let alone = try XCTUnwrap(every.first)
        XCTAssertEqual(try AgentMemories.read(alone.path, home: home.path).get().text, "alone")
        XCTAssertNil(try AgentMemories.read(alone.path, home: home.path).get().memory.folder)
        XCTAssertNoThrow(try AgentMemories.delete(alone.path, home: home.path).get())
        XCTAssertEqual(AgentMemories.allMemories(home: home.path).count, 4)
        // A folder's own: those under its name, the folder being the one asked for.
        XCTAssertEqual(AgentMemories.memories(of: app, home: home.path).map { $0.name + " " + ($0.folder ?? "") }, ["MEMORY.md " + app, "feedback.md " + app])
        XCTAssertEqual(AgentMemories.memories(of: "/Users/me/Dev/empty", home: home.path), [])
        XCTAssertEqual(AgentMemories.memories(of: "/Users/me/Dev/none", home: home.path), [])
    }

    /// MEM-3: a memory is read whole, and written all at once; a change is
    /// refused, nothing written, when the file changed after it was read.
    func testAMemoryIsReadAndWrittenAndNotOverAChangeMadeMeanwhile() throws {
        let path = try write("# Notes\n\nBe brief.\n", to: notes() + "/MEMORY.md", in: home, modified: Date(timeIntervalSince1970: 1_800_000_000))
        let read = try AgentMemories.read(path, home: home.path).get()
        XCTAssertEqual(read.text, "# Notes\n\nBe brief.\n")
        XCTAssertEqual(read.memory.name, "MEMORY.md")
        XCTAssertNil(read.memory.folder, "no conversation tells the folder")
        XCTAssertEqual(read.memory.modifiedAt, Date(timeIntervalSince1970: 1_800_000_000))

        let written = try AgentMemories.write("# Notes\n\nBe brief and kind.\n", to: path, seen: read.memory.modifiedAt, home: home.path).get()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Notes\n\nBe brief and kind.\n")
        XCTAssertNotEqual(written.modifiedAt, read.memory.modifiedAt)
        XCTAssertEqual(written.size, 28)

        // With the date read before that change: refused, in words, and the file is as it was.
        let refused = AgentMemories.write("lost", to: path, seen: read.memory.modifiedAt, home: home.path)
        XCTAssertEqual(refused, .failure(AgentMemories.Refusal(MemoryWords.changedMeanwhile("MEMORY.md"))))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Notes\n\nBe brief and kind.\n")
        // With the date it has now: written.
        XCTAssertNoThrow(try AgentMemories.write("again", to: path, seen: written.modifiedAt, home: home.path).get())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "again")

        // One that is not text is not opened.
        let binary = home.appendingPathComponent(notes() + "/blob.md")
        try Data([0x00, 0xff, 0x00, 0x01]).write(to: binary)
        XCTAssertEqual(AgentMemories.read(binary.path, home: home.path), .failure(AgentMemories.Refusal(MemoryWords.notText)))
    }

    /// MEM-4: a memory deleted goes to the Trash, the test's own, and is
    /// no longer listed.
    func testAMemoryIsDeletedToTheTrash() throws {
        let index = try write("- [x](feedback.md)", to: notes() + "/MEMORY.md", in: home)
        let note = try write("note", to: notes() + "/feedback.md", in: home)
        XCTAssertEqual(try AgentMemories.delete(note, home: home.path).get().name, "feedback.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note))
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("feedback.md"), encoding: .utf8), "note")
        XCTAssertEqual(listed().map(\.name), ["MEMORY.md"])
        // Gone already: said, nothing done.
        XCTAssertEqual(AgentMemories.delete(note, home: home.path), .failure(AgentMemories.Refusal(MemoryWords.notAMemory)))
        XCTAssertNoThrow(try AgentMemories.delete(index, home: home.path).get())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)), ["feedback.md", "MEMORY.md"])
        XCTAssertEqual(listed(), [])
    }

    /// MEM-5: whatever path a client sends, only a file that is listed as
    /// a memory is read, written or deleted: not an agent's instructions
    /// (`CLAUDE.md`, `AGENTS.md`), not another file, not one reached with
    /// `..`, not one a link leads to outside the folder of notes, nothing
    /// outside the `memory` folders of Claude Code's projects.
    func testAPathThatIsNotListedIsRefused() throws {
        let memory = try write("# Notes", to: notes() + "/MEMORY.md", in: home)
        let instructions = try writeInstructions()
        let secret = try write("secret", to: "secret.txt", in: root.appendingPathComponent("elsewhere"))
        let settings = try write("{}", to: ".claude/settings.json", in: home)
        let conversation = try write("{}", to: notes() + "/../c-1.jsonl", in: home)
        // A note that is a link to a file outside the notes, and one to a file elsewhere in the home.
        let linkOut = home.appendingPathComponent(notes() + "/out.md").path
        try FileManager.default.createSymbolicLink(atPath: linkOut, withDestinationPath: secret)
        let linkToSettings = home.appendingPathComponent(notes() + "/settings.md").path
        try FileManager.default.createSymbolicLink(atPath: linkToSettings, withDestinationPath: settings)
        // Another folder's notes are memories too; one whose notes are a link to a folder outside the home has none.
        let other = root.appendingPathComponent("Dev/other")
        let others = try write("other", to: notes(of: other) + "/MEMORY.md", in: home)
        let nested = try write("deeper", to: notes() + "/deeper/note.md", in: home)
        let beside = try write("beside", to: notes() + "/../memory.md", in: home)
        let linked = root.appendingPathComponent("Dev/linked")
        try write("outside", to: "far/MEMORY.md", in: root.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(notes(of: linked)).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent(notes(of: linked)).path, withDestinationPath: root.appendingPathComponent("elsewhere/far").path)

        XCTAssertEqual(listed().map(\.name), ["MEMORY.md"], "what a link leads out of the notes to is not a memory")
        XCTAssertEqual(AgentMemories.memories(of: linked.path, home: home.path), [], "notes that are a link out of the home are not listed")

        let refused = AgentMemories.Refusal(MemoryWords.notAMemory)
        let paths =
            instructions + [
                secret, settings, conversation, nested, beside, linkOut, linkToSettings,
                home.appendingPathComponent(notes(of: linked) + "/MEMORY.md").path,
                home.path + "/" + notes() + "/../../../../../elsewhere/secret.txt",
                home.path + "/" + notes() + "/../c-1.jsonl",
                home.path + "/" + notes() + "/MEMORY.md/../../../../settings.json",
                "/etc/hosts", "", folder.path, home.path + "/" + notes(),
            ]
        for path in paths {
            XCTAssertEqual(AgentMemories.read(path, home: home.path), .failure(refused), path)
            XCTAssertEqual(AgentMemories.write("x", to: path, seen: Date(), home: home.path), .failure(refused), path)
            XCTAssertEqual(AgentMemories.delete(path, home: home.path), .failure(refused), path)
        }
        // Another folder's memory is one, listed or not in the app.
        XCTAssertEqual(try AgentMemories.read(others, home: home.path).get().text, "other")
        XCTAssertEqual(try AgentMemories.read(memory, home: home.path).get().text, "# Notes")
        // Nothing was touched.
        for path in instructions { XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "instructions", path) }
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), "{}")
        XCTAssertEqual(try String(contentsOfFile: nested, encoding: .utf8), "deeper")
        XCTAssertEqual(try String(contentsOfFile: beside, encoding: .utf8), "beside")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        // The listed one, named with `..` on the way, is the listed one.
        XCTAssertEqual(try AgentMemories.read(home.path + "/" + notes() + "/../memory/MEMORY.md", home: home.path).get().text, "# Notes")
    }

    // MARK: Over the connection

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    private final class Device {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String, name: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: name)
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var welcomed: Bool { messages.contains { if case .welcome = $0 { return true } else { return false } } }

        func memories(_ path: String?) -> [AgentMemory]? {
            messages.compactMap { if case .memories(path, let list) = $0 { return list } else { return nil } }.last
        }
    }

    /// MEM-6: a device lists the memories, of a folder and every one on
    /// the Mac though the host lists no folder, reads one, changes it, is refused a change over one made
    /// meanwhile, a path that is not listed and the folder's `CLAUDE.md`,
    /// and deletes one, of which every device is told.
    func testADeviceListsReadsChangesAndDeletesAMemory() throws {
        let path = try write("# Notes\n", to: notes() + "/MEMORY.md", in: home)
        try writeConversation(in: folder.path, project: AgentHistory.claudeProjectName(for: folder.path))
        let elsewhere = "/Users/me/Dev/never-listed"
        try write("its own", to: ".claude/projects/-Users-me-Dev-never-listed/memory/MEMORY.md", in: home)
        try writeConversation(in: elsewhere, project: "-Users-me-Dev-never-listed")
        let claude = try write("# Rules\n", to: "CLAUDE.md")
        try write("# For every agent\n", to: "AGENTS.md")
        try write("user", to: ".claude/CLAUDE.md", in: home)
        let secret = try write("secret", to: "secret.txt", in: root.appendingPathComponent("elsewhere"))
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, home: home.path)
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        let host = HostServer(configuration: configuration)
        let port = try host.start()
        defer { host.stop() }
        let phone = Device(port: port, token: token, name: "phone")
        let other = Device(port: port, token: token, name: "other")
        waitUntil("welcome") { phone.welcomed && other.welcomed }

        // Listed: the folder's own notes only; and every one on the Mac, of folders the host does not list.
        phone.connection.send(.memories(path: folder.path))
        waitUntil("the folder's memories") { phone.memories(folder.path) != nil }
        XCTAssertEqual(phone.memories(folder.path)?.map(\.name), ["MEMORY.md"])
        phone.connection.send(.memories(path: nil))
        waitUntil("every memory") { phone.memories(nil) != nil }
        XCTAssertEqual(Set(phone.memories(nil)?.map { $0.folder ?? "not known" } ?? []), [folder.path, elsewhere])
        XCTAssertEqual(phone.memories(nil)?.map(\.agent), ["claude", "claude"])

        // Read.
        phone.connection.send(.readMemory(path: path))
        func read() -> AgentMemoryContent? {
            phone.messages.compactMap { if case .memoryRead(path, let content, _) = $0 { return content } else { return nil } }.last
        }
        waitUntil("the memory read") { read() != nil }
        let content = try XCTUnwrap(read())
        XCTAssertEqual(content.text, "# Notes\n")

        // Changed, with the date it was read at.
        phone.connection.send(.writeMemory(path: path, text: "# Notes\n\nBe brief.\n", seen: content.memory.modifiedAt))
        func saved() -> AgentMemory? {
            phone.messages.compactMap { if case .memorySaved(let memory) = $0 { return memory } else { return nil } }.last
        }
        waitUntil("saved") { saved() != nil }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Notes\n\nBe brief.\n")
        XCTAssertEqual(saved()?.size, 19)

        // With the date from before that change: refused in words, nothing written.
        phone.connection.send(.writeMemory(path: path, text: "lost", seen: content.memory.modifiedAt))
        waitUntil("refused") { phone.messages.contains(.memoryRefused(path: path, problem: MemoryWords.changedMeanwhile("MEMORY.md"))) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Notes\n\nBe brief.\n")

        // The folder's instructions are not a memory: refused for all three, as any path that is not listed.
        for unlisted in [claude, secret] {
            phone.connection.send(.readMemory(path: unlisted))
            waitUntil("not read") { phone.messages.contains(.memoryRead(path: unlisted, content: nil, problem: MemoryWords.notAMemory)) }
            phone.connection.send(.writeMemory(path: unlisted, text: "x", seen: Date()))
            waitUntil("not written") { phone.messages.contains(.memoryRefused(path: unlisted, problem: MemoryWords.notAMemory)) }
        }
        let refusals = { phone.messages.filter { $0 == .memoryRefused(path: claude, problem: MemoryWords.notAMemory) }.count }
        XCTAssertEqual(refusals(), 1)
        phone.connection.send(.deleteMemory(path: claude))
        waitUntil("the instructions not deleted") { refusals() == 2 }
        let reached = home.path + "/" + notes() + "/../../../../../elsewhere/secret.txt"
        phone.connection.send(.deleteMemory(path: reached))
        waitUntil("not deleted") { phone.messages.contains(.memoryRefused(path: reached, problem: MemoryWords.notAMemory)) }
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOfFile: claude, encoding: .utf8), "# Rules\n")

        // Deleted: to the Trash, every device told.
        phone.connection.send(.deleteMemory(path: path))
        waitUntil("deleted") { other.messages.contains(.memoryDeleted(path: path)) && phone.messages.contains(.memoryDeleted(path: path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["MEMORY.md"])
        phone.connection.send(.memories(path: folder.path))
        waitUntil("no longer listed") { phone.memories(folder.path) == [] }
        phone.connection.send(.memories(path: nil))
        waitUntil("the other folder's stays") { phone.memories(nil)?.map(\.folder) == [elsewhere] }
    }
}
