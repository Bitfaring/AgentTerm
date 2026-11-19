import Foundation

/// Whether an agent's session talks to AgentTerm (#129): its hooks, which
/// say what it is doing, and AgentTerm's MCP server, which gives it shells
/// and pages of its own. AgentTerm starts an agent with no arguments of its
/// own: both come from the agent's own configuration, which
/// `agenttermd setup` adds to when the user asks. What is shown is what the
/// host heard, not what is installed.
public struct AgentLink: Codable, Equatable, Sendable {
    /// Its hooks: heard from (true), not heard from in the first seconds
    /// of the agent (false), or not known yet (nil).
    public var hooks: Bool?
    /// AgentTerm's MCP server: it said it started (true), it did not in the
    /// first seconds (false), or not known yet (nil).
    public var mcp: Bool?
    /// AgentTerm's instructions to the agent (#172): how they reached this
    /// session, as the host can tell; nil while not known yet.
    public var prompt: Prompt?

    /// How AgentTerm's instructions reached a session.
    public enum Prompt: String, Codable, Equatable, Sendable {
        /// Given, as far as the host can see: through the MCP server that
        /// said it started (Claude Code, Codex), or through the session's
        /// environment (Copilot CLI).
        case given
        /// Not given: they reach this agent through its MCP server, which
        /// did not start.
        case missing
        /// The user's text for this agent was empty when it started.
        case disabled
        /// Given in a way the host cannot see for one session (Antigravity's
        /// rule), or for an agent typed by hand.
        case unverified
    }

    public init(hooks: Bool? = nil, mcp: Bool? = nil, prompt: Prompt? = nil) {
        self.hooks = hooks
        self.mcp = mcp
        self.prompt = prompt
    }

    /// What the instructions came to, from how they are given to `agent`
    /// and whether there were any (`given`) when it started.
    public static func prompt(agent: String, given: Bool, mcp: Bool?) -> Prompt? {
        guard given else { return .disabled }
        switch agent {
        case "claude", "codex":
            switch mcp {
            case true?: return .given
            case false?: return .missing
            case nil: return nil
            }
        case "copilot": return .given
        default: return .unverified
        }
    }

    /// Both heard from.
    public var isWhole: Bool { hooks == true && mcp == true }
    /// Either known to be missing.
    public var isMissing: Bool { hooks == false || mcp == false }
}

/// What both apps say of an agent's link to AgentTerm, in the same words
/// (principle 9).
public enum AgentLinkWords {
    /// The heading of the pane of Settings, and of the step of the
    /// onboarding, that sets them up.
    public static let title = "Hooks & MCP"

    /// What the icon of a session says, in a word or two.
    public static func summary(_ link: AgentLink) -> String {
        if link.isWhole { return "Hooks and MCP connected" }
        if link.hooks == nil && link.mcp == nil { return "Connecting…" }
        switch (link.hooks, link.mcp) {
        case (false, false): return "No hooks, no MCP"
        case (false, _): return "No hooks"
        case (_, false): return "No MCP"
        default: return "Connecting…"
        }
    }

    /// Its hooks, in a line.
    public static func hooks(_ heard: Bool?) -> String {
        switch heard {
        case true?: return "Hooks: heard. Its state, the Inbox and notifications work."
        case false?: return "Hooks: not heard. Its state is not shown, it does not come to the Inbox, and no notification is made."
        case nil: return "Hooks: not heard yet."
        }
    }

    /// Its MCP server, in a line.
    public static func mcp(_ connected: Bool?) -> String {
        switch connected {
        case true?: return "MCP server: connected. It can open shells and pages of its own."
        case false?: return "MCP server: not connected. It cannot open shells and pages of its own."
        case nil: return "MCP server: not connected yet."
        }
    }

    /// The rows of the mark's popover (#172), each a word or two.
    public static let hooksRow = "Hooks"
    public static let mcpRow = "MCP"
    public static let promptRow = "System Prompt"
    public static let checking = "Checking…"

    public static func hooksStatus(_ heard: Bool?) -> String {
        switch heard {
        case true?: return "Heard"
        case false?: return "Not heard"
        case nil: return checking
        }
    }

    public static func mcpStatus(_ connected: Bool?) -> String {
        switch connected {
        case true?: return "Connected"
        case false?: return "Not connected"
        case nil: return checking
        }
    }

    public static func promptStatus(_ prompt: AgentLink.Prompt?) -> String {
        switch prompt {
        case .given?: return "Given"
        case .missing?: return "Not given"
        case .disabled?: return "Disabled"
        case .unverified?: return "Unverified"
        case nil: return checking
        }
    }

    /// Why, under the row.
    public static func promptDetail(_ prompt: AgentLink.Prompt?) -> String {
        switch prompt {
        case .given?: return "AgentTerm's instructions reached this session."
        case .missing?: return "They come through the MCP server, which did not start."
        case .disabled?: return "Settings > Agents held no instructions for this agent when it started."
        case .unverified?: return "Given in a way AgentTerm cannot see for one session."
        case nil: return "Waiting for the session to start."
        }
    }

    /// What to do when either is missing.
    public static let fix = "Settings > Hooks & MCP on the Mac adds them to the agent's own configuration."

    /// An agent typed by hand in a shell, for the icon's help.
    public static func typed(_ name: String) -> String { "\(name), started by hand in this shell." }
}
