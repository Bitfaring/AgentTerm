import Foundation

/// A memory of an agent (#220): a note the agent saved by itself for a
/// folder, which it reads again in its later sessions there. Only a file
/// the host knows an agent to keep as its memory is one (`AgentMemories` on
/// the host), and only one that exists. An agent's instructions, which a
/// person writes for it (`CLAUDE.md`, `AGENTS.md`), are not memories.
public struct AgentMemory: Codable, Equatable, Identifiable, Sendable {
    /// Where the file is on the Mac, links on the way resolved: what is
    /// read, written and moved to the Trash.
    public var path: String
    /// What it is called in a list: the file's name ("MEMORY.md").
    public var name: String
    /// The id of the agent that saved it and reads it.
    public var agent: String
    /// The folder it is a memory of; nil when that is not known: its
    /// agent names the folder in a way that cannot be turned back into a
    /// path, and nothing else it keeps tells it.
    public var folder: String?
    /// What its agent calls the folder, as it wrote it
    /// ("-Users-me-Dev-app"): shown when the folder is not known.
    public var project: String
    public var modifiedAt: Date
    /// In bytes.
    public var size: Int

    public var id: String { path }

    public init(path: String, name: String, agent: String, folder: String?, project: String, modifiedAt: Date, size: Int) {
        self.path = path
        self.name = name
        self.agent = agent
        self.folder = folder
        self.project = project
        self.modifiedAt = modifiedAt
        self.size = size
    }

    /// One group of a list of memories: an agent's, as History's groups are.
    public struct Group: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var memories: [AgentMemory]

        public init(id: String, title: String, memories: [AgentMemory]) {
            self.id = id
            self.title = title
            self.memories = memories
        }
    }

    /// The memories grouped by agent in the order given, as History groups
    /// its conversations, each group's in the order the host listed them.
    /// An agent with none has no group.
    public static func groups(_ memories: [AgentMemory], agentNames: [(id: String, name: String)]) -> [Group] {
        var known = agentNames
        for memory in memories where !known.contains(where: { $0.id == memory.agent }) { known.append((memory.agent, memory.agent)) }
        return known.compactMap { agent in
            let own = memories.filter { $0.agent == agent.id }
            return own.isEmpty ? nil : Group(id: "agent:" + agent.id, title: agent.name, memories: own)
        }
    }
}

/// A memory as it was read: what it is now, and its text.
public struct AgentMemoryContent: Codable, Equatable, Sendable {
    /// As it is now: its date is the one a change is sent back with.
    public var memory: AgentMemory
    public var text: String

    public init(memory: AgentMemory, text: String) {
        self.memory = memory
        self.text = text
    }
}

/// A memory's text taken apart for its preview (#220): the front matter an
/// agent opens a note with, and the Markdown under it. Claude Code's notes
/// begin with a block between two lines of `---` that names the note, says
/// what it is about and keeps ids of its own; drawn as Markdown it is
/// noise. Read by lines, leniently: what cannot be read is left out, never
/// a failure, and a text with no such block is all body.
public struct MemoryText: Equatable, Sendable {
    /// What the note is about, in a line: its `description`.
    public var description: String?
    /// Its `name`.
    public var name: String?
    /// What kind of note it is: `metadata.type`, or a top-level `type`.
    public var type: String?
    /// When its agent last changed it: `modified`, under `metadata` or at the top.
    public var modified: Date?
    /// The text without its front matter: all of it when it has none.
    public var body: String
    /// Whether the text opened with a front matter block.
    public private(set) var hasFrontMatter = false

    public init(_ text: String) {
        body = text
        // Front matter only when the first line is exactly `---` and a later one closes it.
        // A Windows line end is one character to Swift, which a split at "\n" would not see.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return }
        body = lines[(end + 1)...].joined(separator: "\n")
        hasFrontMatter = true
        var inMetadata = false
        var top: [String: String] = [:]
        var metadata: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let indented = line.hasPrefix("  ") || line.hasPrefix("\t")
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
            if indented {
                if inMetadata, metadata[key] == nil { metadata[key] = value }
            } else {
                inMetadata = key == "metadata" && value.isEmpty
                if !inMetadata, top[key] == nil { top[key] = value }
            }
        }
        func filled(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        description = filled(top["description"])
        name = filled(top["name"])
        type = filled(metadata["type"]) ?? filled(top["type"])
        modified = (filled(metadata["modified"]) ?? filled(top["modified"])).flatMap(Self.date)
    }

