import AgentTermProtocol
import AppKit
import XCTest

@testable import AgentTermTerminal

/// What the review of 2026-11-22 found in the terminal and the split diff
/// (#293, #295).
@MainActor
final class ReviewTerminalTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// #293: what the user types while the screen is being replayed reaches
    /// the program: only the emulator's answers to the replay are kept back.
    func testWhatIsTypedDuringAReplayReachesTheProgram() {
        let controller = TerminalController(session: 1)
        var sent = Data()
        controller.onInput = { sent.append($0) }
        controller.replayQuiet = 5
        controller.beginReplay(size: TermSize(cols: 80, rows: 24))
        controller.feed(Data("what was on the screen\r\n".utf8))
        spin(0.1)
        // A key, as the terminal view hands it over when the user types.
        controller.send(source: controller.view, data: ArraySlice(Array("ls\r".utf8)))
        controller.endReplay()
        spin(0.3)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "ls\r", "what was typed during the replay did not reach the program")
    }

    /// #295: what is copied from the split diff is the file's own: a tab of
    /// the file is a tab in the text.
    func testATabOfTheFileIsATabInTheSplitDiff() {
        let (advance, lineHeight) = SplitDiffTexts.metrics(11.5)
        let texts = SplitDiffTexts(patch: "@@ -1,2 +1,2 @@\n all:\n-\tgo build\n+\tgo test", fontSize: 11.5, advance: advance, lineHeight: lineHeight)
        let left = texts.left.string.components(separatedBy: "\n")
        let right = texts.right.string.components(separatedBy: "\n")
        XCTAssertTrue(left.contains("\tgo build"), "the left side has \(left.map(\.debugDescription))")
        XCTAssertTrue(right.contains("\tgo test"), "the right side has \(right.map(\.debugDescription))")
    }

    /// #296: a limit said to start over at a date out of range is shown,
    /// not a stop.
    func testAResetDateOutOfRangeDoesNotStopTheProcess() {
        XCTAssertFalse(UsageStyle.shortReset(Date(timeIntervalSince1970: 1e300), now: Date(timeIntervalSince1970: 0)).isEmpty)
        XCTAssertEqual(UsageStyle.shortReset(Date(timeIntervalSince1970: -1e300), now: Date(timeIntervalSince1970: 0)), "now")
    }
}
