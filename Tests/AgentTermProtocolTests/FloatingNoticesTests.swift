import AgentTermProtocol
import XCTest

/// The agents' notices floating over the window's content (#225).
final class FloatingNoticesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let asks = AgentState.waitingForAnswer(AgentQuestion(text: "Which?"))
    private let permission = AgentState.waitingForPermission(AgentQuestion(text: "make deploy"))

    private func notice(_ session: SessionID, _ state: AgentState = .done(said: "ok")) -> AgentNotice {
        AgentNotice(session: session, name: "s\(session)", folder: "/tmp", state: state)
    }

    private func after(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// NOTE-16: a notice of an agent that is done goes after 10 seconds;
    /// one of an agent that waits stays.
    func testADoneNoticeGoesAfterItsTimeAndOneThatWaitsStays() {
        XCTAssertEqual(FloatingNotices.stays, 10)
        var notices = FloatingNotices()
        notices.show(notice(1), id: 1, at: now)
        notices.show(notice(2, asks), id: 2, at: now)
        notices.show(notice(3, permission), id: 3, at: now)
        XCTAssertEqual(notices.shown.map(\.id), [3, 2, 1], "the newest is on top")
        XCTAssertEqual(notices.nextGoes, after(10))
        XCTAssertEqual(notices.expire(at: after(9.9)), [])
        XCTAssertEqual(notices.shown.count, 3)
        XCTAssertEqual(notices.expire(at: after(10)), [1])
        XCTAssertEqual(notices.shown.map(\.id), [3, 2])
        XCTAssertNil(notices.nextGoes, "what waits never goes by itself")
        XCTAssertEqual(notices.expire(at: after(3600)), [])
        XCTAssertEqual(notices.shown.map(\.id), [3, 2])
    }

    /// NOTE-16: each done notice has its own time, from when it was told.
    func testEachNoticeGoesAtItsOwnTime() {
        var notices = FloatingNotices()
        notices.show(notice(1), id: 1, at: now)
        notices.show(notice(2), id: 2, at: after(4))
        XCTAssertEqual(notices.nextGoes, after(10))
        XCTAssertEqual(notices.expire(at: after(10)), [1])
        XCTAssertEqual(notices.nextGoes, after(14))
        XCTAssertEqual(notices.expire(at: after(14)), [2])
        XCTAssertTrue(notices.isEmpty)
    }

    /// NOTE-16: the time a test asks for, and 10 seconds for anything that
    /// is not a time.
    func testTheTimeCanBeShortenedByTheEnvironment() {
        XCTAssertEqual(FloatingNotices.stays(in: [:]), 10)
        XCTAssertEqual(FloatingNotices.stays(in: [FloatingNotices.staysVariable: "2.5"]), 2.5)
        XCTAssertEqual(FloatingNotices.stays(in: [FloatingNotices.staysVariable: "soon"]), 10)
        XCTAssertEqual(FloatingNotices.stays(in: [FloatingNotices.staysVariable: "0"]), 10)
        XCTAssertEqual(FloatingNotices.stays(in: [FloatingNotices.staysVariable: "-3"]), 10)
        var notices = FloatingNotices(stays: 3)
        notices.show(notice(1), id: 1, at: now)
        XCTAssertEqual(notices.nextGoes, after(3))
    }

    /// NOTE-16: a notice does not go while the pointer is over it, and its
    /// time starts again when the pointer leaves.
    func testANoticeUnderThePointerDoesNotGo() {
        var notices = FloatingNotices()
        notices.show(notice(1), id: 1, at: now)
        notices.show(notice(2), id: 2, at: now)
        notices.hover(1, true, at: after(8))
        XCTAssertEqual(notices.expire(at: after(60)), [2], "only the one the pointer is not over goes")
        XCTAssertEqual(notices.shown.map(\.id), [1])
        XCTAssertNil(notices.nextGoes)
        notices.hover(1, false, at: after(60))
        XCTAssertEqual(notices.nextGoes, after(70), "the whole time again once the pointer left")
        XCTAssertEqual(notices.expire(at: after(69)), [])
        XCTAssertEqual(notices.expire(at: after(70)), [1])

        // One that waits stays after the pointer left, as before it came.
        notices.show(notice(3, asks), id: 3, at: now)
        notices.hover(3, true, at: now)
        notices.hover(3, false, at: after(1))
        XCTAssertNil(notices.nextGoes)
        // A notice that is not there is not hovered.
        notices.hover(99, true, at: now)
        XCTAssertEqual(notices.shown.map(\.id), [3])
    }

    /// NOTE-17: ten at most, the newest on top; an eleventh takes the place
    /// of the oldest that does not wait.
    func testAnEleventhTakesThePlaceOfTheOldestThatDoesNotWait() {
        var notices = FloatingNotices()
        // The oldest waits, the next two are done, the others wait.
        notices.show(notice(1, asks), id: 1, at: now)
        notices.show(notice(2), id: 2, at: now)
        notices.show(notice(3), id: 3, at: now)
        for id in 4...10 { notices.show(notice(SessionID(id), permission), id: UInt64(id), at: now) }
        XCTAssertEqual(notices.shown.count, FloatingNotices.most)
        XCTAssertEqual(notices.shown.map(\.id), [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])

        notices.show(notice(11), id: 11, at: now)
        XCTAssertEqual(notices.shown.map(\.id), [11, 10, 9, 8, 7, 6, 5, 4, 3, 1], "the oldest done one goes, not the older one that waits")
        notices.show(notice(12, asks), id: 12, at: now)
        XCTAssertEqual(notices.shown.map(\.id), [12, 11, 10, 9, 8, 7, 6, 5, 4, 1], "then the next done one")
        XCTAssertEqual(notices.shown.count, FloatingNotices.most)
    }

    /// NOTE-17: when all ten wait, the oldest goes from the stack.
    func testWhenAllTenWaitTheOldestGoes() {
        var notices = FloatingNotices()
        for id in 1...10 { notices.show(notice(SessionID(id), asks), id: UInt64(id), at: now) }
        notices.show(notice(11), id: 11, at: now)
        XCTAssertEqual(notices.shown.map(\.id), [11, 10, 9, 8, 7, 6, 5, 4, 3, 2])
        // The one just told is done, and the only one that goes by itself.
        XCTAssertEqual(notices.expire(at: after(10)), [11])
        XCTAssertEqual(notices.shown.count, 9)
    }

    /// NOTE-17: the same notice told again takes its own place, with the
    /// time it had; another of the same session takes that session's place,
    /// on top.
    func testTheSameNoticeToldAgainIsNotStackedTwice() {
        var notices = FloatingNotices()
        notices.show(notice(1), id: 1, at: now)
        notices.show(notice(2), id: 2, at: after(1))
        notices.show(notice(1), id: 1, at: after(5))
        XCTAssertEqual(notices.shown.map(\.id), [2, 1], "told again, it stays where it was")
        XCTAssertEqual(notices.shown.last?.goes, after(10), "and goes when it was to go")

        // The session's agent asks something after it was done: one card.
        notices.show(notice(1, asks), id: 3, at: after(6))
        XCTAssertEqual(notices.shown.map(\.id), [3, 2])
        XCTAssertNil(notices.shown.first?.goes)
        // The same number, now done: it goes by itself from then.
        notices.show(notice(1), id: 3, at: after(7))
        XCTAssertEqual(notices.shown.first?.goes, after(17))
        // And waiting again: it stays.
        notices.show(notice(1, permission), id: 3, at: after(8))
        XCTAssertNil(notices.shown.first?.goes)
        XCTAssertEqual(notices.shown.count, 2)
    }

    /// NOTE-17: a notice handled or read on another device goes; so does
    /// one whose session is opened, or whose agent moved on.
    func testANoticeHandledElsewhereGoes() {
        var notices = FloatingNotices()
        notices.show(notice(1, asks), id: 1, at: now)
        notices.show(notice(2), id: 2, at: now)
        notices.show(notice(3, permission), id: 3, at: now)
        notices.show(notice(4), id: 4, at: now)
        notices.remove(ids: [1, 99])
        XCTAssertEqual(notices.shown.map(\.id), [4, 3, 2])
        notices.remove(session: 2)
        XCTAssertEqual(notices.shown.map(\.id), [4, 3])
        // The host's sessions now: the third works again, the fourth is as it was.
        let states: [SessionID: AgentState] = [3: .working(since: now), 4: .done(said: "ok")]
        notices.keep { states[$0.session] == $0.state }
        XCTAssertEqual(notices.shown.map(\.id), [4])
    }
}
