import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// #249 (review of 2026-11-22), the part in the agent's MCP server: a number
/// an agent gives a browser tool. One out of range or that is no number is
/// refused in words; it never stops the server nor makes a request that
/// cannot be sent.
final class ReviewCoreBrowserNumbersTests: XCTestCase {
    /// "inf" and "nan" are read as numbers (`Double("inf")`); JSON cannot
    /// carry them, so the message to the host is encoded as nothing.
    func testANumberThatIsNotOneIsRefusedInWords() throws {
        for (tool, arguments) in [
            ("browser_scroll", ["tab": "1", "y": "inf"] as [String: Any]),
            ("browser_wait", ["tab": "1", "text": "x", "seconds": "nan"]),
        ] {
            switch AgentShellsMCP.browserRequest(tool, arguments) {
            case .failure: break
            case .success(let request):
                let sent = MessageCoding.encode(ClientMessage.agentBrowser(id: 1, key: "k", request: request))
                XCTFail("\(tool) with \(arguments) was not refused; the message it makes for the host is \(sent.count) bytes long")
            }
        }
    }

    /// `browser_emulate` with a width no screen has. Run in a process of
    /// its own: `Int(width)` stops the process it runs in.
    func testAWidthOutOfRangeDoesNotStopTheServer() throws {
        let run = try ReviewCore.runAlone("testEmulatingAWidthOutOfRange", in: ReviewCoreTrapCases.self)
        XCTAssertFalse(run.crashed, "the process that made the request was stopped (signal \(run.status)):\n\(ReviewCore.crashLines(run.said))")
        XCTAssertEqual(run.status, 0, ReviewCore.crashLines(run.said))
    }

    /// A number in range is taken; one past it is refused, naming the range.
    func testANumberInRangeIsTakenAndOnePastItRefused() throws {
        guard case .success = AgentShellsMCP.browserRequest("browser_scroll", ["tab": "1", "y": 900]) else { return XCTFail("a scroll of 900 refused") }
        guard case .success = AgentShellsMCP.browserRequest("browser_emulate", ["tab": "1", "width": 390, "height": 844]) else {
            return XCTFail("a phone's size refused")
        }
        guard case .failure(let error) = AgentShellsMCP.browserRequest("browser_emulate", ["tab": "1", "width": 1e30, "height": 844]) else {
            return XCTFail("a width of 1e30 taken")
        }
        XCTAssertEqual(error.text, "`width` is a number from 1 to 10000.")
    }
}
