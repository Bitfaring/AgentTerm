import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// SETUP-11 (#259): two builds' status line relays never run each other
/// without end. A build set up after the other runs the other's after its
/// own (MCP-15), once; the relay that one runs runs only the user's, and a
/// build set up again keeps the user's own over the other build's.
final class ReviewSubStatusLineTests: XCTestCase {
    private var root: URL!
    private var home: URL { root.appendingPathComponent("home") }
    private var tool: URL { Bundle(for: ReviewSubStatusLineTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agenttermd") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-review-statusline-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func setup(name: String, tool: String) -> AgentSetup {
        AgentSetup(
            directory: root.appendingPathComponent("setup-\(name)"), tool: tool, home: home.path, name: name, environment: [:],
            locate: { [] }, prompt: { _ in nil }, run: { _ in nil })
    }

    private func keptCommand(_ setup: AgentSetup) throws -> String? {
        let file = AgentSetup.previousStatusLine(in: root.appendingPathComponent("setup-\(setup.name)"))
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["command"] as? String
    }

    /// The released build is set up, then the development build, then the
    /// released build again (it says its status line is "not known"). The
    /// released build keeps the user's own; the development build the
    /// released build's, which it took the place of.
    func testSetUpAgainAfterTheOtherBuildTheUsersOwnIsKept() throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        try #"{"statusLine":{"type":"command","command":"printf mine"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let released = setup(name: "agentterm", tool: "/Applications/AgentTerm.app/Contents/MacOS/agenttermd")
        let development = setup(name: "agentterm-dev", tool: "/Applications/AgentTerm Dev.app/Contents/MacOS/agenttermd")

        try released.setClaudeStatusLine()
        XCTAssertEqual(try keptCommand(released), "printf mine")
        try development.setClaudeStatusLine()
        XCTAssertEqual(try keptCommand(development), released.statusLineCommand)
        try released.setClaudeStatusLine()
        XCTAssertEqual(try keptCommand(released), "printf mine", "the released build no longer keeps the user's own status line")
    }

    /// A stand-in relay that writes a line for each time it is run, and
    /// whether it was run by a relay.
    private func standInRelay() throws -> (command: String, ran: URL) {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ran = root.appendingPathComponent("ran")
        let standIn = bin.appendingPathComponent("agenttermd")
        try "#!/bin/sh\necho \"run ${\(StatusLineRelay.relayedVariable):-}\" >> '\(ran.path)'\n".write(to: standIn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
        return (Handoff.shellQuote(standIn.path) + " statusline", ran)
    }

    private func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The other build's relay, kept, is run, and told it is run by a relay.
    func testTheOtherBuildsRelayIsRunToldItIsRelayed() throws {
        let (command, ran) = try standInRelay()
        let previous = root.appendingPathComponent("previous-status-line.json")
        try JSONSerialization.data(withJSONObject: ["type": "command", "command": command]).write(to: previous)
        _ = StatusLineRelay.run(input: Data(#"{"cwd":"/tmp"}"#.utf8), file: nil, previous: previous, home: home.path, environment: [:])
        XCTAssertEqual(lines(ran), ["run 1"])
    }

    /// A relay run by a relay runs no relay it keeps.
    func testARelayRunByARelayRunsNoRelay() throws {
        let (command, ran) = try standInRelay()
        let previous = root.appendingPathComponent("previous-status-line.json")
        try JSONSerialization.data(withJSONObject: ["type": "command", "command": command]).write(to: previous)
        _ = StatusLineRelay.run(
            input: Data(#"{"cwd":"/tmp"}"#.utf8), file: nil, previous: previous, home: home.path, environment: [StatusLineRelay.relayedVariable: "1"])
        XCTAssertEqual(lines(ran), [], "a relay run by a relay ran the relay it keeps")
    }

    /// The real `agenttermd statusline`, whose kept command leads back to
    /// itself, as two builds that keep each other's do, goes round once.
    /// It leads back through a stand-in that counts and gives up after 4
    /// turns, so that the test cannot run for ever: before the fix each
    /// turn started the next with no end.
    func testTheRealRelayDoesNotRunItselfAgain() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool.path), "agenttermd is not built next to the tests")
        let state = root.appendingPathComponent("state")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let turns = root.appendingPathComponent("turns")
        let standIn = bin.appendingPathComponent("agenttermd")
        try """
        #!/bin/sh
        echo turn >> '\(turns.path)'
        [ "$(wc -l < '\(turns.path)')" -ge 4 ] && exit 0
        exec '\(tool.path)' statusline

        """.write(to: standIn, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)
        let previous = AgentSetup.previousStatusLine(in: state.appendingPathComponent("agent-setup"))
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "command", "command": Handoff.shellQuote(standIn.path) + " statusline"]).write(to: previous)

        let process = Process()
        process.executableURL = tool
        process.arguments = ["statusline"]
        var environment = OwnEnvironment.withoutAgentTerms
        environment["AGENTTERM_STATE_DIR"] = state.path
        environment["HOME"] = home.path
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"cwd":"/tmp"}"#.utf8))
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        _ = Subprocess.run("/usr/bin/pkill", ["-f", root.path])

        let count = ((try? String(contentsOf: turns, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(count, 1, "the real relay went round \(count) times through a kept command that is an AgentTerm status line")
    }
}
