import AgentTermProtocol
import Foundation
import XCTest

/// TEST-11 (#207): the tests run from a session of the installed AgentTerm,
/// whose own variables (its hooks' file, its status line's, its MCP
/// server's key) are in the test runner's environment. The test's host, its
/// app and their sessions get no `AGENTTERM_` variable the test did not
/// set.
final class OwnEnvironmentTests: MacUITestCase {
    private let theirs = "of-the-installed-app-207"
    /// What a session of the installed app has, and one more of AgentTerm's
    /// that the person running the tests may have set.
    private let names = ["AGENTTERM_EVENTS", "AGENTTERM_USAGE", "AGENTTERM_MCP", "AGENTTERM_DEV_EVENTS", "AGENTTERM_DEV_USAGE", "AGENTTERM_PANE_PLACES"]
    private var before: [String?] = []

    override func setUpWithError() throws {
        before = names.map { ProcessInfo.processInfo.environment[$0] }
        for name in names { setenv(name, theirs, 1) }
        try super.setUpWithError()
    }

    override func tearDown() {
        super.tearDown()
        for (name, value) in zip(names, before) {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }

    /// The names of the variables a program was started with that have the
    /// outer session's value; nothing of a value, which a failure prints.
    private func inherited(by pid: pid_t) -> [String]? {
        Self.argumentsAndEnvironment(of: pid).map { $0.1.filter { $0.key.hasPrefix("AGENTTERM_") && $0.value == theirs }.keys.sorted() }
    }

    func testTheTestsHostAppAndSessionsGetNoneOfTheVariablesOfTheSessionTheTestsRunIn() throws {
        let hosts = listeners(on: port)
        XCTAssertFalse(hosts.isEmpty, "no host listens on \(port)")
        for pid in hosts { XCTAssertEqual(inherited(by: pid), [], "the test's host") }
        XCTAssertEqual(inherited(by: try XCTUnwrap(app).pid), [], "the test's app")
        let said = root.appendingPathComponent("said")
        let device = try device()
        let command = "env | sed -n 's/^\\(AGENTTERM_[A-Z_]*\\)=\(theirs)$/\\1/p' > '\(said.path).new'; mv '\(said.path).new' '\(said.path)'; exec sleep 600"
        device.send(.create(CreateRequest(command: command, cwd: project.path)))
        wait("the session to start") { FileManager.default.fileExists(atPath: said.path) }
        let names = ((try? String(contentsOf: said, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(names, [], "a session of the test's host")
    }
}
