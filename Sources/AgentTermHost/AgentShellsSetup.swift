#if os(macOS)
import AgentTermProtocol
import Foundation

/// AgentTerm's MCP server (`agenttermd mcp`, #10): its name, this build's
/// (`AppChannel.mcpServerName`, #57), and the host's program, which runs it.
/// The agents get it from their own configuration, which `agenttermd setup`
/// adds to when the user asks (`AgentSetup`, #129); AgentTerm puts nothing
/// there, and takes nothing out, by itself. What builds before 0.8.0 left
/// there is not taken out any more (principle 6).
public final class AgentShellsSetup {
    /// The name the server has in each agent's configuration.
    public let name: String
    /// The host's program, which the server runs as `<tool> mcp`.
    public let tool: String

    public init(directory: URL, tool: String, name: String = AppChannel.current.mcpServerName) {
        self.tool = tool
        self.name = name
    }
}
#endif
