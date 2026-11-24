import AgentTermProtocol
import XCTest

/// GIT-83 (#300): a page of commits that repeats one already listed, because
/// commits were made since the first page, is never added: the list is read
/// again. Before the fix both apps added it, and the same commit was two rows
/// of one id.
final class CommitPagesTests: XCTestCase {
    private func commits(_ range: ClosedRange<Int>) -> [CommitInfo] { range.map { CommitInfo(hash: "h\($0)", subject: "commit \($0)") } }

    func testThePageAfterWhatIsListedIsAdded() {
        XCTAssertEqual(CommitPages.add(commits(51...60), skip: 50, to: commits(1...50)), .listed(commits(1...60)))
    }

    func testAPageThatRepeatsACommitIsStale() {
        // Three commits made at the top since the first page: `--skip=50`
        // gives the last three of it again.
        let after = commits(48...57)
        XCTAssertEqual(CommitPages.add(after, skip: 50, to: commits(1...50)), .stale)
    }

    func testAPageOfAnotherListIsLeft() {
        XCTAssertEqual(CommitPages.add(commits(51...60), skip: 40, to: commits(1...50)), .other)
    }
}
