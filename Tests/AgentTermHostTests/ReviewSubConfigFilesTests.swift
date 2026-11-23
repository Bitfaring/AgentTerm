import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What the host writes into files of the user's and of the agents'
/// (review of 2026-11-22): a symbolic link (#263), the folders
/// `CLAUDE_CONFIG_DIR` and `CODEX_HOME` name (#264), and a Codex
/// `config.toml` that could not be read (#265). All in a folder of the
/// test's own.
final class ReviewSubConfigFilesTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-config-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func setup(environment: [String: String] = [:], run: @escaping AgentSetup.Run = { _ in (0, "") }) -> AgentSetup {
        AgentSetup(
            directory: root.appendingPathComponent("setup"), tool: "/Apps/AgentTerm Dev.app/agenttermd", home: home.path, name: "agentterm-dev",
            environment: environment, locate: { [] }, prompt: { _ in nil }, run: run)
    }

    /// A file kept elsewhere (a dotfiles folder) and linked to from `path`.
    private func linked(_ path: URL, text: String) throws -> URL {
        let real = root.appendingPathComponent("dotfiles").appendingPathComponent(path.lastPathComponent)
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: real)
        return real
    }

    private func isLink(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    // MARK: #263

    /// #263: Claude Code's settings kept as a link stay a link when the
    /// status line is written into them, and the file linked to gets it.
    func testClaudesSettingsThatAreALinkStayALink() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        let real = try linked(settings, text: #"{"theme":"dark"}"#)
        try setup().setClaudeStatusLine()
        XCTAssertTrue(isLink(settings), "the link was replaced by a plain file")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("statusline"), "the file linked to did not get the status line")
    }

    /// #263: Codex's `config.toml` kept as a link, the same.
    func testCodexsConfigurationThatIsALinkStaysALink() throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        let real = try linked(config, text: "model = \"o3\"\n")
        try setup().addCodexHooks(path: "/usr/bin/true")
        XCTAssertTrue(isLink(config), "the link was replaced by a plain file")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("AgentTerm's hook"), "the file linked to did not get the hooks")
    }

    /// #263: a file saved from the Files tab that is a link, the same.
    func testAFileSavedThroughALinkStaysALink() throws {
        let file = home.appendingPathComponent("project/notes.md")
        let real = try linked(file, text: "before\n")
        try FileBrowser.write("after\n", to: file.path)
        XCTAssertTrue(isLink(file), "the link was replaced by a plain file")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "after\n", "the file linked to was not written")
    }

    /// #263: the folder an agent is trusted in for a schedule, the same.
    func testTheTrustFileThatIsALinkStaysALink() throws {
        let file = home.appendingPathComponent(".claude.json")
        let real = try linked(file, text: #"{"numStartups":3}"#)
        try ScheduleRunner.trustFolder(of: Schedule(name: "n", agent: "claude", folder: "/work", prompt: "p", when: .limitReset), home: home.path)
        XCTAssertTrue(isLink(file), "the link was replaced by a plain file")
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains("/work"), "the file linked to did not get the folder")
    }

    // MARK: #264

    /// Sets a variable of this process for the test, and puts back what was there.
    private func with(_ name: String, _ value: String, _ body: () throws -> Void) rethrows {
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        try body()
    }

    /// #264: with `CLAUDE_CONFIG_DIR` in the host's environment, the status
    /// line is written where it names (the ground of the next two tests).
    func testTheStatusLineGoesWhereClaudeConfigDirNames() throws {
        let own = root.appendingPathComponent("claude-own")
        try setup(environment: ["CLAUDE_CONFIG_DIR": own.path]).setClaudeStatusLine()
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    // MARK: #265

    /// A `config.toml` with one byte that is not UTF-8, in a comment.
    private func unreadableConfig() throws -> (file: URL, data: Data) {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("model = \"o3\"\n# caf".utf8)
        data.append(0xE9)
        data.append(Data("\n[features]\nweb_search = true\n".utf8))
        try data.write(to: config)
        return (config, data)
    }

    /// #265: a `config.toml` that cannot be read as UTF-8 is not replaced
    /// by the hooks alone: what the user had is still in it, or it is left
    /// as it was and the reason said.
    func testAConfigurationThatCannotBeReadIsNotReplaced() throws {
        let (config, before) = try unreadableConfig()
        try? setup().addCodexHooks(path: "/usr/bin/true")
        let after = try Data(contentsOf: config)
        XCTAssertNotNil(after.range(of: Data("model = \"o3\"".utf8)), "the user's configuration is gone: \(after.count) bytes where there were \(before.count)")
    }

    /// #265: and when Codex then refuses the file, it is put back as it
    /// was, not deleted.
    func testAConfigurationThatCannotBeReadIsNotDeletedWhenCodexRefusesIt() throws {
        let (config, before) = try unreadableConfig()
        XCTAssertThrowsError(try setup(run: { _ in (1, "error: could not parse config.toml") }).addCodexHooks(path: "/usr/bin/false"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path), "the user's config.toml was deleted")
        XCTAssertEqual(try? Data(contentsOf: config), before, "the user's config.toml is not what it was")
    }
}
