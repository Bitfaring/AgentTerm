import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// #260 (review of 2026-11-22): the changes of a folder are read whatever
/// the user's git writes before a path in a diff (`diff.mnemonicPrefix`,
/// `diff.noprefix`). The settings are the temporary repository's own.
final class ReviewSubGitPrefixTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-prefix-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.com")
        git("config", "commit.gpgsign", "false")
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "one\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git("add", ".")
        git("commit", "-q", "-m", "init")
        // One change staged, one not.
        try "one\ntwo\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "one\ntwo\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        git("add", "b.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: String...) -> String {
        let result = Subprocess.run("/usr/bin/git", ["-C", root.path] + arguments)
        return String(decoding: result?.output ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var changes: [String] {
        GitDiff.snapshot(directory: root.path).files.map { "\($0.isStaged ? "staged" : "unstaged") \($0.path)" }.sorted()
    }

    /// As git is set up by itself: the test's own ground.
    func testTheChangesAreNamedAsGitIsSetUpByItself() {
        XCTAssertEqual(changes, ["staged b.txt", "unstaged a.txt"])
    }

    /// #260: `diff.mnemonicPrefix` writes `i/` and `w/` (`c/` and `i/` for
    /// what is staged) where the parser expects `a/` and `b/`.
    func testTheChangesAreNamedWithMnemonicPrefix() {
        git("config", "--local", "diff.mnemonicPrefix", "true")
        XCTAssertEqual(changes, ["staged b.txt", "unstaged a.txt"])
    }

    /// #260: `diff.noprefix` writes no prefix at all.
    func testTheChangesAreNamedWithNoPrefix() {
        git("config", "--local", "diff.noprefix", "true")
        XCTAssertEqual(changes, ["staged b.txt", "unstaged a.txt"])
    }

    /// #260: a commit's files, and a stash's, are named the same way.
    func testACommitAndAStashAreNamedWithNoPrefix() {
        git("commit", "-q", "-m", "second")
        let hash = git("rev-parse", "HEAD")
        git("stash", "push", "-q")
        git("config", "--local", "diff.noprefix", "true")
        git("config", "--local", "diff.mnemonicPrefix", "true")
        XCTAssertEqual(GitActions.show(hash, in: root.path)?.files.map(\.path), ["b.txt"])
        guard let stash = GitActions.stashes(in: root.path).first else { return XCTFail("no stash") }
        XCTAssertEqual(GitActions.stashFiles(stash.hash, in: root.path)?.map(\.path), ["a.txt"])
    }
}
