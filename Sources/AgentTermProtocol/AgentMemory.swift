import Foundation

/// A memory of an agent (#220): a file it keeps for itself and reads again,
/// its instructions for a folder or for the user, or a note it saved from an
/// earlier session. Only a file the host knows an agent to read is one
/// (`AgentMemories` on the host), and only one that exists.
public struct AgentMemory: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable {
        /// Read in one folder.
        case folder
        /// The user's own: read in every folder.
        case user
    }

    /// Where the file is on the Mac, links on the way resolved: what is
    /// read, written and moved to the Trash.
    public var path: String
    /// What it is called in a list: where it is inside its folder or under
    /// the agent's own folder ("CLAUDE.md", ".claude/rules/style.md").
    public var name: String
    /// The ids of the agents that read it, in the host's order. A file that
    /// several read, such as `AGENTS.md`, is one memory naming them all.
    public var agents: [String]
    public var scope: Scope
    /// The folder it is a memory of; nil for the user's own.
    public var folder: String?
    /// Its agent writes it by itself, as Claude Code does the notes it
    /// keeps for a folder; the others are written by the user, or by an
    /// agent when it is asked to.
    public var writtenByAgent: Bool
    public var modifiedAt: Date
    /// In bytes.
    public var size: Int

    public var id: String { path }

    public init(path: String, name: String, agents: [String], scope: Scope, folder: String? = nil, writtenByAgent: Bool = false, modifiedAt: Date, size: Int) {
        self.path = path
        self.name = name
        self.agents = agents
        self.scope = scope
        self.folder = folder
        self.writtenByAgent = writtenByAgent
        self.modifiedAt = modifiedAt
        self.size = size
    }

    /// One group of a list of memories: a folder's, or the user's own.
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

    /// The id of the group of the user's own memories, in both lists.
    public static let userGroup = "user"

    /// The side panel's and the folder's screen's two groups: the folder's
    /// memories, then the user's own. A group with none is left out.
    public static func groups(_ memories: [AgentMemory], ofFolder folder: String) -> [Group] {
        let own = memories.filter { $0.scope == .folder && $0.folder == folder }
        let user = memories.filter { $0.scope == .user }
        var groups: [Group] = []
        if !own.isEmpty { groups.append(Group(id: "folder:" + folder, title: MemoryWords.thisFolder, memories: own)) }
        if !user.isEmpty { groups.append(Group(id: userGroup, title: MemoryWords.yours, memories: user)) }
        return groups
    }

    /// The place's groups: each folder's memories under the folder's name,
    /// in the order the folders are listed in, then the user's own. A group
    /// with none is left out.
    public static func groups(_ memories: [AgentMemory], folders: [String]) -> [Group] {
        var order = folders
        for memory in memories where memory.scope == .folder {
            if let folder = memory.folder, !order.contains(folder) { order.append(folder) }
        }
        var groups: [Group] = []
        for folder in order {
            let own = memories.filter { $0.scope == .folder && $0.folder == folder }
            if !own.isEmpty { groups.append(Group(id: "folder:" + folder, title: (folder as NSString).lastPathComponent, memories: own)) }
        }
        let user = memories.filter { $0.scope == .user }
        if !user.isEmpty { groups.append(Group(id: userGroup, title: MemoryWords.yours, memories: user)) }
        return groups
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

/// Every sentence about the agents' memory that the user reads (#220), the
/// same on the Mac and the iPhone, and what the host answers a request it
/// refuses with.
public enum MemoryWords {
    public static let title = "Memory"
    public static let thisFolder = "This Folder"
    public static let yours = "Yours, for Every Folder"

    public static let loadingList = "Reading the memories…"
    public static let loadingOne = "Reading the memory…"
    public static let selectFolder = "Select a folder to see the agents' memory of it."
    public static let noneInFolder = "None of the files the agents read as their memory is in this folder, or among your own."
    public static let noneAnywhere = "None of the files the agents read as their memory is in a folder listed here, or among your own."
    public static let choose = "Choose a memory"
    public static let chooseWhy = "Read it, change it, or delete it."

    public static let save = "Save"
    public static let revert = "Revert"
    public static let delete = "Delete…"
    public static let unsaved = "Changed, not saved"

    /// "1 memory", "4 memories".
    public static func count(_ count: Int) -> String { count == 1 ? "1 memory" : "\(count) memories" }

    /// "Claude Code", "Claude Code and Codex", "Claude Code, Codex and Copilot CLI".
    public static func names(of agents: [String], agentNames: [(id: String, name: String)]) -> String {
        let names = agents.map { id in agentNames.first { $0.id == id }?.name ?? id }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Who reads it: "Read by Claude Code and Codex".
    public static func readers(of memory: AgentMemory, agentNames: [(id: String, name: String)]) -> String {
        "Read by " + names(of: memory.agents, agentNames: agentNames)
    }

    /// Who writes it, when its agent does by itself: "Written by Claude Code itself".
    public static func writer(of memory: AgentMemory, agentNames: [(id: String, name: String)]) -> String? {
        memory.writtenByAgent ? "Written by " + names(of: memory.agents, agentNames: agentNames) + " itself" : nil
    }

    /// "1.2 KB", "340 bytes".
    public static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// What is not shown, and why: said under both lists, so that what is
    /// listed is not taken for all an agent remembers (principle 5).
    public struct Note: Equatable, Identifiable, Sendable {
        /// The agent it is about; nil for all of them.
        public var agent: String?
        public var text: String
        public var id: String { agent ?? "all" }
    }

    public static let notShownTitle = "Not shown"

    public static let notShown: [Note] = [
        Note(agent: "codex", text: "What Codex saves by itself is not known: only its instructions are listed."),
        Note(agent: "agy", text: "What Antigravity saves by itself is not known: only its rules are listed."),
        Note(agent: "copilot", text: "Copilot CLI keeps what it saves by itself on GitHub, not in a file: only its instructions are listed."),
        Note(agent: nil, text: "Files in the folders above a folder or inside it are not listed, though an agent may read them too."),
    ]

    // MARK: What the host refuses with

    public static let notAMemory = "That is not a file AgentTerm knows an agent to read as its memory, or it is no longer there: nothing was done."
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
/// the Trash, saying which agents read it.
public struct DeleteMemoryQuestion: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    public init(_ memory: AgentMemory, agentNames: [(id: String, name: String)]) {
        let readers = MemoryWords.names(of: memory.agents, agentNames: agentNames)
        title = "Delete “\(memory.name)”?"
        message =
            "\(readers) \(memory.agents.count == 1 ? "reads" : "read") it\(memory.scope == .user ? " in every folder" : ""), and will no longer have it. The file is moved to the Trash of the Mac, from where it can be put back."
        confirm = "Delete Memory"
    }
}
