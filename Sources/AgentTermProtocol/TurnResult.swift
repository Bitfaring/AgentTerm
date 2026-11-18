import Foundation

/// What an agent's last turn came to (#71): what it was asked, what it
/// answered, the commands it ran as its own record has them, and what
/// changed in its folder while it worked. The host keeps the last one of
/// each session, in memory, and tells every device when a turn ends and
/// when a device connects (`ServerMessage.turnResult`).
public struct TurnResult: Codable, Equatable, Sendable {
    /// How the turn ended.
    public enum End: String, Codable, Sendable {
        /// The agent said it was done.
        case done
        /// The user stopped it.
        case stopped
    }

    /// A command the agent ran, with its exit code as its record has it.
    public struct Command: Codable, Equatable, Sendable {
        public var command: String
        /// Nil when the record does not say it.
        public var exitCode: Int?
        /// The record says it failed, and not with which code.
        public var failed: Bool?

        public init(command: String, exitCode: Int? = nil, failed: Bool? = nil) {
            self.command = command
            self.exitCode = exitCode
            self.failed = failed
        }
    }

    /// A file of the folder that changed while the agent worked.
    public struct File: Codable, Equatable, Sendable {
        /// Relative to the repository's top.
        public var path: String
        /// What git says of it now, as `git status --short` does ("M",
        /// "A", "D", "??"); nil when it is as it was in the last commit
        /// again.
        public var status: String?
        /// Its lines added and removed against the last commit, now; nil
        /// for a file git does not count (a new file, a binary one).
        public var added: Int?
        public var removed: Int?
        /// It had changes already when the turn began: the lines are not
        /// all of this turn.
        public var changedBefore: Bool?

        public init(path: String, status: String?, added: Int? = nil, removed: Int? = nil, changedBefore: Bool? = nil) {
            self.path = path
            self.status = status
            self.added = added
            self.removed = removed
            self.changedBefore = changedBefore
        }
    }

    /// What changed in the session's folder from the turn's start to its
    /// end, by whoever changed it.
    public struct Changes: Codable, Equatable, Sendable {
        public var files: [File]
        /// Another session of an agent worked in the same repository while
        /// this one did: not all of it may be this agent's.
        public var shared: Bool
        /// The session works in a worktree no other session works in.
        public var ownWorktree: Bool

        public init(files: [File], shared: Bool = false, ownWorktree: Bool = false) {
            self.files = files
            self.shared = shared
            self.ownWorktree = ownWorktree
        }
    }

    /// What it was asked, as its record or its hooks have it.
    public var request: String?
    /// What it answered last.
    public var reply: String?
    public var startedAt: Date
    public var endedAt: Date
    public var end: End
    /// Nil when the agent's record of the turn could not be read: then
    /// which commands it ran is not known.
    public var commands: [Command]?
    /// Nil when the folder is not in a git repository, or git could not
    /// say.
    public var changes: Changes?

    public init(
        request: String?, reply: String?, startedAt: Date, endedAt: Date, end: End, commands: [Command]?, changes: Changes?
    ) {
        self.request = request
        self.reply = reply
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.end = end
        self.commands = commands
        self.changes = changes
    }

    // MARK: The words both apps show (principle 9)

    public static let asked = "What it was asked"
    public static let ran = "Commands it ran"
    public static let changed = "Changed in the folder while it worked"
    public static let noCommand = "It ran no command."
    public static let commandsNotKnown = "Its record of this turn could not be read: which commands it ran is not known."
    public static let nothingChanged = "Nothing changed in the folder."
    public static let changesNotKnown = "Not in a git repository: what changed is not known."
    public static let shared = "Another agent worked in this repository at the same time: not all of these changes may be this one's."
    public static let ownWorktree = "In a worktree of its own."
    public static let changedBefore = "already changed before"
    public static let stopped = "The turn was stopped before the agent was done."
    public static let openDiff = "Open Diff"
    public static let handOff = "Hand Off…"
    public static let continuePrompt = "Continue with…"
    public static let send = "Send"
    public static let nextInstruction = "The next instruction"
    public static let sessionEnded = "The session has ended."
    public static let title = "Last Turn"
    /// Its switch in Settings, on both apps.
    public static let setting = "Show what each turn came to"
    public static let settingDetail =
        "When an agent's turn ends, its folder is looked at with git and the agent's own record of the turn is read, on the Mac only, to show in the Inbox the commands it ran and what changed. Off, the Inbox shows what the agent said."
    public static let outcomeNotKnown = "not known"

    /// Under a list cut short.
    public static func andMore(_ count: Int) -> String { "And \(count) more." }
    public static let commandsNote = "As the agent's own record has them; what it says it ran is in its answer."

    /// A command's outcome in words: "exit 0", "exit 3", "failed", or nil
    /// when not known.
    public static func outcome(of command: Command) -> String? {
        if let code = command.exitCode { return "exit \(code)" }
        return command.failed == true ? "failed" : nil
    }
}
