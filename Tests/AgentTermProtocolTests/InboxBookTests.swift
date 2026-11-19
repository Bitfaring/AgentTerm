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
}
