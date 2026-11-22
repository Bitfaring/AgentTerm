import AgentTermProtocol
import XCTest

@testable import AgentTermTerminal

/// #235: what a terminal does by itself while a program draws in place.
@MainActor
final class LiveOutputTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testAProgramDrawingOnTheOtherScreenDoesNotAskForEarlierLines() {
        let controller = TerminalController(session: 1)
        // A phone's: it opened the session with some of the lines above the
        // screen, and the host keeps more of them.
        controller.historyAsked = 500
        controller.historyKept = 5_000
        var asked: [Int] = []
        controller.onNeedsHistory = { asked.append($0) }
        // An agent on the other screen, each frame in synchronized output,
        // as Claude Code draws.
        controller.feed(Data("\u{1b}[?1049h\u{1b}[H\u{1b}[2J".utf8))
        for frame in 0..<20 {
            controller.feed(Data("\u{1b}[?2026h\u{1b}[?25l\u{1b}[H\r\u{1b}[14B⠋ agent \(frame)\u{1b}[30;1H\u{1b}[?25h\u{1b}[?2026l".utf8))
            spin(0.05)
        }
        spin(0.3)
        XCTAssertEqual(asked, [], "the terminal asked for earlier lines while nobody scrolled")
    }

    /// On the main screen, where there are lines above, a look past the top
    /// still asks for the next page of them (HIST-6), and back from the
    /// other screen it does again.
    func testOnTheMainScreenEarlierLinesAreStillAskedFor() {
        let controller = TerminalController(session: 1)
        controller.historyAsked = 500
        controller.historyKept = 5_000
        var asked: [Int] = []
        controller.onNeedsHistory = { asked.append($0) }
        controller.feed(Data("a line\r\n".utf8))
        spin(0.1)
        controller.loadMoreHistory()
        XCTAssertEqual(asked, [1_500])

        // On the other screen, and back.
        let other = TerminalController(session: 2)
        other.historyAsked = 500
        other.historyKept = 5_000
        var otherAsked: [Int] = []
        other.onNeedsHistory = { otherAsked.append($0) }
        other.feed(Data("\u{1b}[?1049h".utf8))
        spin(0.1)
        other.loadMoreHistory()
        XCTAssertEqual(otherAsked, [], "asked for earlier lines on the other screen")
        other.feed(Data("\u{1b}[?1049l".utf8))
        spin(0.1)
        other.loadMoreHistory()
        XCTAssertEqual(otherAsked, [1_500], "not asked again once back on the main screen")
    }
}
