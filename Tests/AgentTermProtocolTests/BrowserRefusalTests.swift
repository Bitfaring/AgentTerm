import AgentTermProtocol
import XCTest

/// REMOTE-32 (#210): what the other Mac's browser refused a watch or an
/// unwatch this Mac sent by itself, because that Mac's app is not
/// connected, is not said in an alert (the owner's decision, 2026-11-21);
/// a watch the user asked for, and every other refusal, still is.
final class BrowserRefusalTests: XCTestCase {
    private let watch = BrowserRequest.watch(tab: "7", on: true, width: 1600)
    private let unwatch = BrowserRequest.watch(tab: "7", on: false, width: 0)

    func testAWatchOrUnwatchSentByItselfIsNotSaidWhenTheOtherMacsAppIsAway() {
        XCTAssertFalse(BrowserRefusal.isSaid(BrowserWords.noApp, of: watch, byItself: true), "a watch sent by itself at a reconnect is refused in an alert")
        XCTAssertFalse(BrowserRefusal.isSaid(BrowserWords.noApp, of: unwatch, byItself: true), "an unwatch sent by itself is refused in an alert")
    }

    func testAWatchTheUserAskedForIsStillRefusedOutLoud() {
        XCTAssertTrue(BrowserRefusal.isSaid(BrowserWords.noApp, of: watch, byItself: false))
    }

    func testEveryOtherRefusalIsStillSaid() {
        XCTAssertTrue(BrowserRefusal.isSaid("No such tab.", of: watch, byItself: true), "only the app being away is left unsaid")
        XCTAssertTrue(BrowserRefusal.isSaid(BrowserWords.noApp, of: .tap(tab: "7", x: 1, y: 1), byItself: true), "only a watch or an unwatch")
    }
}
