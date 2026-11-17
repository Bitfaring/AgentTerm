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

    public init(hooks: Bool? = nil, mcp: Bool? = nil) {
        self.hooks = hooks
        self.mcp = mcp
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

    /// What to do when either is missing.
    public static let fix = "Settings > Hooks & MCP on the Mac adds them to the agent's own configuration."

    /// An agent typed by hand in a shell, for the icon's help.
    public static func typed(_ name: String) -> String { "\(name), started by hand in this shell." }
}
