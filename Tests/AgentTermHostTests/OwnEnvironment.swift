import Foundation

/// What a program a host test starts is given (TEST-10, #207).
enum OwnEnvironment {
    /// This process's environment with none of AgentTerm's variables: the
    /// tests may be run from a session of the installed app, whose own (its
    /// hooks' file, its MCP server's key) are in it. A host, a stand-in or
    /// an MCP server a test starts gets the `AGENTTERM_` variables the test
    /// gives it, and no other.
    static var withoutAgentTerms: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AGENTTERM_") }
    }
}
