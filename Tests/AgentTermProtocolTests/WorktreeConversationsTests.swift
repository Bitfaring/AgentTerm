import AgentTermProtocol
import XCTest

/// HAND-9 (#165): a new worktree carries on a conversation of the folder's
/// or of one of its worktrees', and of nothing else.
final class WorktreeConversationsTests: XCTestCase {
    private func conversation(_ id: String, in cwd: String, at seconds: TimeInterval) -> Conversation {
        Conversation(agent: "claude", sessionID: id, title: id, updatedAt: Date(timeIntervalSince1970: seconds), cwd: cwd)
    }

    func testTheFoldersAndItsWorktreesConversationsOnly() {
        let folder = "/Users/me/app"
        let own = [conversation("main", in: folder, at: 10)]
        let all = [
            conversation("main", in: folder, at: 10),
            conversation("in-worktree", in: folder + "/.agentterm/worktrees/agentterm-claude-1", at: 30),
            conversation("other-project", in: "/Users/me/site", at: 40),
            conversation("subfolder", in: folder + "/docs", at: 50),
        ]
        let offered = WorktreePath.conversations(of: folder, own: own, all: all)
        XCTAssertEqual(offered.map(\.sessionID), ["in-worktree", "main"], "newest first, the worktree's among them, each once, nothing else")
    }
}
