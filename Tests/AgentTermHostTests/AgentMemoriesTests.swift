import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// MEM-1 to MEM-7 (#220): the agents' memory, listed from a home and a
/// folder of the test's own, and read, written and deleted only where it
/// is listed.
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

    /// Claude Code's own folder of notes for the test's folder.
    private var notes: String { ".claude/projects/" + AgentHistory.claudeProjectName(for: folder.path) + "/memory" }

    /// MEM-1: each agent's files of a folder are its memories, with who
    /// reads each; a file that is not there is not listed, nor is one no
    /// agent is known to read.
    func testAFoldersMemoriesAreListedWithTheAgentsThatReadThem() throws {
        XCTAssertEqual(listed(), [], "nothing is there yet: nothing is listed")
        try write("# Claude", to: "CLAUDE.md")
        try write("mine", to: "CLAUDE.local.md")
        try write("inner", to: ".claude/CLAUDE.md")
        try write("style", to: ".claude/rules/style.md")
        try write("not a rule", to: ".claude/rules/notes.txt")
        try write("override", to: "AGENTS.override.md")
        try write("gemini", to: "GEMINI.md")
        try write("rule", to: ".agents/rules/tests.md")
        try write("copilot", to: ".github/copilot-instructions.md")
        try write("swift", to: ".github/instructions/swift.instructions.md")
        try write("not instructions", to: ".github/instructions/README.md")
        // Read by no agent as far as is known: never a memory.
        try write("readme", to: "README.md")
        try write("cursor", to: ".cursorrules")
        try write("deeper", to: "Sources/CLAUDE.md")

        let found = listed()
        XCTAssertEqual(
            found.map { $0.name + " " + $0.agents.joined(separator: ",") },
            [
                "CLAUDE.md claude,copilot", "CLAUDE.local.md claude", ".claude/CLAUDE.md claude", ".claude/rules/style.md claude,copilot",
                "AGENTS.override.md codex", "GEMINI.md agy,copilot", ".agents/rules/tests.md agy", ".github/copilot-instructions.md copilot",
                ".github/instructions/swift.instructions.md copilot",
            ])
        XCTAssertTrue(found.allSatisfy { $0.scope == .folder && $0.folder == folder.path && !$0.writtenByAgent })
        XCTAssertEqual(found.first?.path, folder.appendingPathComponent("CLAUDE.md").path)
        XCTAssertEqual(found.first?.size, 8)
    }

    /// MEM-2: a file several agents read is one memory that names them
    /// all, also when one of them reads it through a link of another name.
    func testAFileSeveralAgentsReadIsOneMemory() throws {
        let agents = try write("# For every agent", to: "AGENTS.md")
        XCTAssertEqual(listed().map(\.agents), [["codex", "agy", "copilot"]])
        // CLAUDE.md as a link to AGENTS.md: the same file, read by Claude Code too.
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "AGENTS.md")
        let found = listed()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.path, agents)
        XCTAssertEqual(found.first?.name, "AGENTS.md", "under the file's own name, not the link's")
        XCTAssertEqual(found.first?.agents, ["claude", "codex", "agy", "copilot"])
    }

    /// MEM-3: the user's own, read in every folder, and what Claude Code
    /// writes by itself for the folder; the folders' come first, then the
    /// user's own.
    func testTheUsersOwnAndWhatClaudeCodeWritesByItself() throws {
        try write("user", to: ".claude/CLAUDE.md", in: home)
        try write("rule", to: ".claude/rules/always.md", in: home)
        try write("codex", to: ".codex/AGENTS.md", in: home)
        try write("gemini", to: ".gemini/GEMINI.md", in: home)
        try write("rule", to: ".gemini/config/rules/a.md", in: home)
        try write("copilot", to: ".copilot/copilot-instructions.md", in: home)
        try write("mine", to: ".copilot/instructions/mine.instructions.md", in: home)
        // Not memories: an agent's settings, its conversations.
        try write("{}", to: ".claude/settings.json", in: home)
        try write("{}", to: ".codex/config.toml", in: home)
        try write("note", to: notes + "/feedback.md", in: home)
        try write("- [x](feedback.md)", to: notes + "/MEMORY.md", in: home)
        try write("{}", to: notes + "/../c-1.jsonl", in: home)
        try write("another folder's", to: ".claude/projects/-Users-me-other/memory/MEMORY.md", in: home)
        try write("# Claude", to: "CLAUDE.md")

        let found = listed()
        XCTAssertEqual(
            found.map { "\($0.scope.rawValue) \($0.name) \($0.agents.joined(separator: ","))\($0.writtenByAgent ? " itself" : "")" },
            [
                "folder CLAUDE.md claude,copilot", "folder memory/MEMORY.md claude itself", "folder memory/feedback.md claude itself",
                "user ~/.claude/CLAUDE.md claude", "user ~/.claude/rules/always.md claude", "user ~/.codex/AGENTS.md codex", "user ~/.gemini/GEMINI.md agy",
                "user ~/.gemini/config/rules/a.md agy", "user ~/.copilot/copilot-instructions.md copilot", "user ~/.copilot/instructions/mine.instructions.md copilot",
            ])
        XCTAssertTrue(found.filter { $0.scope == .user }.allSatisfy { $0.folder == nil })
        XCTAssertEqual(AgentMemories.memoriesOfUser(home: home.path).map(\.name), found.filter { $0.scope == .user }.map(\.name))

        // Every folder's: each folder's own under it, the user's own once.
        let other = root.appendingPathComponent("Dev/other")
        try write("other", to: "AGENTS.md", in: other)
        let every = AgentMemories.memories(ofEvery: [folder.path, other.path], home: home.path)
        XCTAssertEqual(every.filter { $0.folder == other.path }.map(\.name), ["AGENTS.md"])
        XCTAssertEqual(every.filter { $0.folder == folder.path }.count, 3)
        XCTAssertEqual(every.filter { $0.scope == .user }.count, 7)
        // The home folder listed as a folder: its `.claude/CLAUDE.md` is the user's, once.
        let withHome = AgentMemories.memories(of: home.path, home: home.path)
        XCTAssertEqual(withHome.filter { $0.path == home.appendingPathComponent(".claude/CLAUDE.md").path }.map(\.scope), [.user])
    }

    /// MEM-4: a memory is read whole, and written all at once; a change is
    /// refused, nothing written, when the file changed after it was read.
    func testAMemoryIsReadAndWrittenAndNotOverAChangeMadeMeanwhile() throws {
        let path = try write("# Rules\n\nBe brief.\n", to: "CLAUDE.md", modified: Date(timeIntervalSince1970: 1_800_000_000))
        let read = try AgentMemories.read(path, folder: folder.path, home: home.path).get()
        XCTAssertEqual(read.text, "# Rules\n\nBe brief.\n")
        XCTAssertEqual(read.memory.name, "CLAUDE.md")
        XCTAssertEqual(read.memory.modifiedAt, Date(timeIntervalSince1970: 1_800_000_000))

        let written = try AgentMemories.write("# Rules\n\nBe brief and kind.\n", to: path, folder: folder.path, seen: read.memory.modifiedAt, home: home.path).get()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Rules\n\nBe brief and kind.\n")
        XCTAssertNotEqual(written.modifiedAt, read.memory.modifiedAt)
        XCTAssertEqual(written.size, 28)

        // With the date read before that change: refused, in words, and the file is as it was.
        let refused = AgentMemories.write("lost", to: path, folder: folder.path, seen: read.memory.modifiedAt, home: home.path)
        XCTAssertEqual(refused, .failure(AgentMemories.Refusal(MemoryWords.changedMeanwhile("CLAUDE.md"))))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Rules\n\nBe brief and kind.\n")
        // With the date it has now: written.
        XCTAssertNoThrow(try AgentMemories.write("again", to: path, folder: folder.path, seen: written.modifiedAt, home: home.path).get())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "again")

        // One that is not text is not opened.
        let binary = folder.appendingPathComponent("GEMINI.md")
        try Data([0x00, 0xff, 0x00, 0x01]).write(to: binary)
        XCTAssertEqual(AgentMemories.read(binary.path, folder: folder.path, home: home.path), .failure(AgentMemories.Refusal(MemoryWords.notText)))
    }

    /// MEM-5: a memory deleted goes to the Trash, the test's own, and is
    /// no longer listed.
    func testAMemoryIsDeletedToTheTrash() throws {
        let path = try write("# Rules", to: "AGENTS.md")
        let note = try write("note", to: notes + "/MEMORY.md", in: home)
        XCTAssertEqual(try AgentMemories.delete(path, folder: folder.path, home: home.path).get().name, "AGENTS.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("AGENTS.md"), encoding: .utf8), "# Rules")
        XCTAssertEqual(listed().map(\.name), ["memory/MEMORY.md"])
        // Gone already: said, nothing done.
        XCTAssertEqual(AgentMemories.delete(path, folder: folder.path, home: home.path), .failure(AgentMemories.Refusal(MemoryWords.notAMemory)))
        // What Claude Code wrote by itself, under the home.
        XCTAssertNoThrow(try AgentMemories.delete(note, folder: folder.path, home: home.path).get())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)), ["AGENTS.md", "MEMORY.md"])
        XCTAssertEqual(listed(), [])
    }

    /// MEM-6: whatever path a client sends, only a file listed for the
    /// folder it names is read, written or deleted: not another file of
    /// the folder, not one reached with `..`, not one a link leads to
    /// outside the folder, not another folder's memory.
    func testAPathThatIsNotListedIsRefused() throws {
        let memory = try write("# Rules", to: "CLAUDE.md")
        let secret = try write("secret", to: "secret.txt", in: root.appendingPathComponent("elsewhere"))
        let readme = try write("readme", to: "README.md")
        let settings = try write("{}", to: ".claude/settings.json", in: home)
        // A rule that is a link to a file outside the folder, and a folder of rules that is one.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude/rules"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".claude/rules/out.md").path, withDestinationPath: secret)
        try write("outside", to: "rules/far.md", in: root.appendingPathComponent("elsewhere"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent(".agents/rules").path, withDestinationPath: root.appendingPathComponent("elsewhere/rules").path)
        let other = root.appendingPathComponent("Dev/other")
        let others = try write("other", to: "AGENTS.md", in: other)

        XCTAssertEqual(listed().map(\.name), ["CLAUDE.md"], "what a link leads out of the folder to is not its memory")

        let refused = AgentMemories.Refusal(MemoryWords.notAMemory)
        let paths = [
            secret, readme, settings, others,
            folder.appendingPathComponent(".claude/rules/out.md").path,
            folder.appendingPathComponent(".agents/rules/far.md").path,
            folder.path + "/../../elsewhere/secret.txt",
            folder.path + "/.claude/rules/../../../../elsewhere/secret.txt",
            folder.path + "/CLAUDE.md/../README.md",
            "/etc/hosts", "", folder.path,
        ]
        for path in paths {
            XCTAssertEqual(AgentMemories.read(path, folder: folder.path, home: home.path), .failure(refused), path)
            XCTAssertEqual(AgentMemories.write("x", to: path, folder: folder.path, seen: Date(), home: home.path), .failure(refused), path)
            XCTAssertEqual(AgentMemories.delete(path, folder: folder.path, home: home.path), .failure(refused), path)
        }
        // A folder's memory is not one of the user's own, and the reverse.
        XCTAssertEqual(AgentMemories.read(memory, folder: nil, home: home.path), .failure(refused))
        XCTAssertEqual(AgentMemories.delete(memory, folder: other.path, home: home.path), .failure(refused))
        // Nothing was touched.
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOfFile: readme, encoding: .utf8), "readme")
        XCTAssertEqual(try String(contentsOfFile: settings, encoding: .utf8), "{}")
        XCTAssertEqual(try String(contentsOfFile: others, encoding: .utf8), "other")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        // The listed one, named with `..` on the way, is the listed one.
        XCTAssertEqual(try AgentMemories.read(folder.path + "/.claude/../CLAUDE.md", folder: folder.path, home: home.path).get().text, "# Rules")
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

    /// MEM-7: a device lists the memories, of a folder and of every listed
    /// folder, reads one, changes it, is refused a change over one made
    /// meanwhile and a path that is not listed, and deletes one, of which
    /// every device is told.
    func testADeviceListsReadsChangesAndDeletesAMemory() throws {
        let path = try write("# Rules\n", to: "CLAUDE.md")
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

        // Listed: the folder's and the user's own; every listed folder's, once the folder is one.
        phone.connection.send(.memories(path: folder.path))
        waitUntil("the folder's memories") { phone.memories(folder.path) != nil }
        XCTAssertEqual(phone.memories(folder.path)?.map(\.name), ["CLAUDE.md", "~/.claude/CLAUDE.md"])
        phone.connection.send(.memories(path: nil))
        waitUntil("no folder is listed yet") { phone.memories(nil)?.map(\.name) == ["~/.claude/CLAUDE.md"] }
        phone.connection.send(.addFolder(path: folder.path))
        phone.connection.send(.memories(path: nil))
        waitUntil("every folder's") { phone.memories(nil)?.map(\.name) == ["CLAUDE.md", "~/.claude/CLAUDE.md"] }
        let listed = try XCTUnwrap(phone.memories(nil)?.first)
        XCTAssertEqual(listed.folder, folder.path)

        // Read.
        phone.connection.send(.readMemory(path: path, folder: folder.path))
        func read() -> AgentMemoryContent? {
            phone.messages.compactMap { if case .memoryRead(path, let content, _) = $0 { return content } else { return nil } }.last
        }
        waitUntil("the memory read") { read() != nil }
        let content = try XCTUnwrap(read())
        XCTAssertEqual(content.text, "# Rules\n")

        // Changed, with the date it was read at.
        phone.connection.send(.writeMemory(path: path, folder: folder.path, text: "# Rules\n\nBe brief.\n", seen: content.memory.modifiedAt))
        func saved() -> AgentMemory? {
            phone.messages.compactMap { if case .memorySaved(let memory) = $0 { return memory } else { return nil } }.last
        }
        waitUntil("saved") { saved() != nil }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Rules\n\nBe brief.\n")
        XCTAssertEqual(saved()?.size, 19)

        // With the date from before that change: refused in words, nothing written.
        phone.connection.send(.writeMemory(path: path, folder: folder.path, text: "lost", seen: content.memory.modifiedAt))
        waitUntil("refused") { phone.messages.contains(.memoryRefused(path: path, problem: MemoryWords.changedMeanwhile("CLAUDE.md"))) }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "# Rules\n\nBe brief.\n")

        // A path that is not listed: refused for all three.
        phone.connection.send(.readMemory(path: secret, folder: folder.path))
        waitUntil("not read") { phone.messages.contains(.memoryRead(path: secret, content: nil, problem: MemoryWords.notAMemory)) }
        phone.connection.send(.writeMemory(path: secret, folder: folder.path, text: "x", seen: Date()))
        waitUntil("not written") { phone.messages.contains(.memoryRefused(path: secret, problem: MemoryWords.notAMemory)) }
        let reached = folder.path + "/../../elsewhere/secret.txt"
        phone.connection.send(.deleteMemory(path: reached, folder: folder.path))
        waitUntil("not deleted") { phone.messages.contains(.memoryRefused(path: reached, problem: MemoryWords.notAMemory)) }
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "secret")

        // Deleted: to the Trash, every device told.
        phone.connection.send(.deleteMemory(path: path, folder: folder.path))
        waitUntil("deleted") { other.messages.contains(.memoryDeleted(path: path)) && phone.messages.contains(.memoryDeleted(path: path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), ["CLAUDE.md"])
        phone.connection.send(.memories(path: folder.path))
        waitUntil("no longer listed") { phone.memories(folder.path)?.map(\.name) == ["~/.claude/CLAUDE.md"] }
    }
}
