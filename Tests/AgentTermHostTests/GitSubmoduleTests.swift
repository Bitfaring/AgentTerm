import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// Submodules in the Git side panel (#44): what is changed inside one is
/// listed under it, its commit moved is a change of the folder, and a new
/// worktree has them checked out.
final class GitSubmoduleTests: XCTestCase {
    private var root: URL!
    private var project: URL { root.appendingPathComponent("project") }
    private var library: URL { root.appendingPathComponent("library") }
    private var inside: URL { project.appendingPathComponent("libs/library") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-sub-\(UUID().uuidString)").standardizedFileURL
        // The submodules here come from folders of this Mac, which git
        // fetches from only when told to: said to the gits these tests
        // start, and to the ones those start in turn, by the environment.
        setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "protocol.file.allow", 1)
        setenv("GIT_CONFIG_VALUE_0", "always", 1)
        for repository in [library, project] {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            git("init", "-q", "-b", "main", in: repository)
            configure(repository)
        }
        try write("l.txt", "one\n", in: library)
        git("add", ".", in: library)
        git("commit", "-q", "-m", "library: one", in: library)
        try write("a.txt", "the project's\n", in: project)
        git("submodule", "add", "-q", library.path, "libs/library", in: project)
        configure(inside)
        git("add", ".", in: project)
        git("commit", "-q", "-m", "project with its library", in: project)
    }

    override func tearDown() {
        for name in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] { unsetenv(name) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func configure(_ repository: URL) {
        git("config", "user.name", "Test", in: repository)
        git("config", "user.email", "test@example.com", in: repository)
        git("config", "commit.gpgsign", "false", in: repository)
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", directory.path] + arguments, timeout: 60, mergeErrors: true)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ text: String, in directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var snapshot: DiffSnapshot { GitDiff.snapshot(directory: project.path) }

    /// GIT-60: files changed inside a submodule are listed under it, each
    /// with its diff, and are not a change of the folder; they are staged,
    /// committed and discarded in the submodule; its commit, moved by
    /// that, is then a change of the folder, which is staged and
    /// committed there.
    func testChangesInsideASubmoduleAreItsOwnAndItsCommitIsTheFolders() throws {
        XCTAssertEqual(snapshot.files, [])
        XCTAssertEqual(snapshot.submodules, [])

        try write("l.txt", "one\ntwo\n", in: inside)
        try write("new.txt", "new\n", in: inside)
        var state = snapshot
        XCTAssertEqual(state.files, [], "nothing of the folder's own is changed")
        XCTAssertEqual(state.submodules.map(\.path), ["libs/library"])
        var changes = try XCTUnwrap(state.submodules.first).changes
        XCTAssertEqual(changes.branch, "main")
        XCTAssertEqual(changes.unstaged.map(\.path), ["l.txt", "new.txt"])
        XCTAssertTrue(changes.files[0].patch.contains("+two"), "each with its diff")
        XCTAssertEqual(state.withoutPatches.submodules.first?.changes.files.map(\.patch), ["", ""])
        let directory = try XCTUnwrap(state.submodules.first).directory(in: project.path)
        XCTAssertEqual(directory, inside.path)

        // Discarded and staged in the submodule.
        XCTAssertNil(GitActions.discard(["new.txt"], in: directory))
        XCTAssertNil(GitActions.stage(["l.txt"], in: directory))
        changes = try XCTUnwrap(snapshot.submodules.first).changes
        XCTAssertEqual(changes.staged.map(\.path), ["l.txt"])
        XCTAssertEqual(changes.unstaged, [])
        // Discarding everything in the folder leaves what is inside the submodule alone.
        XCTAssertEqual(GitActions.discard([], in: project.path), "There is no change to discard.")

        // Committed there: nothing is changed inside it any more, and its
        // commit is a change of the folder.
        XCTAssertNil(GitActions.commit(message: "library: two", in: directory))
        state = snapshot
        XCTAssertEqual(state.submodules, [])
        XCTAssertEqual(state.unstaged.map(\.path), ["libs/library"])
        let moved = try XCTUnwrap(state.unstaged.first)
        XCTAssertTrue(moved.isSubmodule)
        let old = git("rev-parse", "--short=7", "HEAD~1", in: inside)
        let new = git("rev-parse", "--short=7", "HEAD", in: inside)
        XCTAssertEqual(moved.submoduleWords, "submodule, \(old) → \(new)")

        // Staged and committed in the folder.
        XCTAssertNil(GitActions.stage(["libs/library"], in: project.path))
        XCTAssertEqual(snapshot.staged.map(\.path), ["libs/library"])
        XCTAssertTrue(snapshot.staged[0].isSubmodule)
        XCTAssertNil(GitActions.commit(message: "the library's new commit", in: project.path))
        XCTAssertEqual(snapshot.files, [])
        XCTAssertEqual(git("ls-tree", "HEAD", "libs/library", in: project).split(separator: "\t").first?.split(separator: " ").last.map(String.init), git("rev-parse", "HEAD", in: inside))
    }

    /// GIT-61: a submodule whose commit moved and that has changes inside
    /// is both: a change of the folder and a list of its own. Discarding
    /// the moved commit checks out the one the folder records.
    func testAMovedCommitIsDiscardedToTheOneTheFolderRecords() throws {
        let recorded = git("rev-parse", "HEAD", in: inside)
        try write("l.txt", "one\ntwo\n", in: inside)
        git("commit", "-q", "-am", "library: two", in: inside)
        try write("more.txt", "more\n", in: inside)
        try write("a.txt", "the project's, changed\n", in: project)

        let state = snapshot
        XCTAssertEqual(state.unstaged.map(\.path), ["a.txt", "libs/library"])
        XCTAssertEqual(state.unstaged.map(\.isSubmodule), [false, true])
        XCTAssertEqual(state.submodules.first?.changes.files.map(\.path), ["more.txt"])

        // Everything of the folder's: its file and the submodule's commit.
        // What is inside the submodule and not tracked there stays.
        XCTAssertNil(GitActions.discard([], in: project.path))
        XCTAssertEqual(git("rev-parse", "HEAD", in: inside), recorded)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8), "the project's\n")
        XCTAssertEqual(snapshot.files, [])
        XCTAssertEqual(snapshot.submodules.first?.changes.files.map(\.path), ["more.txt"])
        // A submodule left without a branch says so before a commit there.
        let detached = try XCTUnwrap(snapshot.submodules.first)
        XCTAssertNil(detached.changes.branch)
        XCTAssertEqual(detached.branchWords, "detached HEAD")
        XCTAssertNotNil(detached.detachedWarning)
    }

    /// GIT-62: seen from a folder inside the repository, a submodule is
    /// named from there; a submodule inside a submodule is listed under it.
    func testSubmodulesFromAFolderInsideAndInsideOneAnother() throws {
        // The library gets a submodule of its own.
        let deeper = root.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: deeper)
        configure(deeper)
        try write("d.txt", "deep\n", in: deeper)
        git("add", ".", in: deeper)
        git("commit", "-q", "-m", "deeper", in: deeper)
        git("submodule", "add", "-q", deeper.path, "deep", in: inside)
        git("commit", "-q", "-m", "library with deeper", in: inside)
        git("add", ".", in: project)
        git("commit", "-q", "-m", "the library moved", in: project)
        XCTAssertEqual(snapshot.files, [])

        try write("d.txt", "deep\nchanged\n", in: inside.appendingPathComponent("deep"))
        let outer = try XCTUnwrap(snapshot.submodules.first)
        XCTAssertEqual(outer.changes.files, [])
        XCTAssertEqual(outer.changes.submodules.map(\.path), ["deep"])
        XCTAssertEqual(outer.changes.submodules.first?.changes.files.map(\.path), ["d.txt"])

        let fromLibs = GitDiff.snapshot(directory: project.appendingPathComponent("libs").path)
        XCTAssertEqual(fromLibs.submodules.map(\.path), ["library"])
    }

    /// WT-20: a new worktree has its submodules checked out; where one
    /// cannot be fetched, the worktree is made all the same and says so.
    func testANewWorktreeHasItsSubmodulesCheckedOut() throws {
        let made = try GitWorktrees.create(in: project.path, agent: "claude", branch: "with-library")
        let checkedOut = URL(fileURLWithPath: made.directory).appendingPathComponent("libs/library/l.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkedOut.path), "git leaves it empty")
        XCTAssertNil(GitWorktrees.checkOutSubmodules(in: made.directory))
        XCTAssertEqual(try String(contentsOf: checkedOut, encoding: .utf8), "one\n")
        XCTAssertEqual(GitDiff.snapshot(directory: made.directory).files, [])

        // A repository without submodules has nothing to check out.
        XCTAssertNil(GitWorktrees.checkOutSubmodules(in: library.path))

        // Not checked out in the folder, and gone from where it came from:
        // there is nowhere to take it from (since #244 one checked out in
        // the folder is taken from there).
        git("submodule", "deinit", "-q", "-f", "libs/library", in: project)
        try FileManager.default.removeItem(at: library)
        let second = try GitWorktrees.create(in: project.path, agent: "claude", branch: "without-library")
        let problem = try XCTUnwrap(GitWorktrees.checkOutSubmodules(in: second.directory))
        XCTAssertTrue(problem.hasPrefix("The submodules of the new worktree could not be checked out"), problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory + "/a.txt"))
    }

    /// WT-24 (#244): a new worktree's submodules, and theirs, are cloned
    /// from the folder's own checkout of them, not fetched again from where
    /// they come from, and then push and fetch there; which one is being
    /// checked out, of how many, is told as it goes.
    func testANewWorktreeTakesItsSubmodulesFromTheFolder() throws {
        // The library gets a submodule of its own.
        let deeper = root.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: deeper)
        configure(deeper)
        try write("d.txt", "deep\n", in: deeper)
        git("add", ".", in: deeper)
        git("commit", "-q", "-m", "deeper", in: deeper)
        git("submodule", "add", "-q", deeper.path, "deep", in: inside)
        git("commit", "-q", "-m", "library with deeper", in: inside)
        git("add", ".", in: project)
        git("commit", "-q", "-m", "the library moved", in: project)

        // Neither can be fetched from where it comes from: only the
        // folder's own copies are left.
        let away = root.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library, to: away.appendingPathComponent("library"))
        try FileManager.default.moveItem(at: deeper, to: away.appendingPathComponent("deeper"))

        let made = try GitWorktrees.create(in: project.path, agent: "claude", branch: "from-the-folder")
        // As on the user's Mac: git allows a submodule the file transport
        // only when told, which the code does itself, not the environment
        // these tests give every git.
        for name in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] { unsetenv(name) }
        var told: [String] = []
        XCTAssertNil(GitWorktrees.checkOutSubmodules(in: made.directory) { done, count, name in told.append("\(done + 1)/\(count) \(name)") })
        XCTAssertEqual(told, ["1/1 libs/library"])
        let library = URL(fileURLWithPath: made.directory).appendingPathComponent("libs/library")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("l.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent("deep/d.txt"), encoding: .utf8), "deep\n")
        XCTAssertEqual(GitDiff.snapshot(directory: made.directory).files, [])
        XCTAssertEqual(GitDiff.snapshot(directory: made.directory).submodules, [])
        // Both are submodules there, not loose folders.
        let status = git("submodule", "status", "--recursive", in: URL(fileURLWithPath: made.directory))
        XCTAssertFalse(status.split(separator: "\n").contains { $0.hasPrefix("-") }, status)
        // Their remotes are where they come from, not the folder's copies.
        XCTAssertEqual(git("remote", "get-url", "origin", in: library), self.library.path)
        XCTAssertEqual(git("remote", "get-url", "origin", in: library.appendingPathComponent("deep")), deeper.path)
        // The folder's own are as they were.
        XCTAssertEqual(git("remote", "get-url", "origin", in: inside), self.library.path)
        XCTAssertEqual(git("status", "--porcelain", in: project), "")
    }
}
