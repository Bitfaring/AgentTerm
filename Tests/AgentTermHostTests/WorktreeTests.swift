import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// A git worktree of its own for each session (#23), and the worktrees of
/// the folder that is open (#33).
final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wt-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        try write("a.txt", "one\n")
        git("add", ".")
        git("commit", "-q", "-m", "init")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", (directory ?? project).path] + arguments, timeout: 30, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ name: String, _ text: String, in directory: URL? = nil) throws {
        try text.write(to: (directory ?? project).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// WT-21 (#216): a submodule's own worktree is its folder: git names the
    /// repository's folder under the parent's `.git/modules` instead.
    func testASubmodulesOwnWorktreeIsItsFolder() throws {
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: parent)
        git("config", "user.name", "Test", in: parent)
        git("config", "user.email", "test@example.com", in: parent)
        git("config", "commit.gpgsign", "false", in: parent)
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", project.path, "sub", in: parent)
        git("commit", "-q", "-m", "sub", in: parent)
        let sub = parent.appendingPathComponent("sub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.txt").path), "the submodule is checked out")

        let list = GitWorktrees.list(folder: sub.path)
        XCTAssertEqual(list.map(\.path), [sub.path])
        XCTAssertEqual(list.first?.isMain, true)
        XCTAssertEqual(list.first?.branch, "main")
    }

    /// A repository with the project as its submodule `sub`, committed, and
    /// the submodule able to commit. Returns the submodule's folder.
    private func parentWithSubmodule() throws -> (parent: URL, sub: URL) {
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: parent)
        git("config", "user.name", "Test", in: parent)
        git("config", "user.email", "test@example.com", in: parent)
        git("config", "commit.gpgsign", "false", in: parent)
        git("-c", "protocol.file.allow=always", "submodule", "add", "-q", project.path, "sub", in: parent)
        git("commit", "-q", "-m", "sub", in: parent)
        let sub = parent.appendingPathComponent("sub")
        git("config", "user.name", "Test", in: sub)
        git("config", "user.email", "test@example.com", in: sub)
        git("config", "commit.gpgsign", "false", in: sub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.appendingPathComponent("a.txt").path), "the submodule is checked out")
        return (parent, sub)
    }

    /// WT-21 (#216): a worktree of a submodule is made under the
    /// submodule's own folder, as any repository's, listed after the
    /// submodule's folder, and is a change neither of the submodule nor of
    /// the repository it is in; what is committed in it merges back, and
    /// its folder and branch go with it.
    func testASubmodulesWorktreeIsMadeListedAndMergedBack() throws {
        let (parent, sub) = try parentWithSubmodule()
        let made = try GitWorktrees.create(in: sub.path, agent: "claude", branch: nil)
        XCTAssertEqual(made.branch, "agentterm/claude-1")
        XCTAssertEqual(made.directory, sub.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)
        let worktree = URL(fileURLWithPath: made.directory)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        var list = GitWorktrees.list(folder: sub.path)
        XCTAssertEqual(list.map(\.path), [sub.path, made.directory])
        XCTAssertEqual(list.map(\.branch), ["main", "agentterm/claude-1"])
        XCTAssertEqual(list.map(\.isMain), [true, false])
        XCTAssertEqual(list.map(\.missing), [false, false])
        XCTAssertEqual(list.last?.isAgentTerm, true)
        // Listed the same from inside the worktree, the submodule's folder first.
        XCTAssertEqual(GitWorktrees.list(folder: made.directory).map(\.branch), ["main", "agentterm/claude-1"])
        // Not a change of the submodule, nor of the repository it is in.
        XCTAssertEqual(git("status", "--porcelain", in: sub), "")
        XCTAssertEqual(GitDiff.snapshot(directory: sub.path).files.map(\.path), [])
        XCTAssertEqual(git("status", "--porcelain", in: parent), "")
        XCTAssertEqual(GitDiff.snapshot(directory: parent.path).files.map(\.path), [])

        // Not merged while not committed; committed, it is ahead by one.
        try write("a.txt", "one\nthe worktree's\n", in: worktree)
        list = GitWorktrees.list(folder: sub.path)
        XCTAssertEqual(list[1].changed, 1)
        XCTAssertEqual(list[0].changed, 0, "the submodule's own folder has no change of the worktree's")
        XCTAssertThrowsError(try GitWorktrees.finish(folder: sub.path, path: made.directory, finish: .merge, deleteBranch: true))
        git("commit", "-qam", "the worktree's", in: worktree)
        list = GitWorktrees.list(folder: sub.path)
        XCTAssertEqual(list[1].ahead, 1)
        XCTAssertEqual(list[1].changed, 0)
        XCTAssertEqual(git("status", "--porcelain", in: parent), "", "a commit on the worktree's branch moves nothing of the submodule")

        XCTAssertEqual(
            try GitWorktrees.finish(folder: sub.path, path: made.directory, finish: .merge, deleteBranch: true), "Merged agentterm/claude-1 and removed its worktree.")
        XCTAssertEqual(try String(contentsOf: sub.appendingPathComponent("a.txt"), encoding: .utf8), "one\nthe worktree's\n")
        XCTAssertEqual(git("log", "-1", "--format=%s", in: sub), "the worktree's")
        XCTAssertEqual(git("rev-parse", "--abbrev-ref", "HEAD", in: sub), "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory), "removed")
        XCTAssertEqual(git("branch", "--list", "agentterm/claude-1", in: sub), "", "its branch too, as asked")
        XCTAssertEqual(GitWorktrees.list(folder: sub.path).map(\.path), [sub.path])
        // The submodule is at another commit now, which is all its repository sees.
        XCTAssertEqual(git("status", "--porcelain", in: parent), "M sub")
        XCTAssertEqual(git("-C", sub.path, "status", "--porcelain"), "")
    }

    /// WT-21 (#216): a submodule's worktree is thrown away with what is in
    /// it and with its branch, and one whose folder is gone too.
    func testASubmodulesWorktreeIsThrownAway() throws {
        let (parent, sub) = try parentWithSubmodule()
        let made = try GitWorktrees.create(in: sub.path, agent: "codex", branch: "work")
        XCTAssertEqual(made.directory, sub.appendingPathComponent(".agentterm/worktrees/work").path)
        try write("a.txt", "not committed\n", in: URL(fileURLWithPath: made.directory))
        try write("new.txt", "not committed either\n", in: URL(fileURLWithPath: made.directory))
        XCTAssertEqual(GitWorktrees.list(folder: sub.path).last?.changed, 2)
        XCTAssertEqual(git("status", "--porcelain", in: parent), "")

        XCTAssertEqual(try GitWorktrees.finish(folder: sub.path, path: made.directory, finish: .discard, deleteBranch: true), "Removed the worktree and its branch.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.directory))
        XCTAssertEqual(git("branch", "--list", "work", in: sub), "", "its branch too, as asked")
        XCTAssertEqual(try String(contentsOf: sub.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        // Its folder gone before it is thrown away, the branch kept.
        let gone = try GitWorktrees.create(in: sub.path, agent: "codex", branch: "gone")
        try FileManager.default.removeItem(atPath: gone.directory)
        let list = GitWorktrees.list(folder: sub.path)
        XCTAssertEqual(list.map(\.path), [sub.path, gone.directory])
        XCTAssertEqual(list.map(\.missing), [false, true])
        XCTAssertEqual(try GitWorktrees.finish(folder: sub.path, path: gone.directory, finish: .discard, deleteBranch: false), "Removed the worktree.")
        XCTAssertEqual(GitWorktrees.list(folder: sub.path).map(\.path), [sub.path])
        XCTAssertNotEqual(git("branch", "--list", "gone", in: sub), "", "the branch stays when not asked")
        XCTAssertEqual(git("status", "--porcelain", in: parent), "")
        XCTAssertEqual(git("status", "--porcelain", in: sub), "")
    }

    /// WT-1: a worktree on a branch of its own, cut from the current commit,
    /// inside the project, bringing nothing along, which git does not see.
    func testANewWorktreeIsACleanCheckoutOnABranchOfItsOwn() throws {
        try write("a.txt", "one\nnot committed\n")
        try write(".env", "SECRET=1\n")
        git("config", "core.excludesFile", "/dev/null")
        try "/.env\n".write(to: project.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let made = try GitWorktrees.create(in: project.path, agent: "claude", branch: nil)
        XCTAssertEqual(made.branch, "agentterm/claude-1")
        XCTAssertEqual(made.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path)
        let worktree = URL(fileURLWithPath: made.directory)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("a.txt"), encoding: .utf8), "one\n", "uncommitted changes stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path), "what git ignores stays")
        XCTAssertEqual(git("rev-parse", "HEAD", in: worktree), git("rev-parse", "HEAD"))
        // git does not see it as a change of the project.
        XCTAssertEqual(git("status", "--porcelain").split(separator: "\n").map(String.init), ["M a.txt"])
        // The next is numbered after it; a name already taken is refused.
        XCTAssertEqual(try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).branch, "agentterm/claude-2")
        XCTAssertThrowsError(try GitWorktrees.create(in: project.path, agent: "claude", branch: "agentterm/claude-1"))
    }

    /// WT-2: two sessions change the same file without touching each other's;
    /// merging brings the changes back and removes the worktree.
    func testTwoWorktreesChangeTheSameFileApartAndMergeBack() throws {
        let first = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).directory)
        let second = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "codex", branch: nil).directory)
        try write("a.txt", "one\nfirst\n", in: first)
        try write("a.txt", "one\nsecond\n", in: second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        // Unmerged work is listed as such, and is not merged while not committed.
        var list = GitWorktrees.list(folder: project.path)
        XCTAssertEqual(list.map(\.branch), ["main", "agentterm/claude-1", "agentterm/codex-1"])
        XCTAssertEqual(list[1].changed, 1)
        XCTAssertTrue(list[1].hasUnmergedWork && list[1].isAgentTerm && !list[1].isMain)
        XCTAssertThrowsError(try GitWorktrees.finish(folder: project.path, path: first.path, finish: .merge, deleteBranch: true))

        git("commit", "-qam", "first", in: first)
        list = GitWorktrees.list(folder: project.path)
        XCTAssertEqual(list[1].ahead, 1)
        XCTAssertEqual(list[1].changed, 0)
        _ = try GitWorktrees.finish(folder: project.path, path: first.path, finish: .merge, deleteBranch: true)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "one\nfirst\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "removed")
        XCTAssertEqual(git("branch", "--list", "agentterm/claude-1"), "", "its branch too, as asked")

        // Thrown away, with what is in it, only when asked to.
        _ = try GitWorktrees.finish(folder: project.path, path: second.path, finish: .discard, deleteBranch: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotEqual(git("branch", "--list", "agentterm/codex-1"), "", "the branch stays when not asked")
    }

    /// WT-13 (#43): a worktree is cut from the branch that is named, of a
    /// remote too, and its new branch follows nothing; a branch that is
    /// not there is refused, and nothing is left behind.
    func testAWorktreeIsCutFromTheBranchPicked() throws {
        git("checkout", "-q", "-b", "other")
        try write("b.txt", "other's\n")
        git("add", ".")
        git("commit", "-q", "-m", "other")
        git("update-ref", "refs/remotes/origin/theirs", "HEAD")
        git("checkout", "-q", "main")

        let made = try GitWorktrees.create(in: project.path, agent: "claude", branch: "from-other", from: "other")
        XCTAssertEqual(git("rev-parse", "HEAD", in: URL(fileURLWithPath: made.directory)), git("rev-parse", "other"))
        let remote = try GitWorktrees.create(in: project.path, agent: "claude", branch: "from-theirs", from: "origin/theirs")
        XCTAssertEqual(git("rev-parse", "HEAD", in: URL(fileURLWithPath: remote.directory)), git("rev-parse", "other"))
        XCTAssertEqual(git("config", "--get", "branch.from-theirs.merge"), "", "it does not follow the branch it was cut from")
        // From nothing named: the folder's commit, as before.
        let plain = try GitWorktrees.create(in: project.path, agent: "claude", branch: "plain", from: " ")
        XCTAssertEqual(git("rev-parse", "HEAD", in: URL(fileURLWithPath: plain.directory)), git("rev-parse", "main"))

        XCTAssertThrowsError(try GitWorktrees.create(in: project.path, agent: "claude", branch: "lost", from: "no-such")) {
            XCTAssertEqual($0.localizedDescription, "There is no branch “no-such” to start from.")
        }
        XCTAssertEqual(git("branch", "--list", "lost"), "")
        XCTAssertEqual(GitWorktrees.list(folder: project.path).count, 4)
    }

    /// WT-14 (#43): a worktree of the repository made inside it by someone
    /// else, as Claude Code's `.claude/worktrees` are, is listed with the
    /// others and is not a change of the folder; a repository of another
    /// kind inside it still is what git says.
    func testAWorktreeInsideTheRepositoryIsNotAnUntrackedFile() throws {
        git("worktree", "add", "-q", "-b", "claude-made", ".claude/worktrees/claude-made")
        let inside = project.appendingPathComponent(".claude/worktrees/claude-made")
        try write("inside.txt", "in the worktree\n", in: inside)
        try write("new.txt", "the folder's own\n")
        XCTAssertTrue(git("status", "--porcelain").contains(".claude/"), "git itself lists it")

        XCTAssertEqual(GitDiff.snapshot(directory: project.path).files.map(\.path), ["new.txt"])
        let list = GitWorktrees.list(folder: project.path)
        XCTAssertEqual(list.map(\.branch), ["main", "claude-made"])
        XCTAssertEqual(list[1].changed, 1)
        XCTAssertFalse(list[1].isAgentTerm)
        // Seen from inside that worktree, its own change, and not its neighbours.
        git("worktree", "add", "-q", "-b", "nested", inside.appendingPathComponent("deeper").path, in: inside)
        XCTAssertEqual(GitDiff.snapshot(directory: inside.path).files.map(\.path), ["inside.txt"])
    }

    /// WT-15 (#42, #43): a worktree whose merge conflicts is left merging
    /// in the folder, to be resolved and continued there, or aborted; the
    /// worktree is kept.
    func testAWorktreesMergeThatConflictsIsLeftToBeResolved() throws {
        let worktree = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "claude", branch: "work").directory)
        try write("a.txt", "the worktree's\n", in: worktree)
        git("commit", "-qam", "work", in: worktree)
        try write("a.txt", "the folder's\n")
        git("commit", "-qam", "main")

        XCTAssertThrowsError(try GitWorktrees.finish(folder: project.path, path: worktree.path, finish: .merge, deleteBranch: true)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Merging work stopped on conflicts."), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("The worktree is kept"), $0.localizedDescription)
        }
        let state = GitDiff.snapshot(directory: project.path)
        XCTAssertEqual(state.operation, .merge)
        XCTAssertEqual(state.conflicts.map(\.path), ["a.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertNil(GitActions.resolve("a.txt", as: .theirs, in: project.path))
        XCTAssertNil(GitActions.continueOperation(in: project.path))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "the worktree's\n")
        // Merged now: thrown away with nothing lost.
        XCTAssertFalse(try XCTUnwrap(GitWorktrees.list(folder: project.path).last).hasUnmergedWork)
    }

    /// WT-3 (#33): any worktree is listed, one made by hand outside the
    /// folder too, and one whose folder is gone as missing.
    func testEveryWorktreeIsListedTheMissingToo() throws {
        let outside = root.appendingPathComponent("by-hand")
        git("worktree", "add", "-q", "-b", "by-hand", outside.path)
        let gone = root.appendingPathComponent("gone")
        git("worktree", "add", "-q", "-b", "gone", gone.path)
        try FileManager.default.removeItem(at: gone)
        let list = GitWorktrees.list(folder: project.path, inUse: [outside.path + "/sub"])
        // The folder's own as it is written; the others as git gives them.
        XCTAssertEqual(list.first?.path, project.path)
        func plain(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        XCTAssertEqual(list.dropFirst().map { plain($0.path) }, [outside.path, gone.path].map(plain))
        XCTAssertTrue(list[0].isMain)
        XCTAssertFalse(list[1].isAgentTerm)
        XCTAssertTrue(list[1].inUse, "a session runs in a folder inside it")
        XCTAssertTrue(list[2].missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path), "nothing is removed by listing")
    }

    /// WT-19 (#217): a worktree whose folder is gone is thrown away all the
    /// same, which is all its row offers: git forgets it, and its branch
    /// goes when asked and stays when not.
    func testAWorktreeWhoseFolderIsGoneIsThrownAway() throws {
        let made = URL(fileURLWithPath: try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).directory)
        let byHand = root.appendingPathComponent("by-hand")
        git("worktree", "add", "-q", "-b", "by-hand", byHand.path)
        try FileManager.default.removeItem(at: made)
        try FileManager.default.removeItem(at: byHand)
        // Listed in git's order, by the path git has for each.
        func listed(_ branch: String) throws -> WorktreeInfo { try XCTUnwrap(GitWorktrees.list(folder: project.path).first { $0.branch == branch }, "\(branch) is not listed") }
        XCTAssertEqual(Set(GitWorktrees.list(folder: project.path).map(\.branch)), ["main", "agentterm/claude-1", "by-hand"])
        XCTAssertTrue(try listed("agentterm/claude-1").missing)
        XCTAssertTrue(try listed("by-hand").missing)

        // With its branch, as asked.
        XCTAssertEqual(
            try GitWorktrees.finish(folder: project.path, path: try listed("agentterm/claude-1").path, finish: .discard, deleteBranch: true),
            "Removed the worktree and its branch.")
        XCTAssertEqual(GitWorktrees.list(folder: project.path).map(\.branch), ["main", "by-hand"])
        XCTAssertEqual(git("branch", "--list", "agentterm/claude-1"), "", "its branch too, as asked")

        // Keeping its branch.
        XCTAssertEqual(try GitWorktrees.finish(folder: project.path, path: try listed("by-hand").path, finish: .discard, deleteBranch: false), "Removed the worktree.")
        XCTAssertEqual(GitWorktrees.list(folder: project.path).map(\.branch), ["main"])
        XCTAssertNotEqual(git("branch", "--list", "by-hand"), "", "the branch stays when not asked")
        XCTAssertFalse(git("worktree", "list", "--porcelain").contains("prunable"), "git still knows of a worktree that is gone")
    }

    /// WT-9: what watches a worktree sees its branches change in the
    /// repository's own git folder, as a push or a fetch in a terminal
    /// changes them.
    func testAWorktreesWatchSeesTheRepositorysBranches() throws {
        let worktree = try GitWorktrees.create(in: project.path, agent: "claude", branch: nil).directory
        var changes = 0
        let watch = FolderWatch(paths: FolderWatch.paths(for: worktree), latency: 0.1, queue: .main) { changes += 1 }
        XCTAssertNotNil(watch)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        changes = 0
        // What a push of its branch writes.
        git("update-ref", "refs/remotes/origin/agentterm/claude-1", "HEAD")
        let deadline = Date().addingTimeInterval(5)
        while changes == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(changes, 0, "the push was not seen")
        withExtendedLifetime(watch) {}
    }

    /// WT-10: a worktree made from a folder inside one AgentTerm made goes
    /// next to it, and its session starts in the same folder inside it.
    func testAWorktreeMadeFromInsideAnotherStartsInTheSameFolder() throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try write("sub/b.txt", "two\n")
        git("add", ".")
        git("commit", "-q", "-m", "sub")
        let first = try GitWorktrees.create(in: project.appendingPathComponent("sub").path, agent: "claude", branch: nil)
        XCTAssertEqual(first.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1/sub").path)
        let second = try GitWorktrees.create(in: first.directory, agent: "claude", branch: nil)
        XCTAssertEqual(second.directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-2/sub").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory + "/b.txt"))
        // From the top of one, the top of the next.
        let top = project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path
        XCTAssertEqual(try GitWorktrees.create(in: top, agent: "claude", branch: nil).directory, project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-3").path)
    }

    func testWhereAWorktreesSessionBelongs() {
        XCTAssertEqual(WorktreePath.project(of: "/p/.agentterm/worktrees/agentterm/claude-1"), "/p")
        XCTAssertNil(WorktreePath.project(of: "/p/src"))
        XCTAssertTrue(WorktreePath.belongs("/p/.agentterm/worktrees/x/sub", to: "/p"))
        XCTAssertFalse(WorktreePath.belongs("/q/.agentterm/worktrees/x", to: "/p"))
        XCTAssertEqual(WorktreePath.branchName(agent: "codex", taken: ["agentterm/codex-1"]), "agentterm/codex-2")
    }
}

/// WT-4, WT-5: through the host, with a stand-in agent.
final class WorktreeHostTests: XCTestCase {
    private final class Client {
        let connection: AgentTermConnection
        var messages: [ServerMessage] = []

        init(port: UInt16, token: String) {
            connection = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
            connection.onMessage = { [weak self] in self?.messages.append($0) }
            connection.connect()
        }

        var sessions: [SessionInfo] { messages.compactMap { if case .sessions(let list) = $0 { return list } else { return nil } }.last ?? [] }
        var worktrees: [WorktreeInfo] { messages.compactMap { if case .worktrees(_, let list) = $0 { return list } else { return nil } }.last ?? [] }
        var errors: [String] { messages.compactMap { if case .error(let text, _) = $0 { return text } else { return nil } } }
        /// Every list of the worktrees being made it was sent, in order.
        var inProgress: [[WorktreeInProgress]] { messages.compactMap { if case .worktreesInProgress(let list) = $0 { return list } else { return nil } } }
    }

    private var root: URL!
    private var server: HostServer!
    private var client: Client!
    private var port: UInt16 = 0
    private let token = "test-token-0123456789abcdef0123456789"
    private var project: URL { root.appendingPathComponent("project") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-wth-\(UUID().uuidString)").standardizedFileURL
        let agents = root.appendingPathComponent("agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@example.com"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            _ = Subprocess.run("/usr/bin/git", ["-C", project.path, "-c", "commit.gpgsign=false"] + arguments, timeout: 30)
        }
        try "#!/bin/sh\nexec sleep 600\n".write(to: agents.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.appendingPathComponent("claude").path)
        var configuration = HostServer.Configuration(port: 0, token: token, listenOnTailscale: false, detectAgents: { AgentDetector.detect(in: agents.path) })
        configuration.agentsDirectory = agents.path
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        server = HostServer(configuration: configuration)
        port = try server.start()
        client = Client(port: port, token: token)
        waitUntil("connected") { !self.client.messages.isEmpty }
    }

    override func tearDown() {
        server?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    /// WT-4: a session started in a new worktree runs there, with its branch;
    /// nothing git ignores came along, what it needs being done there by its
    /// user (#75).
    func testASessionInANewWorktreeRunsThereWithItsBranch() throws {
        try "SECRET=1\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try ".env\n".write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path, title: "Claude Code"), branch: nil, from: nil))
        waitUntil("the session") { self.client.sessions.count == 1 && self.client.sessions[0].branch != nil }
        let session = try XCTUnwrap(client.sessions.first)
        let path = project.appendingPathComponent(".agentterm/worktrees/agentterm/claude-1").path
        XCTAssertEqual(session.cwd, path)
        XCTAssertEqual(session.branch, "agentterm/claude-1")
        XCTAssertEqual(session.agent, "claude")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/.env"), "an ignored file came along")
        XCTAssertTrue(WorktreePath.belongs(session.cwd, to: project.path))
        waitUntil("the worktrees") { self.client.worktrees.count == 2 }
        XCTAssertTrue(client.worktrees[1].inUse)
    }

    /// WT-16 (#43): a session is started in a worktree cut from the branch
    /// named; one from a branch that is not there is refused at once.
    func testASessionStartsInAWorktreeFromABranch() throws {
        // Each step says why, should it fail: a lock the host took once
        // made the commit fail here, and the test only timed out (#50).
        for arguments in [["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", "second"], ["branch", "older", "HEAD~1"]] {
            let ran = Subprocess.run("/usr/bin/git", ["-C", project.path] + arguments, timeout: 30, mergeErrors: true)
            XCTAssertEqual(ran?.status, 0, "git \(arguments.joined(separator: " ")): \(String(decoding: ran?.output ?? Data(), as: UTF8.self))")
        }
        client.connection.send(.createInWorktree(request: CreateRequest(command: nil, cwd: project.path), branch: "from-older", from: "older"))
        waitUntil("the session") { self.client.sessions.first?.branch == "from-older" || !self.client.errors.isEmpty }
        XCTAssertEqual(client.errors, [], "the worktree was refused")
        let cwd = try XCTUnwrap(client.sessions.first?.cwd)
        func head(_ arguments: String...) -> String {
            String(decoding: Subprocess.run("/usr/bin/git", ["-C", cwd, "rev-parse"] + arguments, timeout: 30)?.output ?? Data(), as: UTF8.self)
        }
        XCTAssertEqual(head("HEAD"), head("older"))
        // One that cannot be made says why at once.
        client.connection.send(.createInWorktree(request: CreateRequest(command: nil, cwd: project.path), branch: "x", from: "no-such"))
        waitUntil("refused") { self.client.errors.contains { $0.contains("There is no branch “no-such” to start from.") } }
    }

    /// WT-25 (#244): while a worktree is made, every device is told what is
    /// being done: making it, then each of its submodules, one of how many,
    /// then starting its session; and that it is over, once the session is
    /// there or it was refused.
    func testEveryDeviceIsToldWhatIsBeingDoneWhileAWorktreeIsMade() throws {
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let git = { (directory: URL, arguments: [String]) in
            let ran = Subprocess.run(
                "/usr/bin/git", ["-C", directory.path, "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always", "-c", "user.name=T", "-c", "user.email=t@example.com"] + arguments,
                timeout: 30, mergeErrors: true)
            XCTAssertEqual(ran?.status, 0, "git \(arguments.joined(separator: " ")): \(String(decoding: ran?.output ?? Data(), as: UTF8.self))")
        }
        git(library, ["init", "-q", "-b", "main"])
        git(library, ["commit", "-q", "--allow-empty", "-m", "library"])
        git(project, ["submodule", "add", "-q", library.path, "libs/library"])
        git(project, ["commit", "-q", "-m", "with its library"])
        let other = Client(port: port, token: token)
        waitUntil("the other device connected") { !other.messages.isEmpty }

        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path, title: "Claude Code"), branch: nil, from: nil))
        waitUntil("the session") { self.client.sessions.count == 1 }
        waitUntil("over") { self.client.inProgress.last == [] && other.inProgress.last == [] }
        for device in [client!, other] {
            let steps = device.inProgress.compactMap(\.first).map { "\($0.branch ?? "-") \($0.stepText)" }
            XCTAssertEqual(
                steps,
                [
                    "- Making the worktree…",
                    "agentterm/claude-1 Making the worktree…",
                    "agentterm/claude-1 Checking out submodule 1 of 1: libs/library…",
                    "agentterm/claude-1 Starting Claude Code…",
                ])
            XCTAssertEqual(Set(device.inProgress.compactMap(\.first).map(\.folder)), [project.path])
        }
        XCTAssertEqual(client.errors, [])

        // One refused is over at once too.
        client.connection.send(.createInWorktree(request: CreateRequest(command: nil, cwd: project.path), branch: "x", from: "no-such"))
        waitUntil("refused") { !self.client.errors.isEmpty }
        waitUntil("over") { self.client.inProgress.last == [] }
    }

    /// WT-25 (#244): a device that connects while a worktree is being made
    /// is told of it at once, not only of what comes after.
    func testADeviceThatComesWhileAWorktreeIsMadeIsToldOfIt() throws {
        // A checkout that takes a while: git runs the project's hook in the new worktree.
        let hook = project.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\nsleep 6\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        client.connection.send(.createInWorktree(request: CreateRequest(command: nil, cwd: project.path), branch: "feature/slow", from: nil))
        waitUntil("being made") { self.client.inProgress.last?.isEmpty == false }

        // Told on connecting, while git is still at it: not by what the
        // host sends once the worktree is made, seconds later.
        let late = Client(port: port, token: token)
        waitUntil("the late device told of it", timeout: 3) { late.inProgress.first?.first?.branch == "feature/slow" }
        XCTAssertEqual(late.inProgress.first?.first?.step, .making)
        waitUntil("over for it too", timeout: 20) { late.inProgress.last == [] }
    }

    /// WT-26 (#245): a session in a worktree says the branch checked out there, also
    /// after another is checked out in it: it was the one the worktree was
    /// made with, for as long as the session ran.
    func testASessionInAWorktreeSaysTheBranchCheckedOutThere() throws {
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path), branch: "feature/x", from: nil))
        waitUntil("the session") { self.client.sessions.first?.branch == "feature/x" }
        let cwd = try XCTUnwrap(client.sessions.first?.cwd)
        let switched = Subprocess.run("/usr/bin/git", ["-C", cwd, "checkout", "-q", "-b", "feature/y"], timeout: 30, mergeErrors: true)
        XCTAssertEqual(switched?.status, 0)
        // The folder's worktrees are asked for, as the apps do when it is shown.
        client.connection.send(.listWorktrees(folder: project.path))
        waitUntil("the worktrees") { self.client.worktrees.contains { $0.branch == "feature/y" } }
        waitUntil("the session's branch") { self.client.sessions.first?.branch == "feature/y" }
    }

    /// WT-5: a worktree a session runs in is not removed; one with unmerged
    /// work is removed only when asked to throw it away.
    func testAWorktreeInUseIsNotRemoved() throws {
        client.connection.send(.createInWorktree(request: CreateRequest(command: "claude", cwd: project.path), branch: "feature/x", from: nil))
        waitUntil("the session") { self.client.sessions.count == 1 }
        let path = try XCTUnwrap(client.sessions.first?.cwd)
        client.connection.send(.finishWorktree(folder: project.path, path: path, finish: .discard, deleteBranch: true))
        waitUntil("refused") { self.client.errors.contains { $0.contains("still runs") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        // Ended, then thrown away as asked.
        client.connection.send(.kill(session: try XCTUnwrap(client.sessions.first?.id)))
        waitUntil("ended") { self.client.sessions.isEmpty }
        client.connection.send(.finishWorktree(folder: project.path, path: path, finish: .discard, deleteBranch: true))
        waitUntil("removed") { !FileManager.default.fileExists(atPath: path) }
        waitUntil("told") { self.client.messages.contains { if case .worktreeFinished = $0 { return true } else { return false } } }
    }
}
