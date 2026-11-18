import Foundation

/// Where AgentTerm keeps the git worktrees it makes for sessions (#23):
/// inside the project, `<project>/.agentterm/worktrees/<branch>`, next to
/// the handoffs, so the project stays one folder to move, back up or delete.
public enum WorktreePath {
    public static let folder = ".agentterm/worktrees"

    /// The project a worktree AgentTerm made belongs to, nil for any other path.
    public static func project(of path: String) -> String? {
        guard let range = path.range(of: "/" + folder + "/") else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// Whether a session started in `cwd` is one of `folder`'s: in it, or in
    /// one of the worktrees AgentTerm made for it.
    public static func belongs(_ cwd: String, to folder: String) -> Bool {
        cwd == folder || project(of: cwd) == folder
    }

    /// The default name of a new worktree's branch: the agent and a number
    /// no branch has yet.
    public static func branchName(agent: String, taken: Set<String>) -> String {
        var number = 1
        while taken.contains("agentterm/\(agent)-\(number)") { number += 1 }
        return "agentterm/\(agent)-\(number)"
    }
}

/// A worktree to make for what is started (#150): its branch, nil for the
/// one named after the agent, cut from the branch `from` names, nil for the
/// folder's current commit.
public struct NewWorktree: Codable, Equatable, Sendable {
    public var branch: String?
    public var from: String?

    public init(branch: String?, from: String?) {
        self.branch = branch
        self.from = from
    }
}

/// One of a repository's git worktrees (#23, #33), whoever made it.
public struct WorktreeInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var path: String
    /// Its branch, nil for a detached HEAD.
    public var branch: String?
    /// The repository's own folder, the first of its worktrees.
    public var isMain: Bool
    /// Commits on its branch that the folder's branch does not have.
    public var ahead: Int
    /// Files changed in it and not committed.
    public var changed: Int
    /// A session runs in it.
    public var inUse: Bool
    /// git knows of it, and its folder is gone.
    public var missing: Bool
    /// AgentTerm made it, in the project's `.agentterm/worktrees`.
    public var isAgentTerm: Bool

    public var id: String { path }

    /// Work in it that is not in the folder's branch.
    public var hasUnmergedWork: Bool { ahead > 0 || changed > 0 }

    public init(path: String, branch: String?, isMain: Bool, ahead: Int = 0, changed: Int = 0, inUse: Bool = false, missing: Bool = false, isAgentTerm: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.ahead = ahead
        self.changed = changed
        self.inUse = inUse
        self.missing = missing
        self.isAgentTerm = isAgentTerm
    }
}

// MARK: In words

/// What is said and asked about worktrees (#43), the same on every device.
public enum WorktreeWords {
    public static let newTitle = "New Worktree"
    public static let newAdvice =
        "A new branch in a folder of its own, so that what is done there does not touch this one. It starts from the branch picked, without changes that are not committed and without what git ignores, such as .env or node_modules: what it needs, such as `npm install`, is done there."
    public static let uncommitted = "This folder has changes that are not committed: the new worktree will not have them."
    /// How the agent in a new worktree begins (#150): with nothing before
    /// it, or carrying on a conversation of the folder's, handed off.
    public static let begin = "Begin"
    public static let fresh = "Start Fresh"
    public static let continueConversation = "Continue a Conversation"
    public static let conversation = "Conversation"
    public static let continueAdvice =
        "The conversation is handed off into the new worktree: the agent picked reads it in a file there, and works there only, not in this folder."
    public static let noConversation = "No conversation of this folder yet."

    public static func discardTitle(_ worktree: WorktreeInfo) -> String { "Throw away \(worktree.chipTitle)?" }
    public static func discardMessage(_ worktree: WorktreeInfo) -> String {
        worktree.hasUnmergedWork ? "It has work that is not merged: \(worktree.menuDetail). It will be lost." : "Its folder is removed."
    }
    public static let discardWithBranch = "Throw Away the Worktree and Its Branch"
    public static let discardKeepingBranch = "Throw Away the Worktree, Keep the Branch"

    public static func merge(into main: WorktreeInfo?) -> String { "Merge into \(main?.branch ?? "the folder's branch")" }
    public static let pullRequest = "Open a Pull Request"
}

extension WorktreeInfo {
    /// What a worktree is called on its chip: its branch, or its folder
    /// when its HEAD is detached.
    public var chipTitle: String { branch ?? (path as NSString).lastPathComponent }

    /// What its chip says after the name: how many files are changed in
    /// it, and how many commits it has that the folder's branch has not.
    public var chipCounts: String {
        if missing { return "missing" }
        // In words, not numbers alone (#50).
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) changed") }
        if ahead > 0 { parts.append("\(ahead) ahead") }
        return parts.joined(separator: " · ")
    }

    /// All of it in a sentence, for a tooltip and for assistive tools.
    public var chipHelp: String {
        var parts: [String] = [isMain ? "The folder itself" : "A worktree"]
        if missing {
            parts.append("its folder is gone")
        } else {
            if changed > 0 { parts.append("\(changed) \(changed == 1 ? "file" : "files") changed") }
            if ahead > 0 { parts.append("\(ahead) \(ahead == 1 ? "commit" : "commits") ahead") }
            if inUse { parts.append("a session runs in it") }
        }
        return parts.joined(separator: ", ")
    }
}

extension WorktreeInfo {
    /// What a worktree is called where the folder's worktrees are listed:
    /// its branch, and for the folder's own the folder first.
    public var menuTitle: String {
        let folder = (path as NSString).lastPathComponent
        if isMain { return folder + (branch.map { " · \($0)" } ?? "") }
        return branch ?? folder
    }

    /// What is said of it after its name, short enough for a row to be
    /// read at a glance (#56). A worktree AgentTerm did not make is told
    /// from another by the name of its folder, not by its whole path,
    /// which is what a tooltip is for.
    public var menuDetail: String {
        if missing { return "missing: its folder is gone" }
        var parts: [String] = []
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if changed > 0 { parts.append("\(changed) changed") }
        let folder = (path as NSString).lastPathComponent
        if !isAgentTerm && !isMain && folder != menuTitle { parts.append("in \(folder)") }
        if inUse { parts.append("in use") }
        return parts.joined(separator: ", ")
    }
}

/// What to do with a worktree whose work is finished (#23).
public enum WorktreeFinish: String, Codable, Sendable {
    /// Merge its branch into the folder's branch, then remove it.
    case merge
    /// Push its branch and open a pull request with `gh`; it is kept.
    case pullRequest
    /// Remove it, and what is in it.
    case discard
}
