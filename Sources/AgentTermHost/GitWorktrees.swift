#if os(macOS)
import AgentTermProtocol
import Foundation

/// A repository's git worktrees (#23, #33): those AgentTerm makes for a
/// session, in `<project>/.agentterm/worktrees/<branch>`, and any other.
public enum GitWorktrees {
    public struct Failure: Error, LocalizedError, Equatable {
        public var text: String
        public var errorDescription: String? { text }
    }

    private static func git(_ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil) -> (status: Int32, output: String) {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory] + arguments, timeout: timeout, mergeErrors: true, environment: environment)
        return (result?.status ?? -1, String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ arguments: [String], in directory: String, timeout: TimeInterval = 30, environment: [String: String]? = nil) throws -> String {
        let result = git(arguments, in: directory, timeout: timeout, environment: environment)
        guard result.status == 0 else { throw Failure(text: result.output.isEmpty ? "git \(arguments.first ?? "") failed." : result.output) }
        return result.output
    }

    /// The top of the folder's repository, written the way the folder is
    /// written: git gives the real path, and a folder opened through a
    /// symbolic link (`/var`, `/tmp`) would not be found in it.
    static func top(of folder: String) throws -> (asWritten: String, real: String) {
        let real = try run(["rev-parse", "--show-toplevel"], in: folder)
        let prefix = (try? run(["rev-parse", "--show-prefix"], in: folder)) ?? ""
        var written = folder
        if !prefix.isEmpty, written.hasSuffix("/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            written = String(written.dropLast(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).count + 1))
        }
        return (written, real)
    }

    /// A path git gave, written the way the folder is.
    private static func written(_ path: String, top: (asWritten: String, real: String)) -> String {
        guard top.asWritten != top.real, path == top.real || path.hasPrefix(top.real + "/") else { return path }
        return top.asWritten + path.dropFirst(top.real.count)
    }

    /// Where the repository's own worktree is checked out. For a submodule
    /// git names the repository's folder under the parent's `.git/modules`
    /// instead (#216), which holds no files; the checkout is where that
    /// folder's `core.worktree` leads. A bare repository has none, and
    /// keeps the path git named.
    private static func ownCheckout(_ named: String, of folder: String) -> String {
        guard let common = try? run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder), common == named,
            let checkout = try? run(["rev-parse", "--show-toplevel"], in: named), !checkout.isEmpty
        else { return named }
        return checkout
    }

    /// The folder's repository's worktrees, the repository's own first.
    /// `inUse` names the folders sessions run in.
    public static func list(folder: String, inUse: Set<String> = []) -> [WorktreeInfo] {
        guard let porcelain = try? run(["worktree", "list", "--porcelain"], in: folder), let top = try? top(of: folder) else { return [] }
        let base = (try? run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)) ?? "HEAD"
        var list: [WorktreeInfo] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?
            var branch: String?
            var prunable = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    let named = String(line.dropFirst("worktree ".count))
                    path = written(list.isEmpty ? ownCheckout(named, of: folder) : named, top: top)
                }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("prunable") { prunable = true }
            }
            guard let path else { continue }
            let missing = prunable || !FileManager.default.fileExists(atPath: path)
            var info = WorktreeInfo(
                path: path, branch: branch, isMain: list.isEmpty, missing: missing,
                isAgentTerm: WorktreePath.project(of: path) != nil)
            if !info.isMain, let branch {
                info.ahead = Int((try? run(["rev-list", "--count", "\(base)..\(branch)"], in: folder)) ?? "") ?? 0
            }
            if !missing {
                info.changed = ((try? run(["status", "--porcelain"], in: path)) ?? "").split(separator: "\n").count
            }
            list.append(info)
        }
        // A session is in the deepest worktree its folder is in: one in a
        // worktree inside the project is not in the project's own.
        // Compared as real paths: a session's folder may be written another way.
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let roots = list.map { real($0.path) }
        for used in inUse.map(real) {
            let holding = roots.indices.filter { used == roots[$0] || used.hasPrefix(roots[$0] + "/") }
            if let deepest = holding.max(by: { roots[$0].count < roots[$1].count }) { list[deepest].inUse = true }
        }
        return list
    }

    /// Makes a worktree of the folder's repository on a new branch cut from
    /// its current commit, or from the branch named (#43), and returns
    /// where to start the session: the same folder inside it. Nothing is
    /// brought along: no uncommitted change, nothing git ignores.
    public static func create(in folder: String, agent: String, branch wanted: String?, from: String? = nil) throws -> (directory: String, branch: String) {
        let top = try top(of: folder).asWritten
        // A worktree made from one made by AgentTerm goes next to the others.
        let projectTop = WorktreePath.project(of: top) ?? top
        let taken = Set(((try? run(["branch", "--list", "--format=%(refname:short)"], in: folder)) ?? "").split(separator: "\n").map(String.init))
        let branch = (wanted?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? WorktreePath.branchName(agent: agent, taken: taken)
        guard (try? run(["check-ref-format", "--branch", branch], in: folder)) != nil else { throw Failure(text: "“\(branch)” is not a name a branch can have.") }
        guard !taken.contains(branch) else { throw Failure(text: "A branch called “\(branch)” is there already.") }
        let root = URL(fileURLWithPath: projectTop).appendingPathComponent(WorktreePath.folder).appendingPathComponent(branch).path
        Handoff.keepOutOfGit(projectTop)
        try FileManager.default.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let start = (from?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
        guard start == "HEAD" || git(["rev-parse", "--verify", "--quiet", "--end-of-options", start + "^{commit}"], in: folder).status == 0 else {
            throw Failure(text: "There is no branch “\(start)” to start from.")
        }
        // The new branch follows nothing: cut from a branch of a remote, it
        // would otherwise be set to push to that one.
        _ = try run(["worktree", "add", "--no-track", "-b", branch, root, start], in: folder, timeout: 120)
        // The folder's place in its own checkout, in the new one: from the
        // top of the worktree it is in, not from the project's.
        let inside = folder.hasPrefix(top + "/") ? String(folder.dropFirst(top.count)) : ""
        return (root + inside, branch)
    }

    /// Checks out the submodules of a new worktree, theirs too (#44): git
    /// leaves their folders empty. Nil when there are none or all went
    /// well; otherwise what git said, for the worktree is made all the same.
    ///
    /// Each is cloned from the repository's own checkout of it, which is on
    /// this Mac already, and its remote set back to its URL; only one that
    /// is not checked out there is fetched from its URL (#244, the owner's
    /// decision of 2026-11-22: cloned again from GitHub, `~/Project/apps`'
    /// took minutes and some 500 MB a worktree). `progress` is told which
    /// one of the worktree's own is being checked out, and of how many.
    public static func checkOutSubmodules(in directory: String, progress: ((_ done: Int, _ count: Int, _ name: String) -> Void)? = nil) -> String? {
        guard let top = try? top(of: directory).asWritten, FileManager.default.fileExists(atPath: top + "/.gitmodules") else { return nil }
        // The repository's own checkout: the first of its worktrees.
        let porcelain = (try? run(["worktree", "list", "--porcelain"], in: top)) ?? ""
        let first = porcelain.split(separator: "\n").first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        let main = first.map { ownCheckout($0, of: top) }
        var problems: [String] = []
        checkOutSubmodules(of: top, mainCheckout: main == top ? nil : main, problems: &problems, progress: progress)
        guard !problems.isEmpty else { return nil }
        return "The submodules of the new worktree could not be checked out: their folders are empty there.\n\n\(String(problems.joined(separator: "\n\n").suffix(1500)))"
    }

    /// The submodules `.gitmodules` names at the top of `checkout`, as
    /// their names and their paths, in the order it gives them.
    private static func submodules(of checkout: String) -> [(name: String, path: String)] {
        let lines = (try? run(["config", "--file", ".gitmodules", "--get-regexp", #"^submodule\..*\.path$"#], in: checkout)) ?? ""
        return lines.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let key = line[..<space]
            guard key.hasPrefix("submodule."), key.hasSuffix(".path") else { return nil }
            let name = String(key.dropFirst("submodule.".count).dropLast(".path".count))
            return (name, String(line[line.index(after: space)...]))
        }
    }

    /// The git folder of the submodule checked out at `path` in `checkout`;
    /// nil when it is not checked out there, its folder empty or missing,
    /// where git would answer for the repository around it.
    private static func checkedOutGitDirectory(_ path: String, in checkout: String) -> String? {
        let folder = (checkout as NSString).appendingPathComponent(path)
        guard let own = try? run(["rev-parse", "--show-toplevel"], in: folder),
            URL(fileURLWithPath: own).resolvingSymlinksInPath().path == URL(fileURLWithPath: folder).resolvingSymlinksInPath().path,
            let directory = try? run(["rev-parse", "--absolute-git-dir"], in: folder)
        else { return nil }
        return directory
    }

    private static func checkOutSubmodules(of checkout: String, mainCheckout: String?, problems: inout [String], progress: ((Int, Int, String) -> Void)?) {
        let list = submodules(of: checkout)
        for (index, submodule) in list.enumerated() {
            progress?(index, list.count, submodule.name)
            let folder = (checkout as NSString).appendingPathComponent(submodule.path)
            let theirs = mainCheckout.flatMap { checkedOutGitDirectory(submodule.path, in: $0) }
            var done = false
            if let theirs, let url = try? run(["config", "--file", ".gitmodules", "submodule.\(submodule.name).url"], in: checkout) {
                // Its URL written into the worktree's configuration first:
                // given only on the command line, `--init` took it for one
                // there already and left a submodule inside it uninitialized
                // (tried with git 2.54.0). The clone from the folder's own
                // copy needs the file transport, which git allows a
                // submodule only when asked (2.38.1).
                let cloned =
                    git(["submodule", "init", "--", submodule.path], in: checkout).status == 0
                    && git(
                        ["-c", "protocol.file.allow=always", "-c", "submodule.\(submodule.name).url=\(theirs)", "submodule", "update", "--", submodule.path],
                        in: checkout, timeout: 900, environment: GitActions.actionEnvironment
                    ).status == 0
                // Pushed and fetched where it comes from, not from the copy.
                if cloned, git(["remote", "set-url", "origin", url], in: folder).status == 0 { done = true }
            }
            if !done {
                // Not checked out in the folder, or the copy failed: fetched
                // from its URL, which may take a while.
                let fetched = git(["submodule", "update", "--init", "--", submodule.path], in: checkout, timeout: 900, environment: GitActions.actionEnvironment)
                guard fetched.status == 0 else {
                    problems.append(fetched.output)
                    continue
                }
            }
            // Those inside it, from the same submodule's own checkout.
            checkOutSubmodules(of: folder, mainCheckout: mainCheckout.map { ($0 as NSString).appendingPathComponent(submodule.path) }, problems: &problems, progress: nil)
        }
    }

    /// Merges, opens a pull request for, or throws away a worktree. What
    /// was done, in words: a pull request's address, for one.
    public static func finish(folder: String, path: String, finish: WorktreeFinish, deleteBranch: Bool) throws -> String {
        let worktrees = list(folder: folder)
        guard let worktree = worktrees.first(where: { $0.path == path }), !worktree.isMain else { throw Failure(text: "That is not a worktree of this folder.") }
        let branch = worktree.branch
        switch finish {
        case .merge:
            guard let branch else { throw Failure(text: "Its HEAD is detached: there is no branch to merge.") }
            guard worktree.changed == 0 else { throw Failure(text: "It has changes that are not committed: commit or discard them first.") }
            let merged = git(["merge", "--no-edit", branch], in: folder, timeout: 120, environment: GitActions.actionEnvironment)
            guard merged.status == 0 else {
                // Stopped on conflicts: left to be resolved in the folder
                // and continued, or aborted (#42). The worktree stays.
                guard GitActions.operation(in: folder) == .merge else { throw Failure(text: merged.output) }
                throw Failure(
                    text: GitActions.stoppedOnConflicts("Merging \(branch)", as: "merge", said: merged.output)
                        + "\n\nThe worktree is kept: once the merge is finished, throw it away from its menu.")
            }
            _ = try run(["worktree", "remove", path], in: folder)
            if deleteBranch { _ = try run(["branch", "-d", branch], in: folder) }
            return "Merged \(branch) and removed its worktree."
        case .pullRequest:
            guard let branch else { throw Failure(text: "Its HEAD is detached: there is no branch to push.") }
            _ = try run(["push", "--set-upstream", "origin", branch], in: path, timeout: 120, environment: GitActions.actionEnvironment)
            // gh is the user's, found through their shell.
            let line = "gh pr create --fill --head " + Handoff.shellQuote(branch)
            guard
                let result = Subprocess.run(
                    HostEnvironment.shell, ["-l", "-i", "-c", line], cwd: path, timeout: 120, mergeErrors: true,
                    environment: HostEnvironment.loginShellCommandEnvironment)
            else {
                throw Failure(text: "gh could not be started.")
            }
            let said = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0 else { throw Failure(text: said.isEmpty ? "gh could not open the pull request." : said) }
            return said.split(separator: "\n").last.map(String.init) ?? said
        case .discard:
            _ = try run(["worktree", "remove", "--force", path], in: folder)
            if deleteBranch, let branch { _ = try run(["branch", "-D", branch], in: folder) }
            return "Removed the worktree" + (deleteBranch && branch != nil ? " and its branch." : ".")
        }
    }
}
#endif
