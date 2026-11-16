import AgentTermProtocol
import XCTest

/// Settings > Agents: what each agent is told (PROMPT-4 in docs/TESTING.md).
final class AgentPromptsUITests: MacUITestCase {
    /// PROMPT-4: the user's words for an agent are saved by the host, told
    /// to every device, and given back as the default by Reset to Default.
    func testTheUserWritesWhatAnAgentIsTold() throws {
        let phone = try device()
        app.press(.id("place-settings"))
        app.press(.id("settings-agents"))
        app.wait(for: .id("prompt-text"))
        app.wait(for: .text("AgentTerm's default"))
        let words = "Use AgentTerm's browser for every web page."
        app.write(words, into: .id("prompt-text"))
        app.wait(for: .text("Edited, not saved"))
        app.press(.id("prompt-save"))
        wait("the host to have them") {
            phone.last { if case .agentPrompts(let custom, _) = $0 { return custom } else { return nil } }?["claude"] == words
        }
        app.wait(for: .text("Your words"))
        shot("written")

        app.press(.id("prompt-reset"))
        wait("back to the default") {
            phone.last { if case .agentPrompts(let custom, _) = $0 { return custom } else { return nil } }?["claude"] == nil
        }
        app.wait(for: .text("AgentTerm's default"))
    }
}
