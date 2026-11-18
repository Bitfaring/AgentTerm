import Foundation

/// One command that adds a part of what AgentTerm needs of an agent, or
/// takes it out, as typed in a terminal, with what it is for. The agent's
/// own command when the agent has one for that part (`claude mcp add …`),
/// AgentTerm's (`agenttermd setup claude`) for what it has none for.
public struct AgentSetupStep: Codable, Equatable, Sendable {
    /// What it adds or takes out, and whose command it is, in a line.
    public var title: String
    public var command: String

    public init(title: String, command: String) {
        self.title = title
        self.command = command
    }
}

/// What an agent has of AgentTerm's in its own configuration (#129), as the
/// agent itself says it: AgentTerm's MCP server, its hooks, and for Claude
/// Code the status line AgentTerm reads its usage from; with the commands
/// that add them and take them out. Each build has its own
/// (`AppChannel.mcpServerName`).
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
    /// The background server Codex's sessions share is out of the way
    /// (#140): not started by Codex itself, and not running. While it runs,
    /// a session's hooks and server are that server's and no session's;
    /// nil for an agent that has none.
    public var sharedServerOff: Bool?
    /// The commands that add what AgentTerm needs of it, in the order they
    /// are run, and those that take it out: what Install and Remove run.
    /// The agent's own first, AgentTerm's for what the agent has no command
    /// for (decided by the owner on 2026-11-18).
    public var steps: [AgentSetupStep]
    public var removeSteps: [AgentSetupStep]
    /// What else the user should know of it, when there is something.
    public var note: String?
    /// What is in the way of its setup now, or why the last setup or
    /// removal did not work, with the agent's own words.
    public var problem: String?

    public var id: String { agent }

    public init(
        agent: String, name: String, installed: Bool, hooks: Bool? = nil, mcp: Bool? = nil, statusLine: Bool? = nil, sharedServerOff: Bool? = nil,
        steps: [AgentSetupStep] = [], removeSteps: [AgentSetupStep] = [], note: String? = nil, problem: String? = nil
    ) {
        self.agent = agent
        self.name = name
        self.installed = installed
        self.hooks = hooks
        self.mcp = mcp
        self.statusLine = statusLine
        self.sharedServerOff = sharedServerOff
        self.steps = steps
        self.removeSteps = removeSteps
        self.note = note
        self.problem = problem
    }

    /// Everything of AgentTerm's is there, and nothing is in its way.
    public var isSetUp: Bool { hooks == true && mcp == true && statusLine != false && sharedServerOff != false }
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
        "AgentTerm starts an agent as you would, with nothing added. What it needs of each agent is in the agent's own configuration: AgentTerm's MCP server, which gives it shells and pages you see, and its hooks, which tell AgentTerm what the agent is doing (its state, the Inbox, notifications). Install adds them for all your folders: the server with the agent's own command, the hooks with AgentTerm's, as no agent has a command for them. Remove takes them out. Outside AgentTerm they do nothing."
    public static let install = "Install"
    public static let remove = "Remove"
    public static let installAll = "Install for All"
    public static let notInstalled = "Not installed on this Mac."
    public static let working = "Working…"
    public static let commandHeading = "Or run in a terminal:"
    public static let removeHeading = "To take them out:"

    /// Over the agent's own command for the server.
    public static func serverStep(_ name: String) -> String { "The MCP server, with \(name)'s own command:" }

    /// Over Codex's own command that turns its shared server off, or on
    /// again.
    public static func sharedServerStep(_ name: String, on: Bool = false) -> String {
        on ? "Its shared server on again, with \(name)'s own command:" : "Its shared server off, with \(name)'s own command:"
    }

    /// Over AgentTerm's command, which is for what the agent has no
    /// command for: what that is, for each agent.
    public static func ownStep(agent: String, name: String) -> String {
        switch agent {
        case "claude": return "Its hooks and the status line, which \(name) has no command for:"
        case "codex": return "Its hooks, and the session's variable for the server, which \(name) has no command for:"
        case "agy": return "Its hooks and what it is told, which \(name) has no command for:"
        default: return "Its hooks, which \(name) has no command for:"
        }
    }

    /// Codex has the server, added with its own command, and gives it
    /// nothing of the session: what to do.
    public static let codexVariableMissing =
        "Codex has AgentTerm's MCP server and gives it nothing of its session: `codex mcp add` has no option for the variable the server knows its session by. Install, or AgentTerm's own command (`agenttermd setup codex`), names it."
    public static let statusLine = "Status line"
    public static let hooks = "Hooks"
    public static let mcp = "MCP server"

    /// The background server Codex's sessions share, as a part of its
    /// setup: out of the way, in it, or not known.
    public static func sharedServer(off: Bool?) -> String {
        switch off {
        case true?: return "Shared server off"
        case false?: return "Shared server on"
        case nil: return "Shared server"
        }
    }

    /// What Install does about it, with which of Codex's own commands, and
    /// for what: the setting is Codex's, outside AgentTerm too.
    public static let sharedServerNote =
        "Codex runs its sessions through one background server they share, where AgentTerm cannot tell one session from another. Install turns that off for all of Codex, with `codex features disable daemon_auto_start`; Remove turns it on again."

    /// Turned off, and still running: what to do.
    public static let sharedServerRunning =
        "Codex's shared background server is still running, and Codex goes on using it. Quit Codex's sessions, then stop it: `codex app-server daemon stop`."
}
