import AgentTermProtocol
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

    // MARK: Deleting a conversation of Antigravity (#222)

    private let antigravity = ".gemini/antigravity-cli"

    /// Antigravity's list as it is written here: three conversations, and
    /// keys AgentTerm does not know, at the top and inside an entry, with
    /// numbers and spacing a JSON library would write another way.
    private let antigravityList = """
        {
          "format_version": 3,
          "conversations": {
            "conv-1": {"is_internal": false, "summary": {"Title": "Plan the release", "UpdatedAt": "2026-11-10T17:00:22Z", "WorkspaceURIs": ["file:///Users/me/Dev/my.app"]}},
            "conv-2": {"is_internal": false, "summary": {"Title": "Write the parser", "UpdatedAt": "2026-11-11T17:00:22Z", "WorkspaceURIs": ["file:///Users/me/Dev/my.app"]}, "x_unknown": {"ratio": 1.50, "big": 12345678901234567890}},
            "conv-3": {"is_internal": false, "x_kept": [1,  2, {"a": null}], "summary": {"Title": "Tidy \\"the\\" README", "UpdatedAt": "2026-11-12T17:00:22Z", "WorkspaceURIs": ["file:///Users/me/Dev/my.app"]}}
          },
          "x_future": {"conversations": {"conv-2": "not the list"}, "order": ["conv-2", "conv-1"]}
        }

        """

    private var antigravityListFile: URL { home.appendingPathComponent("\(antigravity)/cache/conversation_metadata.json") }

    /// A home with Antigravity's list and what it keeps of each
    /// conversation, and a trash of the test's own.
    private func antigravityHome(list: String? = nil) throws -> URL {
        let trash = home.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        setenv(FileBrowser.trashVariable, trash.path, 1)
        addTeardownBlock { unsetenv(FileBrowser.trashVariable) }
        try FileManager.default.createDirectory(at: antigravityListFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (list ?? antigravityList).write(to: antigravityListFile, atomically: true, encoding: .utf8)
        for id in ["conv-1", "conv-2", "conv-3"] {
            try write("\(antigravity)/brain/\(id)/.system_generated/logs/transcript_full.jsonl", [#"{"type":"USER_INPUT","source":"USER_EXPLICIT","content":"said in \#(id)"}"#])
            try write("\(antigravity)/conversations/\(id).db", ["steps of \(id)"])
            try write("\(antigravity)/annotations/\(id).pbtxt", ["title: \"\(id)\""])
        }
        return trash
    }

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

    /// HIST-26 (#222): a conversation of Antigravity is deleted: its entry
    /// is taken out of Antigravity's list, what Antigravity keeps of that
    /// one conversation is moved to the Trash, and everything else the
    /// list holds stays byte for byte as it was.
    func testAConversationOfAntigravityIsDeletedFromItsListAndToTheTrash() throws {
        let trash = try antigravityHome()
        let base = home.appendingPathComponent(antigravity)
        XCTAssertEqual(Set(history().map(\.sessionID)), ["conv-1", "conv-2", "conv-3"])

        XCTAssertNil(AgentHistory.delete(try listed("conv-2"), home: home.path))

        // The list: the one line gone, nothing else touched.
        let wanted = antigravityList.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(#""conv-2": {"is_internal""#) }.joined(separator: "\n")
        XCTAssertEqual(try String(contentsOf: antigravityListFile, encoding: .utf8), wanted)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: antigravityListFile)) as? [String: Any], "no longer JSON")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(antigravityList.utf8)) as? NSDictionary)
        let entries = try XCTUnwrap(root["conversations"] as? [String: Any])
        XCTAssertEqual(Set(entries.keys), ["conv-1", "conv-3"])
        XCTAssertEqual(root["format_version"] as? Int, 3)
        XCTAssertEqual(root["x_future"] as? NSDictionary, before["x_future"] as? NSDictionary, "an unknown key at the top changed")
        for kept in ["conv-1", "conv-3"] {
            XCTAssertEqual(entries[kept] as? NSDictionary, (before["conversations"] as? NSDictionary)?[kept] as? NSDictionary, "\(kept) changed")
        }
        XCTAssertEqual((entries["conv-3"] as? [String: Any])?["x_kept"] as? NSArray, [1, 2, ["a": NSNull()]], "an unknown key in an entry changed")
        // Nothing left beside the list by the rewriting.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: antigravityListFile.deletingLastPathComponent().path), ["conversation_metadata.json"])

        // What was that one conversation's is in the Trash, the others' is not.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)), ["conv-2", "conv-2.db", "conv-2.pbtxt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("conv-2/.system_generated/logs/transcript_full.jsonl").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("brain").path)), ["conv-1", "conv-3"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("conversations").path)), ["conv-1.db", "conv-3.db"])
        XCTAssertEqual(Set(history().map(\.sessionID)), ["conv-1", "conv-3"], "still listed")

        // The last of the list, then the only one left: still JSON each time.
        XCTAssertNil(AgentHistory.delete(try listed("conv-3"), home: home.path))
        XCTAssertEqual(Set(history().map(\.sessionID)), ["conv-1"])
        XCTAssertNil(AgentHistory.delete(try listed("conv-1"), home: home.path))
        let emptied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: antigravityListFile)) as? [String: Any], "no longer JSON")
        XCTAssertEqual(emptied["conversations"] as? NSDictionary, [:])
        XCTAssertEqual(emptied["x_future"] as? NSDictionary, before["x_future"] as? NSDictionary)
        XCTAssertEqual(emptied["format_version"] as? Int, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("brain").path), [])
    }

    /// HIST-26 (#222): refused when Antigravity's list cannot be read, and
    /// nothing is rewritten or moved.
    func testAConversationOfAntigravityIsNotDeletedWhenItsListCannotBeRead() throws {
        let trash = try antigravityHome()
        let conversation = try listed("conv-2")
        // Not there at all.
        try FileManager.default.removeItem(at: antigravityListFile)
        var before = try everything()
        XCTAssertTrue(try XCTUnwrap(AgentHistory.delete(conversation, home: home.path)).hasPrefix("Antigravity's list of conversations could not be read, so nothing was deleted"))
        XCTAssertEqual(try everything(), before)
        // There, and not JSON: cut off while it was written.
        try String(antigravityList.prefix(200)).write(to: antigravityListFile, atomically: true, encoding: .utf8)
        before = try everything()
        XCTAssertTrue(try XCTUnwrap(AgentHistory.delete(conversation, home: home.path)).hasPrefix("Antigravity's list of conversations is not written the way AgentTerm knows"))
        XCTAssertEqual(try everything(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    /// HIST-26 (#222): refused when the list has a shape AgentTerm does
    /// not know, so that a later format is never rewritten.
    func testAConversationOfAntigravityIsNotDeletedWhenItsListHasAnotherShape() throws {
        let entry = #"{"is_internal": false, "summary": {"Title": "Write the parser", "UpdatedAt": "2026-11-11T17:00:22Z", "WorkspaceURIs": ["file:///Users/me/Dev/my.app"]}}"#
        let trash = try antigravityHome()
        let conversation = try listed("conv-2")
        for other in [
            // The conversations as a list, not by their ids.
            #"{"conversations": [{"id": "conv-2", "summary": {"Title": "Write the parser"}}]}"#,
            // An entry that is not an object.
            #"{"conversations": {"conv-2": \#(entry), "conv-9": "elsewhere"}}"#,
            // No conversations at the top; the list one level down.
            #"{"version": 4, "data": {"conversations": {"conv-2": \#(entry)}}}"#,
            // Not an object at all.
            #"[{"conversations": {"conv-2": \#(entry)}}]"#,
            // The same key twice: which one Antigravity reads is not known.
            #"{"conversations": {"conv-2": \#(entry)}, "conversations": {"conv-2": \#(entry), "conv-1": \#(entry)}}"#,
        ] {
            try other.write(to: antigravityListFile, atomically: true, encoding: .utf8)
            let before = try everything()
            XCTAssertTrue(
                try XCTUnwrap(AgentHistory.delete(conversation, home: home.path), "deleted from \(other)").hasPrefix("Antigravity's list of conversations is not written the way AgentTerm knows"),
                other)
            XCTAssertEqual(try everything(), before, other)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    /// HIST-26 (#222): one that is not in the list is said to be gone
    /// already, and only what is under Antigravity's own folder is ever
    /// touched, whatever a client names.
    func testAConversationOfAntigravityThatIsNotInItsListIsSaidToBeGone() throws {
        let trash = try antigravityHome()
        var conversation = try listed("conv-2")
        let before = try everything()
        conversation.sessionID = "conv-9"
        conversation.source = nil
        XCTAssertEqual(AgentHistory.delete(conversation, home: home.path), "It is gone from Antigravity's list already.")
        XCTAssertEqual(try everything(), before)

        // Forged: a file elsewhere, another conversation's folder, an id that leaves the folder.
        try write("notes.jsonl", ["mine"])
        let untouched = try everything()
        var forged = try listed("conv-2")
        forged.source = home.appendingPathComponent("notes.jsonl").path
        XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Antigravity.")
        forged.source = home.appendingPathComponent("\(antigravity)/brain/conv-1/.system_generated/logs/transcript_full.jsonl").path
        XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Antigravity.")
        forged.source = home.appendingPathComponent("\(antigravity)/brain/conv-2/../../../../notes.jsonl").path
        XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Antigravity.")
        for id in ["..", ".", "a/b", ""] {
            forged = Conversation(agent: "agy", sessionID: id, title: "t", updatedAt: Date(), cwd: project, source: nil)
            XCTAssertEqual(AgentHistory.delete(forged, home: home.path), "That is not a conversation of Antigravity.", id)
        }
        XCTAssertEqual(try everything(), untouched)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path), [])
    }

    /// HIST-26 (#222): when what is the conversation's cannot be moved to
    /// the Trash, the list is put back as it was, and it says so.
    func testAntigravitysListIsPutBackWhenTheTrashFails() throws {
        _ = try antigravityHome()
        let conversation = try listed("conv-2")
        // A Trash that cannot be: a folder under what is a file.
        try write("a-file", ["not a folder"])
        setenv(FileBrowser.trashVariable, home.appendingPathComponent("a-file/trash").path, 1)
        let before = try everything()
        let said = try XCTUnwrap(AgentHistory.delete(conversation, home: home.path))
        XCTAssertTrue(said.hasPrefix("It could not be moved to the Trash: "), said)
        XCTAssertTrue(said.hasSuffix(" Antigravity's list was put back as it was."), said)
        XCTAssertEqual(try everything(), before)
        XCTAssertEqual(Set(history().map(\.sessionID)), ["conv-1", "conv-2", "conv-3"])
    }

    func testDatesWithAnyFractionParse() {
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-11T04:32:36.5Z"))
        XCTAssertNotNil(AgentHistory.parseDate("2026-11-10T17:00:22.474318735+07:00"))
        XCTAssertNil(AgentHistory.parseDate("yesterday"))
    }
}
