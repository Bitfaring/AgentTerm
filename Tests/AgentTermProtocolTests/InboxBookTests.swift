import AgentTermProtocol
import XCTest

/// A device's own Inbox (#66, decided 2026-11-19).
final class InboxBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let asked = AgentState.waitingForAnswer(AgentQuestion(text: "Which?"))

    private func notice(_ id: UInt64, _ state: AgentState, ago: TimeInterval = 0, handled: Notice.Handled.How? = nil) -> Notice {
        Notice(
            id: id, at: now.addingTimeInterval(-ago), session: SessionID(id), name: "s\(id)", folder: "/tmp", kind: .agent(state),
            handled: handled.map { Notice.Handled(at: now, how: $0) })
    }

    /// INBOX-12: the Inbox shows all of what an agent said, on both apps (the
    /// owner's report, 2026-11-21: its messages were cut). A notification
    /// keeps the end only; a question's choices come with it.
    func testTheInboxHasAllOfWhatWasSaid() {
        let long = String(repeating: "word ", count: 200) + "the point."
        let done = notice(1, .done(said: long))
        XCTAssertEqual(done.fullBody, long.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertLessThanOrEqual(done.body.count, AgentNotice.detailLength)
        XCTAssertTrue(done.body.hasSuffix("the point."))
        let question = notice(2, .waitingForAnswer(AgentQuestion(text: "Red or blue?", choices: ["Red", "Blue"])))
        XCTAssertTrue(question.fullBody.contains("Red or blue?") && question.fullBody.contains("Blue"), question.fullBody)
    }

    /// INBOX-7: kept after it is read, newest first; brought up to date
    /// when it is handled.
    func testWhatWasToldIsKeptAfterItIsRead() {
        var book = InboxBook()
        book.take([notice(1, .done(said: "ok"), ago: 60), notice(2, asked)], now: now)
        XCTAssertEqual(book.entries.map(\.id), [2, 1])
        XCTAssertEqual(book.unread, 2)
        book.markRead(1)
        book.markRead(session: 2)
        XCTAssertEqual(book.unread, 0)
        XCTAssertEqual(book.entries.count, 2, "read is kept")
        book.handled(2, Notice.Handled(at: now, how: .answered))
        XCTAssertEqual(book.entries.first?.notice.handled?.how, .answered)
        book.take([notice(2, asked, handled: .answered)], now: now)
        XCTAssertEqual(book.entries.first?.read, true, "taken again, still read")
    }

    /// INBOX-8: one item, the read ones, or all are deleted; an agent that
    /// still waits stays; deleted stays deleted when the log comes again.
    func testDeletingOneTheReadOnesOrAll() {
        var book = InboxBook()
        book.take([notice(1, .done(said: nil)), notice(2, asked), notice(3, .done(said: "x")), notice(4, .done(said: "y"))], now: now)
        XCTAssertFalse(book.delete(2), "it waits for an answer")
        XCTAssertTrue(book.delete(1))
        book.markRead(3)
        book.deleteRead()
        XCTAssertEqual(book.entries.map(\.id).sorted(), [2, 4])
        book.deleteAll()
        XCTAssertEqual(book.entries.map(\.id), [2])
        book.take([notice(1, .done(said: nil)), notice(2, asked), notice(3, .done(said: "x")), notice(4, .done(said: "y"))], log: true, now: now)
        XCTAssertEqual(book.entries.map(\.id), [2], "the log does not bring back what was deleted")
        book.take([notice(2, asked, handled: .answered)], log: true, now: now)
        XCTAssertEqual(book.deleted, [], "what the host no longer keeps is forgotten")
        XCTAssertTrue(book.delete(2), "answered: it can go")
    }

    /// INBOX-9: older than 30 days goes by itself.
    func testThirtyDaysAreKept() {
        var book = InboxBook()
        book.take([notice(1, .done(said: nil), ago: Notice.kept + 60), notice(2, .done(said: nil), ago: Notice.kept - 60)], now: now)
        XCTAssertEqual(book.entries.map(\.id), [2])
        book.prune(now: now.addingTimeInterval(120))
        XCTAssertEqual(book.entries, [])
    }

    /// INBOX-11 (#180): read on another device is read here, and never
    /// unread again; handled by being answered, opened or dismissed is
    /// read, by moving on is not; what was read here while away is what
    /// the host is told once the log comes.
    func testReadIsTheSameOnEveryDevice() {
        var book = InboxBook()
        book.take([notice(1, .done(said: nil)), notice(2, asked), notice(3, .done(said: "x"))], now: now)
        book.markRead(ids: [1])
        XCTAssertEqual(book.unread, 2)
        var read = notice(2, asked)
        read.read = true
        book.take([read], now: now)
        XCTAssertEqual(book.entries.first { $0.id == 2 }?.read, true, "read in the host's log")
        book.take([notice(2, asked)], now: now)
        XCTAssertEqual(book.entries.first { $0.id == 2 }?.read, true, "never unread again")
        // Moved on is read too (#321, the owner's decision of 2026-11-23).
        book.handled(3, Notice.Handled(at: now, how: .movedOn))
        XCTAssertEqual(book.entries.first { $0.id == 3 }?.read, true, "moved on is read")
        XCTAssertEqual(book.unread, 0)

        // The host's log knows 2 as read; 1 and 3 were read here only.
        XCTAssertEqual(Set(book.readHere(notTold: [notice(1, .done(said: nil)), read, notice(3, .done(said: "x"))])), [1, 3])
        XCTAssertEqual(book.readHere(notTold: [read]), [], "not in the log: not told")

        var fresh = InboxBook()
        fresh.take([notice(4, asked), notice(5, .done(said: nil))], now: now)
        XCTAssertEqual(fresh.unread(session: 4), [4])
        fresh.take([notice(6, asked, handled: .dismissed)], now: now)
        XCTAssertEqual(fresh.entries.first { $0.id == 6 }?.read, true, "taken handled by dismissing: read")
    }
}
