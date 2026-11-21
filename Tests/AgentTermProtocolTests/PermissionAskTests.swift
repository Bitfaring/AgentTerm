import XCTest

@testable import AgentTermProtocol

/// NOTIFY-3 (#200): whoever asks whether the iPhone may notify while iOS's
/// question is open waits for its answer, rather than read the settings,
/// which say "not determined" until then. The iPhone's
/// `AgentNotifications.askOnce` goes by `PermissionAsk`.
final class PermissionAskTests: XCTestCase {
    func testWhoAsksWhileTheQuestionIsOpenIsToldItsAnswer() {
        var ask = PermissionAsk<String>()
        // Pairing asks, and registering for pushes right after.
        XCTAssertEqual(ask.ask("pairing", switchedOn: true), .request)
        XCTAssertEqual(ask.ask("push", switchedOn: true), .wait, "a second caller does not read the settings while the question is open")
        XCTAssertEqual(ask.ask("post", switchedOn: true), .wait)
        // Allowed: everyone that asked is told so, the first first.
        XCTAssertEqual(ask.answered(), ["pairing", "push", "post"])
        // Answered: the settings say it from now on.
        XCTAssertEqual(ask.ask("later", switchedOn: true), .readSettings)
        XCTAssertEqual(ask.answered(), [], "nobody is told twice")
    }

    func testNobodyHasTheSystemAskedWhileTheSwitchIsOff() {
        var ask = PermissionAsk<String>()
        XCTAssertEqual(ask.ask("pairing", switchedOn: false), .refuse)
        XCTAssertEqual(ask.answered(), [], "a caller told no is not kept")
        // Turned on: the system is asked then.
        XCTAssertEqual(ask.ask("switch", switchedOn: true), .request)
        // Turned off while the question is open: told no at once.
        XCTAssertEqual(ask.ask("post", switchedOn: false), .refuse)
        XCTAssertEqual(ask.answered(), ["switch"])
    }
}
