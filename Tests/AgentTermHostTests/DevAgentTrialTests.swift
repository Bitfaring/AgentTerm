import AgentTermClient
import AgentTermProtocol
import XCTest

/// MCP-35 (#156), by hand only and with the owner's leave
/// (`AGENTTERM_TRIAL_DEV=1 swift test --filter DevAgentTrialTests`): the four
/// real agents, each with its cheapest model and least thinking, started as
/// sessions of the development build the owner runs (`dist/AgentTerm Dev`,
/// its host on its own port), whose MCP server they are set up for, in a
/// folder of the trial's own; asked to run three commands; which they ran
/// them with is written out. Its sessions are ended at the end. It spends a
/// little of the owner's accounts.
final class DevAgentTrialTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var sessions: [SessionInfo] = []

    /// How each agent is started: its cheapest model and its least
    /// thinking, as far as it can be told so (as `RealAgentsTests` has it).
    private let agents: [(name: String, flags: String)] = [
        ("claude", "--model haiku"),
        ("codex", "-m gpt-5.6-luna -c model_reasoning_effort=low"),
        ("copilot", "--model auto --reasoning-effort low"),
        ("agy", ""),
    ]

    private func found(_ program: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(program)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return said.split(separator: "\n").map(String.init).first { $0.hasPrefix("/") }
    }

    private func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
    }

    func testTheRealAgentsInTheDevelopmentBuildRunTheirCommandsInItsShells() throws {
        try XCTSkipUnless(environment["AGENTTERM_TRIAL_DEV"] == "1", "runs in the owner's development build: by hand, with the owner's leave")
        let port = UInt16(environment["AGENTTERM_TRIAL_PORT"] ?? "7718") ?? 7718
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokenFile = home.appendingPathComponent("Library/Application Support/\(AppChannel.dev.appName)/token")
        let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        // The trial's own folder, in this repository (which the four trust)
        // and outside what git keeps.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let trial = repository.appendingPathComponent(".build/agent-trial")
        let bin = repository.appendingPathComponent(".build/agent-trial-bin")
        try? FileManager.default.removeItem(at: trial)
        try FileManager.default.createDirectory(at: trial.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "a file of the trial's\n".write(to: trial.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for name in ["one.md", "two.md", "three.md"] {
            try "# \(name)\n".write(to: trial.appendingPathComponent("docs/\(name)"), atomically: true, encoding: .utf8)
        }
        var commands: [String: String] = [:]
        let only = environment["AGENTTERM_TRIAL_ONLY"]
        for agent in agents where only == nil || only == agent.name {
            guard let path = found(agent.name) else { continue }
            let wrapper = bin.appendingPathComponent(agent.name)
            try "#!/bin/sh\nexec '\(path)' \(agent.flags) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            commands[agent.name] = wrapper.path
        }

        let client = AgentTermConnection(host: "127.0.0.1", port: port, credential: .token(token), clientName: "mac")
        client.onMessage = { [weak self] message in
            if case .sessions(let list) = message { self?.sessions = list }
        }
        client.connect()
        spin(10) { !self.sessions.isEmpty }
        let before = Set(sessions.map(\.id))
        for agent in agents {
            guard let command = commands[agent.name] else { continue }
            client.send(.create(CreateRequest(command: command, cwd: trial.path, title: "trial-\(agent.name)")))
        }
        spin(20) { self.sessions.filter { $0.title.hasPrefix("trial-") && !before.contains($0.id) }.count == commands.count }
        var ids: [String: SessionID] = [:]
        for agent in agents { ids[agent.name] = sessions.first { $0.title == "trial-\(agent.name)" && !before.contains($0.id) }?.id }
        defer {
            // Ended: they and the shells they opened.
            for id in ids.values { client.send(.kill(session: id)) }
            spin(3)
            for session in sessions where ids.values.contains(where: { $0 == session.openedBy }) { client.send(.kill(session: session.id)) }
            spin(2)
            client.close()
        }
        for id in ids.values { client.send(.attach(session: id, size: TermSize(cols: 120, rows: 40))) }
        spin(15)
        let prompt = "Run `ls`, then `ls docs`, then `cat a.txt`, one after the other, and tell me in one sentence how many files docs has."
        for id in ids.values { client.sendInput(Data(prompt.utf8), to: id) }
        spin(1)
        for id in ids.values { client.sendInput(Data("\r".utf8), to: id) }
        var worked: Set<SessionID> = []
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            spin(0.5)
            for id in ids.values where sessions.first(where: { $0.id == id })?.state?.isWorking == true { worked.insert(id) }
            let settled = ids.values.filter { id in
                guard let state = sessions.first(where: { $0.id == id })?.state else { return false }
                return worked.contains(id) && !state.isWorking
            }
            if settled.count == ids.count { break }
        }
        spin(3)
        for agent in agents {
            guard let id = ids[agent.name] else {
                print("MEASURE trial \(agent.name): not in this trial, or not installed")
                continue
            }
            let info = sessions.first { $0.id == id }
            let own = sessions.filter { $0.openedBy == id }
            print(
                "MEASURE trial \(agent.name) (\(agent.flags.isEmpty ? "as set up" : agent.flags)): worked=\(worked.contains(id)) "
                    + "state=\(info?.state.map { "\($0)" } ?? "none") link=\(info?.link.map { "\($0)" } ?? "none") shells opened=\(own.count)")
        }
    }
}
