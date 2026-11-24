import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// FOLDERS-1 (#264): with `CLAUDE_CONFIG_DIR` and `CODEX_HOME` set, in the
/// host's environment or only in the user's login shell, every part of the
/// host uses the folder the agent uses: setup's status line and hooks, a
/// schedule's trust, the history, a conversation's delete, the model
/// configured. As Claude Code 2.1.330 and Codex 0.171.0 were seen to.
final class AgentFoldersTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var claude: URL!
    private var codex: URL!
    private let project = "/Users/me/Dev/app"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-folders-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        claude = root.appendingPathComponent("claude-config")
        codex = root.appendingPathComponent("codex-home")
        for folder in [home!, claude!, codex!] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A conversation of each agent where its folder is, and the model Codex
    /// is set to.
    private func agentsFiles() throws {
        try write(
            claude.appendingPathComponent("projects/\(AgentHistory.claudeProjectName(for: project))/aaaa-1111.jsonl"),
            #"{"type":"user","message":{"role":"user","content":"fix the bug"},"sessionId":"aaaa-1111"}"# + "\n")
        try write(
            codex.appendingPathComponent("sessions/2026/11/23/rollout-2026-11-23T01-00-00-id-one.jsonl"),
            #"{"type":"session_meta","payload":{"id":"id-one","cwd":"\#(project)"}}"# + "\n")
        try write(codex.appendingPathComponent("history.jsonl"), #"{"session_id":"id-one","ts":1,"text":"add dark mode"}"# + "\n")
        try write(codex.appendingPathComponent("config.toml"), "model = \"o9-mini\"\n")
    }

    private func checkEveryPart(folders: AgentFolders?) throws {
        try agentsFiles()
        // A schedule's trust: in the folder's .claude.json, not the home's.
        try ScheduleRunner.trustFolder(of: Schedule(name: "n", agent: "claude", folder: "/work", prompt: "p", when: .limitReset), home: home.path, folders: folders)
        XCTAssertTrue(try String(contentsOf: claude.appendingPathComponent(".claude.json"), encoding: .utf8).contains("/work"), "the trust is not where Claude Code reads it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path), "the trust went to the home")

        // The history, both agents.
        let found = AgentHistory.conversations(in: project, home: home.path, folders: folders)
        XCTAssertEqual(Set(found.map(\.sessionID)), ["aaaa-1111", "id-one"])
        XCTAssertEqual(found.first { $0.agent == "codex" }?.title, "add dark mode")

        // A conversation's delete: taken as the agent's.
        let conversation = try XCTUnwrap(found.first { $0.agent == "claude" })
        let trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        setenv("AGENTTERM_TRASH_DIR", trash.path, 1)
        defer { unsetenv("AGENTTERM_TRASH_DIR") }
        XCTAssertNil(AgentHistory.delete(conversation, home: home.path, folders: folders))
        XCTAssertFalse(FileManager.default.fileExists(atPath: conversation.source ?? ""), "not deleted")
        // Still confined: the home's own folder is not the agent's now.
        var elsewhere = conversation
        elsewhere.source = home.appendingPathComponent(".claude/projects/x/y.jsonl").path
        XCTAssertNotNil(AgentHistory.delete(elsewhere, home: home.path, folders: folders))
    }

    func testTheHostsOwnVariablesAreFollowedEverywhere() throws {
        setenv("CLAUDE_CONFIG_DIR", claude.path, 1)
        setenv("CODEX_HOME", codex.path, 1)
        defer {
            unsetenv("CLAUDE_CONFIG_DIR")
            unsetenv("CODEX_HOME")
        }
        try checkEveryPart(folders: nil)
        XCTAssertEqual(AgentUsage.configuredModel(agent: "codex", home: home.path), "o9-mini")
    }

    /// Only the login shell has them, as for a host started by the app or
    /// at login when the user exports them in `.zshrc`.
    func testTheLoginShellsVariablesAreFollowedEverywhere() throws {
        let shell = root.appendingPathComponent("shell")
        try write(shell, "#!/bin/sh\nexport CLAUDE_CONFIG_DIR='\(claude.path)'\nexport CODEX_HOME='\(codex.path)'\nshift 3\nexec /bin/sh -c \"$1\"\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let folders = AgentFolders.of(home: home.path, own: [:], shell: LoginShellPath(shell: { shell.path }))
        XCTAssertEqual(folders.claude, claude.path)
        XCTAssertEqual(folders.claudeState, claude.path + "/.claude.json")
        XCTAssertEqual(folders.codex, codex.path)
        try checkEveryPart(folders: folders)

        // Setup writes the status line and the hooks where the agents read.
        let setup = AgentSetup(
            directory: root.appendingPathComponent("plugins"), tool: "/usr/bin/true", home: home.path, environment: [:], locate: { [] }, prompt: { _ in nil }, run: { _ in (0, "") }, folders: folders)
        try setup.setClaudeStatusLine()
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json").path), "the status line is not where Claude Code reads it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
        XCTAssertEqual(setup.codexConfig.path, codex.appendingPathComponent("config.toml").path)
    }

    func testWithNoVariableTheFoldersAreTheHomes() {
        let folders = AgentFolders(home: "/Users/me", environment: ["CLAUDE_CONFIG_DIR": "", "OTHER": "x"])
        XCTAssertEqual(folders, AgentFolders(home: "/Users/me", environment: [:]))
        XCTAssertEqual(folders.claude, "/Users/me/.claude")
        XCTAssertEqual(folders.claudeState, "/Users/me/.claude.json")
        XCTAssertEqual(folders.codex, "/Users/me/.codex")
    }
}
