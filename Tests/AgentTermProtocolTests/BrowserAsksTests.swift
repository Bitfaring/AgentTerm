import XCTest

@testable import AgentTermProtocol

/// REMOTE-26 (#198): what the iPhone asked of the Mac's browser and still
/// waits for is answered at once, refused in the Mac's words, when the
/// connection to that Mac closes or is left for another, and nothing is
/// kept. The iPhone's `PhoneModel` goes by `BrowserAsks`.
final class BrowserAsksTests: XCTestCase {
    func testWhatWaitsIsRefusedInTheMacsWordsWhenTheConnectionCloses() {
        var asks = BrowserAsks<String>()
        let picture = asks.add("picture")
        let tap = asks.add("tap")
        XCTAssertNotEqual(picture, tap)
        XCTAssertEqual(asks.count, 2)
        let closed = asks.closed(mac: "Studio")
        XCTAssertEqual(closed?.why, BrowserWords.otherMacClosed("Studio"), "the same words as the Mac's (#196)")
        XCTAssertEqual(closed?.waiting ?? [], ["picture", "tap"], "each is answered, the first asked first")
        XCTAssertEqual(asks.count, 0, "nothing is kept")
        // Answered once: not again, nor by an answer that comes late.
        XCTAssertNil(asks.closed(mac: "Studio"))
        XCTAssertNil(asks.answered(picture))
    }

    func testAnAnswerGoesToItsAskOnce() {
        var asks = BrowserAsks<String>()
        let picture = asks.add("picture")
        let tap = asks.add("tap")
        XCTAssertEqual(asks.answered(tap), "tap")
        XCTAssertNil(asks.answered(tap), "answered once")
        XCTAssertEqual(asks.closed(mac: "Studio")?.waiting ?? [], ["picture"])
        // The ids go on: an answer to an ask of the connection before
        // answers nothing of the next one.
        let next = asks.add("profiles")
        XCTAssertNotEqual(next, picture)
        XCTAssertNil(asks.answered(picture))
        XCTAssertEqual(asks.answered(next), "profiles")
    }
}
