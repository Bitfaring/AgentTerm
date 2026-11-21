import AgentTermProtocol
import XCTest

/// WT-23 (#217): the worktrees are picked from a list with a search, the
/// same on both apps: what the search finds, and what the button that
/// opens the list says of the worktree on show.
final class WorktreeSearchTests: XCTestCase {
    private let own = WorktreeInfo(path: "/code/project", branch: "main", isMain: true, changed: 1)
    private let made = WorktreeInfo(
        path: "/code/project/.agentterm/worktrees/agentterm/claude-1", branch: "agentterm/claude-1", isMain: false, ahead: 2, changed: 3, inUse: true,
        isAgentTerm: true)
    private let elsewhere = WorktreeInfo(path: "/code/Review-Copy", branch: "feature/Parser", isMain: false)
    private let detached = WorktreeInfo(path: "/code/bisecting", branch: nil, isMain: false)
    private let gone = WorktreeInfo(path: "/code/gone", branch: "old", isMain: false, ahead: 4, missing: true)
    private var all: [WorktreeInfo] { [own, made, elsewhere, detached] }

    func testAnEmptySearchListsEveryWorktreeInItsOrder() {
        XCTAssertEqual(all.matching(search: ""), all)
        XCTAssertEqual(all.matching(search: "   "), all, "spaces alone are no search")
    }

    func testTheSearchFindsABranchWhateverTheCase() {
        XCTAssertEqual(all.matching(search: "MAIN"), [own])
        XCTAssertEqual(all.matching(search: "parser"), [elsewhere])
        XCTAssertEqual(all.matching(search: "agentterm/"), [made], "a part of the branch, its slash included")
        XCTAssertEqual(all.matching(search: " claude "), [made], "the spaces around what was typed are not searched for")
    }

    func testTheSearchFindsTheNameOfTheFolder() {
        XCTAssertEqual(all.matching(search: "review"), [elsewhere], "its folder, which its branch does not name")
        XCTAssertEqual(all.matching(search: "BISECT"), [detached], "a detached HEAD is found by its folder")
        XCTAssertEqual(all.matching(search: "project"), [own], "the last part of the path only, not the folders above it")
        XCTAssertEqual(all.matching(search: "worktrees"), [])
    }

    func testWhatMatchesNothingListsNothing() {
        XCTAssertEqual(all.matching(search: "nothing-like-it"), [])
        XCTAssertEqual(WorktreeWords.noMatch(" nothing "), "No worktree matches “nothing”.")
    }

    /// The button outside the list: the worktree on show and its changed
    /// files only; all of it in a sentence for assistive tools.
    func testWhatTheButtonSaysOfTheWorktreeOnShow() {
        XCTAssertEqual(own.pickerCounts, "1 changed")
        XCTAssertEqual(made.pickerCounts, "3 changed", "what it is ahead by is said in the list")
        XCTAssertEqual(elsewhere.pickerCounts, "")
        XCTAssertEqual(WorktreeInfo(path: "/gone", branch: "old", isMain: false, changed: 4, missing: true).pickerCounts, "missing")
        XCTAssertEqual(own.pickerLabel, "Worktree main, The folder itself, 1 file changed")
        XCTAssertEqual(made.pickerLabel, "Worktree agentterm/claude-1, A worktree, 3 files changed, 2 commits ahead, a session runs in it")
        XCTAssertEqual(detached.pickerLabel, "Worktree bisecting, A worktree")
    }

    func testTheWordsOfTheList() {
        XCTAssertEqual(WorktreeWords.listTitle, "Worktrees")
        XCTAssertEqual(WorktreeWords.searchPrompt, "Find a worktree")
        XCTAssertEqual(WorktreeWords.newTitle, "New Worktree")
        XCTAssertEqual(WorktreeWords.throwAway, "Throw Away…")
        XCTAssertEqual(WorktreeWords.actionsHelp(made), "Merge agentterm/claude-1, open a pull request for it, or throw it away")
        XCTAssertEqual(WorktreeWords.actionsHelp(gone), "Throw away old, whose folder is gone")
    }

    /// WT-19 (#217): what "⋯" on a row holds, the same on both apps: none
    /// for the folder's own, Throw Away… alone for one whose folder is
    /// missing, all three for any other.
    func testWhatARowsMenuHolds() {
        XCTAssertEqual(own.rowActions, [], "the folder's own has no menu")
        XCTAssertEqual(made.rowActions, [.merge, .pullRequest, .throwAway])
        XCTAssertEqual(elsewhere.rowActions, [.merge, .pullRequest, .throwAway])
        XCTAssertEqual(detached.rowActions, [.merge, .pullRequest, .throwAway])
        XCTAssertEqual(gone.rowActions, [.throwAway], "nothing to merge from or push where the folder is missing")
    }

    /// WT-19 (#217): a pull request is opened for the worktree on show
    /// only, and only when its branch has somewhere to be pushed to.
    func testAPullRequestIsForTheWorktreeOnShowOnly() {
        XCTAssertTrue(made.canOpenPullRequest(onShow: true, hasRemote: true))
        XCTAssertFalse(made.canOpenPullRequest(onShow: false, hasRemote: true), "another row's, though its changes were read")
        XCTAssertFalse(made.canOpenPullRequest(onShow: true, hasRemote: false), "nowhere to push to")
        XCTAssertFalse(made.canOpenPullRequest(onShow: false, hasRemote: false))
        XCTAssertFalse(own.canOpenPullRequest(onShow: true, hasRemote: true), "the folder's own has no menu")
        XCTAssertFalse(gone.canOpenPullRequest(onShow: true, hasRemote: true), "a missing one is only thrown away")
    }

    /// Merge is on for commits the folder's branch has not, all committed.
    func testWhenAWorktreeCanBeMerged() {
        XCTAssertFalse(made.canMerge, "it has changes that are not committed")
        XCTAssertTrue(WorktreeInfo(path: "/code/done", branch: "done", isMain: false, ahead: 2).canMerge)
        XCTAssertFalse(elsewhere.canMerge, "nothing ahead")
        XCTAssertFalse(gone.canMerge)
        XCTAssertFalse(own.canMerge)
    }
}
