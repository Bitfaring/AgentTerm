import Foundation

/// How the host starts a shell (Settings > Shell): which program, and what
/// is run in it first. The host keeps it, so that a shell started from any
/// device, or by an agent, is started the same way. A zsh an agent opens
/// always says when each of its commands ends (`ShellIntegration`), with
/// no switch (decided by the owner on 2026-11-16).
public struct ShellSettings: Codable, Equatable, Sendable {
    /// The program of a new shell; nil for the user's login shell. A
    /// session that runs a command, an agent's above all, is started by the
    /// login shell all the same.
    public var program: String?
    /// Typed into each shell the user opens, with Return, once it shows its
    /// prompt; "" for none.
    public var startup: String
    /// Run in each shell an agent opens before its first prompt; "" for none.
    public var agentStartup: String

    public init(program: String? = nil, startup: String = "", agentStartup: String = "") {
        self.program = program
        self.startup = startup
        self.agentStartup = agentStartup
    }
}
