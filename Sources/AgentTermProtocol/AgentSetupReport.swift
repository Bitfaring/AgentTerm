import Foundation

/// What `agenttermd setup` added of AgentTerm's to an agent's own
/// configuration (#129), as the agent itself says it: its hooks, AgentTerm's
/// MCP server, and for Claude Code the status line AgentTerm reads its usage
/// from. Each build has its own (`AppChannel.mcpServerName`).
public struct AgentSetupState: Codable, Equatable, Identifiable, Sendable {
    /// "claude", "codex", "copilot" or "agy".
    public var agent: String
    /// As the user knows it: "Claude Code".
    public var name: String
    /// Its command was found on the Mac.
    public var installed: Bool
    /// What it has of AgentTerm's; nil when that is not known: it is not
    /// installed, or it could not be asked.
    public var hooks: Bool?
    public var mcp: Bool?
    /// Claude Code's status line; nil for an agent that has none.
    public var statusLine: Bool?
    /// The commands to add them and to take them out, as typed in a
    /// terminal: the host's program, by its full path.
    public var command: String
    public var removeCommand: String
    /// What else the user should know of it, when there is something.
    public var note: String?
    /// Why the last setup or removal did not work, with the agent's own words.
    public var problem: String?

    public var id: String { agent }

    public init(
        agent: String, name: String, installed: Bool, hooks: Bool? = nil, mcp: Bool? = nil, statusLine: Bool? = nil, command: String,
        removeCommand: String, note: String? = nil, problem: String? = nil
    ) {
        self.agent = agent
        self.name = name
        self.installed = installed
        self.hooks = hooks
        self.mcp = mcp
        self.statusLine = statusLine
        self.command = command
        self.removeCommand = removeCommand
        self.note = note
        self.problem = problem
    }

    /// Everything of AgentTerm's is there.
    public var isSetUp: Bool { hooks == true && mcp == true && statusLine != false }
    /// Installed, and missing something of AgentTerm's.
    public var needsSetup: Bool { installed && !isSetUp }
}

/// The agents' setup as the host found it.
public struct AgentSetupReport: Codable, Equatable, Sendable {
    public var agents: [AgentSetupState]
    /// The agents being set up or taken out now.
    public var busy: [String]

    public init(agents: [AgentSetupState], busy: [String] = []) {
        self.agents = agents
        self.busy = busy
    }

    /// An installed agent misses something of AgentTerm's.
    public var needsSetup: Bool { agents.contains { $0.needsSetup } }
}

/// What the pane and the onboarding say of the setup, in the same words
/// (principle 9).
public enum AgentSetupWords {
    public static let explanation =
        "AgentTerm starts an agent as you would, with nothing added. What it needs of each agent is in the agent's own configuration: its hooks, which tell AgentTerm what the agent is doing (its state, the Inbox, notifications), and AgentTerm's MCP server, which gives it shells and pages you see. Install adds them for all your folders, with the agent's own commands; Remove takes them out. Outside AgentTerm they do nothing."
    public static let install = "Install"
    public static let remove = "Remove"
    public static let installAll = "Install for All"
    public static let notInstalled = "Not installed on this Mac."
    public static let working = "Working…"
    public static let commandHeading = "Or run in a terminal:"
    public static let statusLine = "Status line"
    public static let hooks = "Hooks"
    public static let mcp = "MCP server"
}
