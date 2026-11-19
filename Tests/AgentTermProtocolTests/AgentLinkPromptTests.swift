import AgentTermProtocol
import XCTest

/// LINK-12 (#172): what AgentTerm's instructions came to in a session, from
/// how they reach its agent.
final class AgentLinkPromptTests: XCTestCase {
    func testHowTheInstructionsReachedASession() {
        // Claude Code and Codex: through the MCP server.
        for agent in ["claude", "codex"] {
            XCTAssertEqual(AgentLink.prompt(agent: agent, given: true, mcp: true), .given)
            XCTAssertEqual(AgentLink.prompt(agent: agent, given: true, mcp: false), .missing)
            XCTAssertNil(AgentLink.prompt(agent: agent, given: true, mcp: nil), "not known while the server is not heard yet")
        }
        // Copilot CLI: the session's environment, whatever its server did.
        XCTAssertEqual(AgentLink.prompt(agent: "copilot", given: true, mcp: false), .given)
        // Antigravity: a rule of its plugin, not seen for one session.
        XCTAssertEqual(AgentLink.prompt(agent: "agy", given: true, mcp: true), .unverified)
        // None saved when it started: disabled, for any agent.
        for agent in ["claude", "codex", "copilot", "agy"] {
            XCTAssertEqual(AgentLink.prompt(agent: agent, given: false, mcp: true), .disabled)
        }
    }
}