    /// What a reader wants of the front matter, a line each as a name and
    /// what it is, for the top of the preview on both apps: the note's
    /// name when it is not its file's (`fileName` without `.md`), its type
    /// and when it changed. The description is shown by itself, as the
    /// note's summary; ids the agent keeps for itself are not shown.
    public func facts(fileName: String) -> [(name: String, value: String)] {
        var facts: [(String, String)] = []
        let file = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        if let name, name != file { facts.append(("Name", name)) }
        if let type { facts.append(("Type", type)) }
        if let modified { facts.append(("Changed", modified.formatted(date: .abbreviated, time: .shortened))) }
        return facts.map { (name: $0.0, value: $0.1) }
    }

    /// ISO 8601, with or without fractions of a second.
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Every sentence about the agents' memory that the user reads (#220), the
/// same on the Mac and the iPhone, and what the host answers a request it
/// refuses with.
public enum MemoryWords {
    public static let title = "Memory"

    public static let loadingList = "Reading the memories…"
    public static let loadingOne = "Reading the memory…"
    public static let selectFolder = "Select a folder to see what the agents saved about it."
    public static let noneInFolder = "No agent has saved a memory of this folder yet."
    public static let noneAnywhere = "No agent has saved a memory on this Mac yet."
    public static let folderNotKnown = "Folder not known"

    /// The folder a memory is about, short, for a row: its name, or that
    /// it is not known, with what its agent calls it.
    public static func folder(of memory: AgentMemory) -> String {
        memory.folder.map { ($0 as NSString).lastPathComponent } ?? folderNotKnown + ": " + memory.project
    }
    public static let choose = "Choose a memory"
    public static let chooseWhy = "Read it, change it, or delete it."

    public static let save = "Save"
    public static let revert = "Revert"
    public static let delete = "Delete…"
    public static let unsaved = "Changed, not saved"
    /// Said in the preview, where nothing is typed: a memory is changed as text.
    public static let changeAsText = "Show as Text to change it."

    /// "1 memory", "4 memories".
    public static func count(_ count: Int) -> String { count == 1 ? "1 memory" : "\(count) memories" }

    /// "1.2 KB", "340 bytes".
    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: What the host refuses with

    public static let notAMemory = "That is not a file AgentTerm knows an agent to keep as its memory, or it is no longer there: nothing was done."
    public static let gone = "That memory is no longer there."
    public static let notText = "That memory is not text, or is too large to open: it was left as it is."

    /// The file changed after the client read it: nothing is written over it.
    public static func changedMeanwhile(_ name: String) -> String {
        "“\(name)” was changed on the Mac after it was read here, so nothing was written. Revert to read it again, then change it."
    }

    /// On a device that does not reach the Mac at the moment.
    public static let notConnected = "The Mac is not reached at the moment, so nothing was saved. The change is kept here."

    public static func notWritten(_ name: String, reason: String) -> String { "“\(name)” could not be written: \(reason)" }
    public static func notTrashed(_ name: String, reason: String) -> String { "“\(name)” could not be moved to the Trash: \(reason)" }
}

/// What is asked before a memory is deleted (#220): once, since it goes to
/// the Trash, saying whose it is and of which folder.
public struct DeleteMemoryQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    public init(_ memory: AgentMemory, agentName: String) {
        title = "Delete “\(memory.name)”?"
        let about = memory.folder.map { "“\(($0 as NSString).lastPathComponent)”" } ?? "a folder that is not known (\(memory.project))"
        message =
            "\(agentName) saved it about \(about), and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back."
        confirm = "Delete Memory"
    }
}
