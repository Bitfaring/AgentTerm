import AgentTermProtocol
import SQLite3
import XCTest

@testable import AgentTermHost

final class AgentHistoryTests: XCTestCase {
    private var home: URL!
    private let project = "/Users/me/Dev/my.app"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ path: String, _ lines: [String], modified: Date? = nil) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func history(_ directory: String? = nil, includeSubfolders: Bool = false) -> [Conversation] {
        AgentHistory.conversations(in: directory ?? project, includeSubfolders: includeSubfolders, home: home.path)
    }

    func testClaudeProjectFolderName() {
        XCTAssertEqual(AgentHistory.claudeProjectName(for: "/Users/manh/Project/apps"), "-Users-manh-Project-apps")
        XCTAssertEqual(AgentHistory.claudeProjectName(for: "/Users/me/Dev/my.app_v2"), "-Users-me-Dev-my-app-v2")
    }

    func testClaudeUsesTheNewestTitleAndFallsBackToTheFirstPrompt() throws {
        let folder = ".claude/projects/-Users-me-Dev-my-app"
        try write(
            "\(folder)/aaaa-1111.jsonl",
            [
                #"{"type":"user","message":{"role":"user","content":"sửa lỗi đăng nhập"},"sessionId":"aaaa-1111"}"#,
                #"{"type":"ai-title","aiTitle":"Old title","sessionId":"aaaa-1111"}"#,
                #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}"#,
                #"{"type":"ai-title","aiTitle":"Fix the login bug","sessionId":"aaaa-1111"}"#,
            ], modified: Date(timeIntervalSince1970: 2_000))
        try write(
            "\(folder)/bbbb-2222.jsonl",
            [
                #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: ignore"}}"#,
                #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
                #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"viết   test\ncho API"}]}}"#,
            ], modified: Date(timeIntervalSince1970: 3_000))
        try write("\(folder)/agent-cccc.jsonl", [#"{"type":"user","message":{"role":"user","content":"sub agent work"}}"#])
        try write("\(folder)/dddd-4444.jsonl", [#"{"type":"mode","mode":"default"}"#])

        let found = history()
        XCTAssertEqual(found.map(\.sessionID), ["bbbb-2222", "aaaa-1111"], "newest first, empty and sub-agent files left out")
        XCTAssertEqual(found[0].title, "viết test cho API")
        XCTAssertEqual(found[1].title, "Fix the login bug")
        XCTAssertEqual(found[1].resumeCommand, "claude --resume aaaa-1111")
        XCTAssertEqual(found[1].cwd, project)
    }

    func testClaudeIncludesSubfoldersButNotLookalikeSiblings() throws {
        // "/Users/me/Dev/my.app/web" and "/Users/me/Dev/my.app-web" share a project folder prefix.
        try write(
            ".claude/projects/-Users-me-Dev-my-app-web/sub-1.jsonl",
            [
                #"{"type":"user","cwd":"/Users/me/Dev/my.app/web","message":{"role":"user","content":"style the header"}}"#
            ])
        try write(
            ".claude/projects/-Users-me-Dev-my-app-tools/sib-1.jsonl",
            [
                #"{"type":"user","cwd":"/Users/me/Dev/my.app-tools","message":{"role":"user","content":"unrelated project"}}"#
            ])
        XCTAssertTrue(history().isEmpty, "a folder lists only its own conversations")
        let found = history(includeSubfolders: true)
        XCTAssertEqual(found.map(\.sessionID), ["sub-1"])
        XCTAssertEqual(found[0].cwd, "/Users/me/Dev/my.app/web")
    }

    func testCodexMatchesByDirectoryAndTakesThePromptFromHistory() throws {
        let meta = { (id: String, cwd: String) in #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","base_instructions":"…"}}"# }
        try write(".codex/sessions/2026/11/10/rollout-2026-11-10T01-00-00-id-one.jsonl", [meta("id-one", project)])
        try write(
            ".codex/sessions/2026/11/11/rollout-2026-11-11T01-00-00-id-two.jsonl",
            [
                meta("id-two", project + "/packages/web"),
                #"{"type":"event_msg","payload":{"type":"user_message","message":"add dark mode"}}"#,
            ])
        try write(".codex/sessions/2026/11/11/rollout-2026-11-11T02-00-00-id-three.jsonl", [meta("id-three", "/Users/me/Dev/other")])
        try write(
            ".codex/history.jsonl",
            [
                #"{"session_id":"id-one","ts":1,"text":"refactor the parser"}"#,
                #"{"session_id":"id-one","ts":2,"text":"a later prompt"}"#,
                #"{"session_id":"id-three","ts":3,"text":"not this project"}"#,
            ])
        XCTAssertEqual(history().map(\.sessionID), ["id-one"], "the subfolder's conversation is not the project's")
        XCTAssertEqual(history(project + "/packages/web").map(\.sessionID), ["id-two"])
        let found = history(includeSubfolders: true).filter { $0.agent == "codex" }
        XCTAssertEqual(Set(found.map(\.sessionID)), ["id-one", "id-two"])
        XCTAssertEqual(found.first { $0.sessionID == "id-one" }?.title, "refactor the parser")
        let nested = try XCTUnwrap(found.first { $0.sessionID == "id-two" })
        XCTAssertEqual(nested.title, "add dark mode")
        XCTAssertEqual(nested.cwd, project + "/packages/web")
        XCTAssertEqual(nested.resumeCommand, "codex resume id-two")
    }

    func testAntigravityReadsTheMetadataCache() throws {
        try write(
            ".gemini/antigravity-cli/cache/conversation_metadata.json",
            [
                """
                {"conversations":{
                  "conv-1":{"is_internal":false,"last_modified_time":"2026-11-10T17:00:22.474318735+07:00",
                    "summary":{"Title":"Plan the release","Preview":"p","UpdatedAt":"2026-11-10T17:00:22.474318735+07:00","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
                  "conv-2":{"is_internal":true,"summary":{"Title":"internal","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
                  "conv-3":{"is_internal":false,"summary":{"Title":"elsewhere","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/other"]}}
                }}
                """
            ])
        let found = history()
        XCTAssertEqual(found.map(\.id), ["agy:conv-1"])
        XCTAssertEqual(found[0].title, "Plan the release")
        XCTAssertEqual(found[0].resumeCommand, "agy --conversation conv-1")
        XCTAssertEqual(found[0].updatedAt.timeIntervalSince1970, 1_794_304_822.474, accuracy: 0.01)
        XCTAssertNil(found[0].source, "no transcript file was written for it")

        try write(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs/transcript.jsonl", ["{}"])
        XCTAssertTrue(history()[0].source?.hasSuffix("/brain/conv-1/.system_generated/logs/transcript.jsonl") == true)
        try write(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs/transcript_full.jsonl", ["{}"])
        XCTAssertTrue(history()[0].source?.hasSuffix("/transcript_full.jsonl") == true, "the untruncated file is preferred")
    }

    func testCopilotReadsWorkspaceFiles() throws {
        try write(
            ".copilot/session-state/sess-1/workspace.yaml",
            [
                "id: sess-1", "cwd: /Users/me/Dev/my.app", "name: Hello Session", "user_named: false", "updated_at: 2026-11-11T04:32:36.549Z",
            ])
        try write(".copilot/session-state/sess-2/workspace.yaml", ["id: sess-2", "cwd: /Users/me/Dev/my.app", "updated_at: 2026-11-11T05:00:00.000Z"])
        try write(
            ".copilot/session-state/sess-2/events.jsonl",
            [
                #"{"type":"session.start","data":{}}"#,
                #"{"type":"user.message","data":{"content":"explain this repo"}}"#,
            ])
        try write(".copilot/session-state/sess-3/workspace.yaml", ["id: sess-3", "cwd: /tmp", "name: Other"])
        let found = history()
        XCTAssertEqual(found.map(\.sessionID), ["sess-2", "sess-1"])
        XCTAssertEqual(found[0].title, "explain this repo")
        XCTAssertEqual(found[1].title, "Hello Session")
        XCTAssertEqual(found[1].resumeCommand, "copilot --resume=sess-1")
    }

    func testIdentifiersThatCouldBreakOutOfTheCommandAreDropped() throws {
        XCTAssertTrue(AgentHistory.isSafeIdentifier("01a1c6c2-d410-7bf3-bd53-0710a01e7ab0"))
        for bad in ["", "a b", "x;rm -rf ~", "$(id)", "a`b`", "-rf", "a/b", "é"] {
            XCTAssertFalse(AgentHistory.isSafeIdentifier(bad), bad)
        }
        try write(".copilot/session-state/evil/workspace.yaml", ["id: x; touch /tmp/pwned", "cwd: /Users/me/Dev/my.app", "name: Evil"])
        XCTAssertTrue(history().isEmpty)
    }

    func testEveryAgentIsScopedToTheExactFolder() throws {
        let sub = project + "/packages/web"
        try write(
            ".gemini/antigravity-cli/cache/conversation_metadata.json",
            [
                """
                {"conversations":{
                  "here":{"summary":{"Title":"here","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
                  "below":{"summary":{"Title":"below","UpdatedAt":"2026-11-10T17:00:23Z","WorkspaceURIs":["file:///Users/me/Dev/my.app/packages/web"]}}
                }}
                """
            ])
        try write(".copilot/session-state/c-here/workspace.yaml", ["id: c-here", "cwd: \(project)", "name: here", "updated_at: 2026-11-11T04:00:00.000Z"])
        try write(".copilot/session-state/c-below/workspace.yaml", ["id: c-below", "cwd: \(sub)", "name: below", "updated_at: 2026-11-11T05:00:00.000Z"])
        XCTAssertEqual(Set(history().map(\.sessionID)), ["here", "c-here"])
        XCTAssertEqual(Set(history(sub).map(\.sessionID)), ["below", "c-below"])
        XCTAssertEqual(history(includeSubfolders: true).count, 4)
    }

    func testAllConversationsCoversEveryFolder() throws {
        try write(
            ".claude/projects/-Users-me-Dev-my-app/c-1.jsonl",
            [
                #"{"type":"user","cwd":"/Users/me/Dev/my.app","message":{"role":"user","content":"in the project"}}"#
            ], modified: Date(timeIntervalSince1970: 5_000))
        try write(
            ".claude/projects/-Users-me-other/c-2.jsonl",
            [
                #"{"type":"user","cwd":"/Users/me/other","message":{"role":"user","content":"somewhere else"}}"#
            ], modified: Date(timeIntervalSince1970: 6_000))
        try write(
            ".claude/projects/-Users-me-nocwd/c-3.jsonl",
            [
                #"{"type":"user","message":{"role":"user","content":"folder unknown"}}"#
            ])
        try write(
            ".codex/sessions/2026/11/11/rollout-2026-11-11T01-00-00-x-1.jsonl",
            [
                #"{"type":"session_meta","payload":{"id":"x-1","cwd":"/tmp/scratch"}}"#
            ], modified: Date(timeIntervalSince1970: 7_000))
        try write(".codex/history.jsonl", [#"{"session_id":"x-1","ts":1,"text":"quick experiment"}"#])
        try write(".copilot/session-state/p-1/workspace.yaml", ["id: p-1", "cwd: /Users/me/third", "name: third", "updated_at: 1970-01-01T00:16:40.000Z"])

        let all = AgentHistory.allConversations(home: home.path)
        XCTAssertEqual(all.map(\.sessionID), ["x-1", "c-2", "c-1", "p-1"], "newest first; a session with no recorded folder is left out")
        XCTAssertEqual(all.map(\.cwd), ["/tmp/scratch", "/Users/me/other", "/Users/me/Dev/my.app", "/Users/me/third"])
        XCTAssertEqual(AgentHistory.allConversations(home: home.path, limit: 2).count, 2)
        XCTAssertEqual(history().map(\.sessionID), ["c-1"], "the folder view is unaffected")
    }

    func testNothingInstalledMeansNoHistory() {
        XCTAssertTrue(AgentHistory.allConversations(home: home.path).isEmpty)
        XCTAssertTrue(history().isEmpty)
        XCTAssertTrue(history("/nonexistent/place").isEmpty)
    }

    private let antigravity = ".gemini/antigravity-cli"
    private var antigravityListFile: URL { home.appendingPathComponent("\(antigravity)/cache/conversation_metadata.json") }

    /// Every file under the test's home, with what it holds.
    private func everything() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let root = home.resolvingSymlinksInPath()
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])! {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                files[String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func listed(_ id: String) throws -> Conversation {
        try XCTUnwrap(history().first { $0.agent == "agy" && $0.sessionID == id })
    }

    // MARK: Antigravity's store of its conversations (#224)

    private let storeRows = [
        AntigravityStoreFixture.Row(id: "5d0c1a52-0d0e-4b7c-9a43-1f2e3d4c5b6a", title: "Plan the release", modified: "2026-11-20 01:02:03.123456+07:00", workspaces: ["file:///Users/me/Dev/my.app"]),
        AntigravityStoreFixture.Row(
            id: "6e1d2b63-1e1f-4c8d-8b54-2a3f4e5d6c7b", title: "", preview: "tidy the README", modified: "2026-11-21 09:00:00.5+07:00", workspaces: ["file:///Users/me/Dev/my.app"]),
        AntigravityStoreFixture.Row(id: "7f2e3c74-2f2a-4d9e-9c65-3b4a5f6e7d8c", title: "Elsewhere", modified: "2026-11-21 10:00:00.000001+07:00", workspaces: ["file:///Users/me/Dev/other"]),
        // Nothing was said in it: Antigravity's own list leaves it out too.
        AntigravityStoreFixture.Row(id: "8a3f4d85-3a3b-4eaf-8d76-4c5b6a7f8e9d", title: "", modified: "2026-11-21 11:00:00.000001+07:00", workspaces: ["file:///Users/me/Dev/my.app"]),
    ]

    /// HIST-27 (#224): Antigravity 1.5.12 keeps its list in a SQLite store
    /// and writes no `conversation_metadata.json`: its conversations are
    /// listed from the store.
    func testAntigravityListsTheConversationsOfItsStore() throws {
        try AntigravityStoreFixture.make(in: home, rows: storeRows)
        XCTAssertFalse(FileManager.default.fileExists(atPath: antigravityListFile.path))

        let found = history()
        XCTAssertEqual(found.map(\.id), ["agy:6e1d2b63-1e1f-4c8d-8b54-2a3f4e5d6c7b", "agy:5d0c1a52-0d0e-4b7c-9a43-1f2e3d4c5b6a"], "newest first; another folder's and an empty one left out")
        XCTAssertEqual(found.map(\.title), ["tidy the README", "Plan the release"], "its title, else what was first said")
        XCTAssertEqual(found[1].cwd, project)
        XCTAssertEqual(found[1].resumeCommand, "agy --conversation 5d0c1a52-0d0e-4b7c-9a43-1f2e3d4c5b6a")
        XCTAssertEqual(found[1].updatedAt.timeIntervalSince1970, 1_795_111_323.123, accuracy: 0.01)
        XCTAssertNil(found[1].source, "no transcript file was written for it")
        XCTAssertEqual(AgentHistory.allConversations(home: home.path).count, 3)

        try write("\(antigravity)/brain/\(storeRows[0].id)/.system_generated/logs/transcript.jsonl", ["{}"])
        try write("\(antigravity)/brain/\(storeRows[0].id)/.system_generated/logs/transcript_full.jsonl", ["{}"])
        XCTAssertTrue(history()[1].source?.hasSuffix("/brain/\(storeRows[0].id)/.system_generated/logs/transcript_full.jsonl") == true, "the untruncated file is preferred")
    }

    /// HIST-27 (#224): a folder that has the earlier list beside the store
    /// lists a conversation once, as the store says; one only the earlier
    /// list has is still listed.
    func testAntigravityListsAConversationOnceWhenItsStoreAndItsEarlierListHaveIt() throws {
        try AntigravityStoreFixture.make(in: home, rows: storeRows)
        let both = storeRows[0].id, moved = storeRows[2].id
        try write(
            "\(antigravity)/cache/conversation_metadata.json",
            [
                """
                {"conversations":{
                  "\(both)":{"summary":{"Title":"Its earlier title","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
                  "\(moved)":{"summary":{"Title":"Was here","UpdatedAt":"2026-11-10T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}},
                  "conv-1":{"summary":{"Title":"Only in the list","UpdatedAt":"2026-11-09T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}}
                }}
                """
            ])
        let found = history()
        XCTAssertEqual(found.map(\.sessionID), [storeRows[1].id, both, "conv-1"], "once each; the one the store has in another folder is not this folder's")
        XCTAssertEqual(found[1].title, "Plan the release", "the store's, which the Antigravity in use writes")
        XCTAssertEqual(found[1].updatedAt.timeIntervalSince1970, 1_795_111_323.123, accuracy: 0.01)
        XCTAssertEqual(AgentHistory.allConversations(home: home.path).filter { $0.sessionID == moved }.map(\.cwd), ["/Users/me/Dev/other"])
        XCTAssertNil(AgentHistory.antigravityProblem(home: home.path))
    }

    /// HIST-27 (#224): a store that cannot be read, or whose table is not
    /// the one known, is said to be so with the reason. Nothing is
    /// guessed from it, nothing is written, and what the earlier list
    /// holds is still listed.
    func testAntigravitysStoreThatCannotBeReadIsSaid() throws {
        XCTAssertNil(AgentHistory.antigravityProblem(home: home.path), "no store is no problem")
        try write(
            "\(antigravity)/cache/conversation_metadata.json",
            [#"{"conversations":{"conv-1":{"summary":{"Title":"Only in the list","UpdatedAt":"2026-11-09T17:00:22Z","WorkspaceURIs":["file:///Users/me/Dev/my.app"]}}}}"#])
        let store = AntigravityStoreFixture.file(in: home)
        let said = "Antigravity's conversations are not listed: its database of them could not be read. "

        // Not a database at all.
        try Data("these bytes are not what SQLite writes, however long they go on".utf8).write(to: store)
        var before = try everything()
        XCTAssertEqual(history().map(\.sessionID), ["conv-1"])
        var problem = try XCTUnwrap(AgentHistory.antigravityProblem(home: home.path))
        XCTAssertTrue(problem.hasPrefix(said + "It is not a database that can be read"), problem)
        XCTAssertEqual(try everything(), before)

        // A database of a later version: the table under another name.
        try FileManager.default.removeItem(at: store)
        try AntigravityStoreFixture.make(in: home, rows: [], schema: ["CREATE TABLE summaries (conversation_id TEXT PRIMARY KEY, title TEXT)", "INSERT INTO summaries VALUES ('a-1', 'Renamed')"])
        before = try everything()
        XCTAssertEqual(history().map(\.sessionID), ["conv-1"])
        XCTAssertEqual(AgentHistory.antigravityProblem(home: home.path), said + "It has no table “conversation_summaries”, so it is not of a version of Antigravity that AgentTerm knows.")
        XCTAssertEqual(try everything(), before)

        // The table, without the columns the folder and the time are in.
        try FileManager.default.removeItem(at: store)
        try AntigravityStoreFixture.make(
            in: home, rows: [],
            schema: [
                "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT, workspaces BLOB)",
                "INSERT INTO conversation_summaries VALUES ('a-1', 'Reshaped', '', x'00')",
            ])
        before = try everything()
        XCTAssertEqual(history().map(\.sessionID), ["conv-1"], "guessed at")
        problem = try XCTUnwrap(AgentHistory.antigravityProblem(home: home.path))
        XCTAssertEqual(problem, said + "Its table “conversation_summaries” has no “last_modified_time”, “workspace_uris”, so it is not of a version of Antigravity that AgentTerm knows.")
        XCTAssertEqual(try everything(), before)
    }

    /// HIST-27 (#224): the store is read while an Antigravity has it open
    /// and writes to it, without a file made beside it and without a lock
    /// in its way. What is still only in its write-ahead log is not seen
    /// until Antigravity brings it into the store.
    func testAntigravitysStoreIsReadWhileItIsWrittenAndNothingIsMadeBesideIt() throws {
        let writer = try XCTUnwrap(try AntigravityStoreFixture.make(in: home, rows: [storeRows[0]], open: true))
        var closed = false
        defer { if !closed { sqlite3_close(writer) } }
        // As it is between two of Antigravity's checkpoints.
        try AntigravityStoreFixture.run("PRAGMA wal_autocheckpoint=0", in: writer)
        try AntigravityStoreFixture.run("PRAGMA wal_checkpoint(TRUNCATE)", in: writer)
        try AntigravityStoreFixture.insert(storeRows[1], in: writer)
        let folder = home.appendingPathComponent(antigravity)
        let names = { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
        XCTAssertEqual(try names(), ["conversation_summaries.db", "conversation_summaries.db-shm", "conversation_summaries.db-wal"])

        // In the middle of a change of Antigravity's too.
        try AntigravityStoreFixture.run("BEGIN IMMEDIATE", in: writer)
        try AntigravityStoreFixture.insert(storeRows[3], in: writer)
        XCTAssertEqual(history().map(\.sessionID), [storeRows[0].id], "what the store holds; the one in the write-ahead log is not seen yet")
        XCTAssertNil(AgentHistory.antigravityProblem(home: home.path))
        try AntigravityStoreFixture.run("COMMIT", in: writer)
        // Nothing of the reader's holds the checkpoint back.
        try AntigravityStoreFixture.run("PRAGMA wal_checkpoint(TRUNCATE)", in: writer)
        XCTAssertEqual(history().map(\.sessionID), [storeRows[1].id, storeRows[0].id])

        // With no Antigravity running there is the one file, and a reader
        // that opened it the ordinary way would make two beside it.
        closed = true
        try AntigravityStoreFixture.close(writer, in: home)
        XCTAssertEqual(try names(), ["conversation_summaries.db"])
        let before = try everything()
        XCTAssertEqual(history().count, 2)
        XCTAssertEqual(try names(), ["conversation_summaries.db"])
        XCTAssertEqual(try everything(), before)
    }

    /// HIST-26 (#224): a conversation of Antigravity is not deleted,
    /// whether it is listed from its store, from the list of an earlier
    /// version or from both: refused with where to delete it, and nothing
    /// under the home is rewritten, moved or made.
    func testAConversationOfAntigravityIsNotDeleted() throws {
        let trash = home.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        setenv(FileBrowser.trashVariable, trash.path, 1)
        addTeardownBlock { unsetenv(FileBrowser.trashVariable) }
        try AntigravityStoreFixture.make(in: home, rows: storeRows)
        let id = storeRows[0].id
        let entry = { (title: String) in #"{"summary": {"Title": "\#(title)", "UpdatedAt": "2026-11-09T17:00:22Z", "WorkspaceURIs": ["file:///Users/me/Dev/my.app"]}}"# }
        try write("\(antigravity)/cache/conversation_metadata.json", [#"{"conversations": {"\#(id)": \#(entry("Its earlier title")), "conv-1": \#(entry("Only in the list"))}}"#])
        for kept in [id, storeRows[1].id, "conv-1"] {
            try write("\(antigravity)/brain/\(kept)/.system_generated/logs/transcript_full.jsonl", [#"{"type":"USER_INPUT","source":"USER_EXPLICIT","content":"said"}"#])
            try write("\(antigravity)/conversations/\(kept).db", ["steps"])
            try write("\(antigravity)/annotations/\(kept).pbtxt", ["title:\"t\""])
        }
        let before = try everything()
        XCTAssertEqual(
            AgentHistory.antigravityNotDeleted, "Antigravity keeps its conversations in a store of its own, which AgentTerm does not write to: this one is deleted in Antigravity.")
        for kept in [id, storeRows[1].id, "conv-1"] {
            XCTAssertEqual(AgentHistory.delete(try listed(kept), home: home.path), AgentHistory.antigravityNotDeleted, kept)
        }
        XCTAssertEqual(try everything(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
        XCTAssertEqual(history().count, 3, "no longer listed")
    }

    func testDatesWithAnyFractionParse() {
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36.5Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-10T17:00:22.474318735+07:00"))
        XCTAssertNil(AgentHistory.parseDate("yesterday"))
    }
}

/// Antigravity's store of its conversations, `conversation_summaries.db`,
/// made here with the schema Antigravity 1.5.12 gave it (read on
/// 2026-11-21 from a copy of the real one) and rows made up (#224).
enum AntigravityStoreFixture {
    struct Row {
        var id: String
        var title: String
        var preview = ""
        /// As Antigravity writes it: "2026-11-20 01:02:03.123456+07:00".
        var modified: String
        var workspaces: [String]
    }

    static let schema = [
        """
        CREATE TABLE `conversation_summaries` (`conversation_id` text,`title` text NOT NULL DEFAULT "",`preview` text NOT NULL DEFAULT "",\
        `step_count` integer NOT NULL DEFAULT 0,`last_modified_time` datetime NOT NULL,`workspace_uris` text NOT NULL,`status` text NOT NULL DEFAULT "",\
        `source` text NOT NULL DEFAULT "",`project_id` text NOT NULL DEFAULT "",`agent_name` text NOT NULL DEFAULT "",\
        `parent_conversation_id` text NOT NULL DEFAULT "",`nesting_depth` integer NOT NULL DEFAULT 0,`battle_id` text NOT NULL DEFAULT "",\
        `winning_conversation_id` text NOT NULL DEFAULT "",`not_fully_idle` numeric NOT NULL DEFAULT false,`killed` numeric NOT NULL DEFAULT false,\
        `last_user_input_time` datetime NOT NULL,`last_user_input_step_index` integer NOT NULL DEFAULT -1,`app_data_dir` text NOT NULL DEFAULT "",\
        `raw_summary` blob,`group_id` text NOT NULL DEFAULT "",PRIMARY KEY (`conversation_id`))
        """,
        "CREATE INDEX `idx_conversation_summaries_last_user_input_time` ON `conversation_summaries`(`last_user_input_time`)",
        "CREATE INDEX `idx_conversation_summaries_last_modified_time` ON `conversation_summaries`(`last_modified_time`)",
        "CREATE TABLE search_schema_version (version INTEGER PRIMARY KEY)",
        "INSERT INTO search_schema_version VALUES (3)",
        """
        CREATE VIRTUAL TABLE conversations_fts USING fts5(conversation_id UNINDEXED, chunk_index UNINDEXED, chunk_first_step UNINDEXED, \
        chunk_last_step UNINDEXED, last_modified_time UNINDEXED, step_count UNINDEXED, last_step_created_at UNINDEXED, archived UNINDEXED, \
        user_step_byte_offsets UNINDEXED, agent_step_byte_offsets UNINDEXED, title, workspace, project, user_body, agent_body, \
        tokenize = 'unicode61 remove_diacritics 2', prefix = '1 2 3')
        """,
        "CREATE TABLE conversation_parents (conversation_id TEXT PRIMARY KEY, parent_id TEXT NOT NULL) WITHOUT ROWID",
    ]

    static func file(in home: URL) -> URL { home.appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db") }

    /// Writes the store, in the write-ahead mode Antigravity's is in. It
    /// is closed again, which leaves the one file, unless `open`: then
    /// the connection is given, as a running Antigravity holds one.
    @discardableResult
    static func make(in home: URL, rows: [Row], schema: [String] = schema, open: Bool = false) throws -> OpaquePointer? {
        let file = file(in: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
        try run("PRAGMA journal_mode=WAL", in: database)
        for statement in schema { try run(statement, in: database) }
        for row in rows { try insert(row, in: database) }
        if open { return database }
        try close(database, in: home)
        return nil
    }

    /// Closes it as Antigravity does on its way out: everything brought
    /// into the store, and the one file left. The system's SQLite leaves
    /// the two others, emptied, where Antigravity's own removes them.
    static func close(_ database: OpaquePointer, in home: URL) throws {
        try run("PRAGMA wal_checkpoint(TRUNCATE)", in: database)
        guard sqlite3_close(database) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file(in: home).path + suffix) }
    }

    static func insert(_ row: Row, in database: OpaquePointer) throws {
        let workspaces = String(decoding: try JSONSerialization.data(withJSONObject: row.workspaces, options: .withoutEscapingSlashes), as: UTF8.self)
        let values = [row.id, row.title, row.preview, row.modified, workspaces, row.modified].map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        try run(
            "INSERT INTO conversation_summaries (conversation_id, title, preview, last_modified_time, workspace_uris, last_user_input_time, step_count, status, app_data_dir, raw_summary) "
                + "VALUES (\(values.joined(separator: ", ")), 4, 'CASCADE_RUN_STATUS_IDLE', 'antigravity-cli', x'0A00')", in: database)
    }

    static func run(_ statement: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
}
