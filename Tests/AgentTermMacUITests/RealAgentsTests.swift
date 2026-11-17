import AgentTermProtocol
import AppKit
import XCTest

/// The real agents, run by hand only (`AGENTTERM_REAL_AGENTS=1
/// scripts/test-mac.sh RealAgentsTests`): what a stand-in cannot show, the
/// agents as they are, at the versions installed, tell the host what they
/// do, and the app shows it. Each is asked one short thing, in this
/// repository, which all four trust, and spends a little of the user's
/// accounts.
///
/// The host has a state folder and a port of its own, but the user's home,
/// where the agents are signed in; a host with a state folder of its own
/// changes none of the agents' configuration and no login item. It is the
/// development build's `agenttermd` in dist/, whose hooks Codex was told to
/// trust, so that Codex asks nothing about them (#124). The app keeps a home
/// of its own.
final class RealAgentsTests: MacUITestCase {
    static let agents = ["claude", "codex", "copilot", "agy"]
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let developmentHost = repository.appendingPathComponent("dist/AgentTerm Dev.app/Contents/MacOS/agenttermd")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTTERM_REAL_AGENTS"] != nil, "spends the user's accounts: run by hand")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.developmentHost.path), "no development build in dist/")
        try super.setUpWithError()
    }

    override var hostExecutable: URL { Self.developmentHost }
    override var hostHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The agents' own programs, found as the user's shell finds them.
    override func beforeTheHostStarts() throws {
        let folder = root.appendingPathComponent("agents")
        for agent in Self.agents {
            let link = folder.appendingPathComponent(agent)
            try? FileManager.default.removeItem(at: link)
            let found = Self.which(agent)
            try XCTSkipIf(found == nil, "\(agent) is not installed")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: found!))
        }
    }

    static func which(_ program: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(program)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return found.hasPrefix("/") ? found : nil
    }

    /// INBOX-5 (#67), by hand: each of the four, asked to run a command and
    /// answer while another session is in front, comes to the Inbox, done or
    /// asking; what each told is written out.
    func testTheRealAgentsComeToTheInbox() throws {
        let phone = try device()
        app.press(.button("Shell"))
        wait("the shell") { phone.sessions.count == 1 }
        let shell = try XCTUnwrap(phone.sessions.first?.id)
        bringAppToFront()
        app.press(.id("session-\(shell)"))

        let folder = Self.repository.path
        for agent in Self.agents {
            phone.send(.create(CreateRequest(command: root.appendingPathComponent("agents/\(agent)").path, cwd: folder, title: "real-\(agent)")))
        }
        wait("the four sessions", timeout: 20) { phone.sessions.count == 5 }
        var ids: [String: SessionID] = [:]
        for agent in Self.agents { ids[agent] = phone.sessions.first { $0.title == "real-\(agent)" }?.id }
        XCTAssertEqual(ids.count, 4)
        // Started, and ready for a prompt.
        Thread.sleep(forTimeInterval: 10)
        shot("started")
        for agent in Self.agents {
            guard let id = ids[agent] else { continue }
            phone.connection.sendInput(Data("Run `sleep 3` in the shell, then reply with one short sentence.".utf8), to: id)
        }
        Thread.sleep(forTimeInterval: 1)
        for agent in Self.agents {
            guard let id = ids[agent] else { continue }
            phone.connection.sendInput(Data("\r".utf8), to: id)
        }
        // Each works, then is done or asks.
        let deadline = Date().addingTimeInterval(240)
        var seenWorking: Set<String> = []
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            for agent in Self.agents where phone.sessions.first(where: { $0.id == ids[agent] })?.state?.isWorking == true { seenWorking.insert(agent) }
            let settled = Self.agents.filter { agent in
                guard let state = phone.sessions.first(where: { $0.id == ids[agent] })?.state else { return false }
                return !state.isWorking && seenWorking.contains(agent)
            }
            if settled.count == Self.agents.count { break }
        }
        for agent in Self.agents {
            let info = phone.sessions.first { $0.id == ids[agent] }
            print("MEASURE real \(agent): worked=\(seenWorking.contains(agent)) state=\(info?.state.map { "\($0)" } ?? "none") unseen=\(info?.unseen.map { "\($0)" } ?? "nil")")
        }
        shot("settled")

        // What the Inbox holds, on the Mac.
        app.press(.id("place-inbox"))
        Thread.sleep(forTimeInterval: 1)
        let rows = app.nodes().filter { $0.identifier.hasPrefix("inbox-session-") }
        for row in rows { print("MEASURE inbox row: \(row.label)") }
        shot("inbox")
        var missing: [String] = []
        for agent in Self.agents {
            guard let id = ids[agent] else { continue }
            if app.first(.id("inbox-session-\(id)")) == nil {
                missing.append(agent)
                continue
            }
            app.press(.id("inbox-session-\(id)"))
            Thread.sleep(forTimeInterval: 0.7)
            shot("inbox-\(agent)")
        }
        XCTAssertTrue(missing.isEmpty, "not in the Inbox: \(missing)")
    }
}
