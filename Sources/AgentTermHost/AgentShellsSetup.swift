#if os(macOS)
import AgentTermProtocol
import Foundation

/// AgentTerm's MCP server (`agenttermd mcp`, #10) as the agents' sessions
/// are given it, and what earlier builds left of it in the agents' own
/// configuration.
///
/// Each session's agent is given the server on its command line, for that
/// session only (`AgentHooks.launchArguments`), as it is given its hooks,
/// and as they are without a switch: nothing is written into an agent's own
/// configuration, and an agent started outside AgentTerm, where the server
/// has nothing to offer, does not get it.
///
/// Builds before 0.8.0 installed the server in each agent's configuration,
/// for the whole user, with `<agent> mcp add`, and kept what they installed
/// in the state folder (`agent-shells.json`). That, and only that, is taken
/// out with the agent's own `<agent> mcp remove`, once for each agent:
/// whether it took it out or refused, it is then forgotten, and one that
/// refused is said, with how to take it out by hand.
///
/// A released build and a development build each have a name of their own
/// for the server (`AppChannel.mcpServerName`, #57), and each takes out
/// only what it put in under its own.
public final class AgentShellsSetup {
    /// The name servers had before each build had its own.
    static let formerName = "agentterm"

    /// The name the server has in each agent's session.
    public let name: String
    /// The host's program, which the server runs as `<tool> mcp`.
    public let tool: String

    /// Runs an agent's command line and says whether it worked.
    public typealias Run = (_ arguments: [String]) -> Bool

    private struct Record: Codable, Equatable {
        /// The agents an earlier build installed it in, with the program it
        /// named: what is left to take out.
        var installed: [String: String] = [:]
        /// The name they were installed under; nil for one from before each
        /// build had its own (`formerName`).
        var name: String?
    }

    private let file: URL
    private let run: Run

    /// - Parameters:
    ///   - directory: The host's state folder.
    ///   - tool: The host's program.
    ///   - name: The server's name; this build's unless a test's.
    ///   - run: Runs an agent's command line; through the user's login shell
    ///     unless a test stands in for it.
    public init(directory: URL, tool: String, name: String = AppChannel.current.mcpServerName, run: Run? = nil) {
        file = directory.appendingPathComponent("agent-shells.json")
        self.tool = tool
        self.name = name
        self.run = run ?? AgentShellsSetup.throughLoginShell
    }

    /// What a session's agent is given.
    public var server: AgentHooks.Server { AgentHooks.Server(name: name, tool: tool) }

    /// Takes the server out of every agent an earlier build installed it
    /// in, with the agent's own command, once: each is forgotten after,
    /// whether it took it out or not. An agent that is not installed now is
    /// left for when it is. Blocks while the agents run.
    ///
    /// - Returns: The agents that refused, and still have it.
    @discardableResult
    public func removeLeftovers(agents: [AgentInfo]) -> [AgentInfo] {
        guard let data = FileManager.default.contents(atPath: file.path), var record = try? JSONDecoder().decode(Record.self, from: data) else { return [] }
        // What a build from before installed under the name every build
        // shared is not this build's: it is left where it is, for the build
        // that has that name.
        guard (record.name ?? Self.formerName) == name, !record.installed.isEmpty else { return [] }
        var refused: [AgentInfo] = []
        for agent in agents where record.installed[agent.id] != nil {
            guard let path = agent.path else { continue }
            if !run(Self.remove(agent: agent.id, path: path, name: name)) { refused.append(agent) }
            record.installed[agent.id] = nil
        }
        if record.installed.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            record.name = name
            try? JSONEncoder().encode(record).write(to: file, options: .atomic)
        }
        return refused
    }

    /// `<agent> mcp remove`, as each agent takes it.
    static func remove(agent: String, path: String, name: String) -> [String] {
        agent == "claude" ? [path, "mcp", "remove", "--scope", "user", name] : [path, "mcp", "remove", name]
    }

    /// As in a terminal: the agents find their sign-in and their PATH there.
    private static func throughLoginShell(_ arguments: [String]) -> Bool {
        let line = arguments.map(Handoff.shellQuote).joined(separator: " ")
        guard let result = Subprocess.run(HostEnvironment.shell, ["-l", "-i", "-c", line], cwd: HostEnvironment.homeDirectory, timeout: 30) else {
            return false
        }
        return result.status == 0
    }
}
#endif
