import Foundation

/// How the host starts a shell (Settings > Shell): which program, what is
/// run in it first, and whether a shell an agent opens says when each of
/// its commands ends. The host keeps it, so that a shell started from any
/// device, or by an agent, is started the same way.
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
    /// A shell an agent opens says when each of its commands starts and
    /// ends, with its exit code (OSC 133), for `shell_run`. On unless
    /// turned off.
    public var marks: Bool

    public init(program: String? = nil, startup: String = "", agentStartup: String = "", marks: Bool = true) {
        self.program = program
        self.startup = startup
        self.agentStartup = agentStartup
        self.marks = marks
    }
}
