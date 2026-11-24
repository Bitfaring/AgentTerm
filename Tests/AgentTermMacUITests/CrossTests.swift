import AgentTermClient
import AgentTermProtocol
import XCTest

/// The Mac app's half of the test that runs it together with the iPhone
/// app on one host. `scripts/test-both.sh` starts the host and both apps
/// and runs this in two parts, the iPhone app's own test in between: what
/// one app does, the other has to show.
final class CrossTests: XCTestCase {
    private var app: MacDriver!
    private let environment = ProcessInfo.processInfo.environment
    private var project: URL { URL(fileURLWithPath: environment["AGENTTERM_CROSS_PROJECT"] ?? "") }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGENTTERM_CROSS_PID"] != nil, "run through scripts/test-both.sh")
        let pid = try XCTUnwrap(environment["AGENTTERM_CROSS_PID"].flatMap { pid_t($0) })
        try XCTSkipUnless(MacDriver.isAllowed, "allow this terminal under System Settings > Privacy & Security > Accessibility")
        continueAfterFailure = false
        app = MacDriver(pid: pid)
        app.wait(for: .id("mac-switcher"), timeout: 20)
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0, let folder = environment["AGENTTERM_SHOT_DIR"], let app {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            app.capture(to: URL(fileURLWithPath: folder).appendingPathComponent("mac-\(name.filter { $0.isLetter || $0.isNumber }).png"))
        }
    }

    private func git(_ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", project.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertTrue(condition(), "timed out waiting for: \(what). On screen:\n\(app.screen())")
    }

    private func openSettings(_ pane: String) {
        app.menu([environment["AGENTTERM_CROSS_APP"] ?? "AgentTerm Dev", "Settings…"])
        app.press(.id("settings-\(pane.lowercased())"))
    }

    /// Before the iPhone app runs: what the Mac does, for the phone to find.
    func testPart1WhatTheMacDoesFirst() throws {
        // A session, for the phone to list and to type in.
        app.menu(["File", "New Shell"])
        app.wait(for: .id("session-1"), timeout: 15)
        // The Mac is kept awake, a setting the phone has to show as on.
        openSettings("General")
        app.press(.id("keep-awake"))
        wait("the switch to be on") { self.app.first(.id("keep-awake"))?.value == "1" }
        // The changes grouped by folder, a choice the phone has to follow,
        // in Sessions' side panel.
        app.press(.id("place-sessions"))
        app.press(.button("Group by folder"))
        app.wait(for: .button("Show as a flat list"))
        // And the changes the phone is going to commit are listed here.
        app.wait(for: .id("change-notes.txt"))

        // BROWSER-12: an agent with a shell and a page of its own, opened
        // through AgentTerm's MCP server, for the phone to find under it.
        let told = URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_AGENT_VARIABLE"]))
        app.press(.id("place-sessions"))
        app.press(.button("Claude Code"))
        wait("the agent to start") { FileManager.default.fileExists(atPath: told.path) }
        let server = try MCPServerProcess(
            tool: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_TOOL"])), variable: try String(contentsOf: told, encoding: .utf8),
            state: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_STATE"])))
        defer { server.stop() }
        let shell = server.text("shell_open", ["title": "agent-shell"])
        XCTAssertFalse(shell.failed, shell.text)
        // #108: lines written while the shell has the Mac's width, longer
        // than the phone's, for the phone to show all of.
        let number = try XCTUnwrap(shell.text.range(of: #"shell \d+"#, options: .regularExpression).flatMap { Int(shell.text[$0].dropFirst(6)) }, shell.text)
        let ran = server.text("shell_run", ["session": number, "command": "echo wide-line-$(printf 'x%.0s' $(seq 1 70))-end"])
        XCTAssertFalse(ran.failed, ran.text)
        // LINK-8 (#129): a shell opened with a shell's own key, as an agent
        // typed in a shell does, is the user's, for the phone to list.
        let shellsKey = told.deletingLastPathComponent().appendingPathComponent("shell-variable")
        let wrote = server.text("shell_run", ["session": number, "command": "printf '%s' \"$AGENTTERM_MCP\" > '\(shellsKey.path)'"])
        XCTAssertFalse(wrote.failed, wrote.text)
        let fromShell = try MCPServerProcess(
            tool: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_TOOL"])), variable: try String(contentsOf: shellsKey, encoding: .utf8),
            state: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_STATE"])))
        defer { fromShell.stop() }
        let opened = fromShell.text("shell_open", ["title": "from-a-shell"])
        XCTAssertFalse(opened.failed, opened.text)
        let page = app.browserOpen(server, ["url": try XCTUnwrap(environment["AGENTTERM_CROSS_PAGE"])])
        XCTAssertFalse(page.failed, page.text)
        app.wait(for: .id("agent-browser"), timeout: 20)
        wait("the page shown beside the agent") { self.app.value(of: .id("browser-page")) == "Cross page" }

        // BROWSER-67 (#251): it asks for a second profile, and the question
        // is left for the phone to answer.
        openSettings("Browser")
        app.press(.id("profile-new"))
        app.wait(for: .id("profile-name-Profile 2"))
        app.press(.id("place-sessions"))
        let asked = server.text("browser_open", ["url": try XCTUnwrap(environment["AGENTTERM_CROSS_PAGE"]), "profile": "Profile 2"])
        XCTAssertEqual(asked.text, BrowserWords.askingForProfile("Profile 2"))
        app.wait(for: .id("profile-question"), timeout: 10)
    }

    /// After the iPhone app ran: what it did, shown by the Mac.
    func testPart2WhatThePhoneDidShowsOnTheMac() throws {
        // GIT-12: the phone staged everything and committed; the Mac's list is empty and git has the commit.
        // The Mac reads the changes again by itself only while it is in
        // front, which it is not with the simulator on top: ask for it.
        app.press(.button("Refresh"))
        app.wait(for: .containing("No uncommitted changes"), timeout: 20)
        XCTAssertEqual(git("log", "-1", "--format=%s"), "test: from the phone")
        // GIT-6: the phone went back to a flat list, so the Mac offers the tree again.
        app.wait(for: .button("Group by folder"), timeout: 15)

        // AWAKE-2: the option the phone switched on is on here.
        openSettings("General")
        wait("the display option the phone switched on") { self.app.first(.button("Keep the display on too"))?.value == "1" }
        XCTAssertEqual(app.first(.id("keep-awake"))?.value, "1")

        // SES-6: the session the phone started is listed here too, in
        // Sessions: after the Mac's shell, its agent and the agent's shell.
        app.press(.id("place-sessions"))
        wait("the phone's own session beside the Mac's") { self.app.exists(.id("session-1")) && self.app.exists(.id("session-4")) }

        // BROWSER-12: the phone gave the agent's page back, after typing in
        // it; the page it opened of its own it closed.
        wait("the page the phone typed in") { self.app.exists(.containing("typed hi")) }

        // BROWSER-67 (#251): the phone allowed the agent "Profile 2": the
        // question is gone here too, and the agent's tab opens in it.
        app.waitGone(.id("profile-question"), timeout: 10)
        let told = URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_AGENT_VARIABLE"]))
        let server = try MCPServerProcess(
            tool: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_TOOL"])), variable: try String(contentsOf: told, encoding: .utf8),
            state: URL(fileURLWithPath: try XCTUnwrap(environment["AGENTTERM_CROSS_STATE"])))
        defer { server.stop() }
        let opened = server.text("browser_open", ["url": try XCTUnwrap(environment["AGENTTERM_CROSS_PAGE"]), "profile": "Profile 2"])
        XCTAssertFalse(opened.failed, opened.text)

        // Who is using a session is checked with the Mac app alone
        // (SessionTests): the iPhone app is closed when its test ends, and
        // the session is the Mac's again by the time this runs.
    }
}
