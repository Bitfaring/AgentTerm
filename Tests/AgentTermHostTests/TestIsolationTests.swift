import AgentTermClient
import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// What the host's tests start reads nothing of the person running them.
final class TestIsolationTests: XCTestCase {
    /// Sets a variable for the test, as the person's own shell may have it,
    /// and puts back what was there.
    private func with(_ name: String, _ value: String, _ body: () throws -> Void) rethrows {
        let before = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let before { setenv(name, before, 1) } else { unsetenv(name) } }
        try body()
    }

    /// TEST-2: under the tests, a session's shell and a command run through
    /// the login shell read their startup files from the tests' own empty
    /// folder, also when the person running the tests has ZDOTDIR set.
    func testTheShellsReadNoneOfTheStartupFilesOfThePersonRunningTheTests() {
        let theirs = "/Users/someone/.config/zsh"
        with("ZDOTDIR", theirs) {
            let session = HostEnvironment.sessionEnvironment()["ZDOTDIR"]
            XCTAssertNotNil(session)
            XCTAssertNotEqual(session, theirs, "a session's shell")
            let command = HostEnvironment.loginShellCommandEnvironment?["ZDOTDIR"]
            XCTAssertNotNil(command)
            XCTAssertNotEqual(command, theirs, "a command run through the login shell")
        }
    }

    /// TEST-3: under the tests, git reads no global configuration of the
    /// person running them (their identity, hooks, signing): not the git
    /// the host runs, nor one run in a session.
    func testGitReadsNoGlobalConfigurationOfThePersonRunningTheTests() throws {
        let result = try XCTUnwrap(Subprocess.run("/usr/bin/git", ["config", "--global", "--list"]))
        // What it read is not printed: it is theirs.
        XCTAssertTrue(result.status != 0 || result.output.isEmpty, "the git the host runs read a global configuration")
        let explicit = try XCTUnwrap(Subprocess.run("/usr/bin/git", ["config", "--global", "--list"], environment: ProcessInfo.processInfo.environment))
        XCTAssertTrue(explicit.status != 0 || explicit.output.isEmpty, "nor with an environment given")
        XCTAssertEqual(HostEnvironment.sessionEnvironment()["GIT_CONFIG_GLOBAL"], "/dev/null", "nor in a session")
    }

    /// TEST-10 (#207): the tests run from a session of the installed
    /// AgentTerm, which gives them that session's own variables (its hooks'
    /// file, its status line's, its MCP server's key). A session of a test's
    /// host gets none of them: what it has of those names is its own host's,
    /// or nothing.
    func testASessionOfATestsHostGetsNoneOfTheVariablesOfTheSessionTheTestsRunIn() throws {
        let theirs = "of-the-installed-app-207"
        let names = [
            AppChannel.release.eventsVariable, AppChannel.dev.eventsVariable, AppChannel.release.usageVariable, AppChannel.dev.usageVariable,
            HostServer.agentShellsVariable,
        ]
        let before = names.map { ProcessInfo.processInfo.environment[$0] }
        for name in names { setenv(name, theirs, 1) }
        defer {
            for (name, value) in zip(names, before) {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentterm-inherited-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let said = root.appendingPathComponent("said")
        let token = "test-token-0123456789abcdef0123456789"
        var configuration = HostServer.Configuration(
            port: 0, token: token, listenOnTailscale: false, detectAgents: { [] }, statusLineTool: "/usr/bin/true",
            usageDirectory: root.appendingPathComponent("usage"))
        configuration.foldersFile = root.appendingPathComponent("state/folders.json")
        let server = HostServer(configuration: configuration)
        let port = try server.start()
        defer { server.stop() }
        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        defer { client.close() }
        client.connect()
        // The names of those it has with the outer session's value, and
        // nothing of their values, which a failure would print.
        let command = "env | sed -n 's/^\\(AGENTTERM_[A-Z_]*\\)=\(theirs)$/\\1/p' > '\(said.path).new'; mv '\(said.path).new' '\(said.path)'; exec sleep 600"
        client.send(.create(CreateRequest(command: command, cwd: root.path)))
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: said.path) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let inherited = try XCTUnwrap(try? String(contentsOf: said, encoding: .utf8), "the session did not start").split(separator: "\n").map(String.init)
        XCTAssertEqual(inherited, [], "the test's session was given the outer session's own")
    }
}
