import AgentTermProtocol
import XCTest

/// HAND-10 (#307): the words both apps say when a conversation cannot be
/// handed off are written once, here; both apps show these.
final class HandoffWordsTests: XCTestCase {
    func testTheWordsOfAHandoffThatCannotBeDone() {
        XCTAssertEqual(
            HandoffWords.noConversation("Claude Code"), "Claude Code has no conversation to hand off in this session yet. It saves one after your first message.")
        XCTAssertEqual(HandoffWords.noOtherAgent, "No other agent is installed to hand this off to.")
    }
}
