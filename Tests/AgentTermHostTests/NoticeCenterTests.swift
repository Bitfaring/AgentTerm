import AgentTermProtocol
import XCTest

@testable import AgentTermHost

/// The host's notices (#66, decided 2026-11-19), without a server.
final class NoticeCenterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("notices-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func session(_ id: SessionID, _ state: AgentState?) -> SessionInfo {
        var info = SessionInfo(id: id, title: "agent \(id)", cwd: "/tmp/app", size: .default, createdAt: now)
        info.state = state
        return info
    }

    private let asked = AgentState.waitingForAnswer(AgentQuestion(text: "Which?", choices: ["a", "b"]))

    /// NOTICE-1: one notice for each state an agent is done or waits in;
    /// handled when the agent moves on or its session ends.
    func testANoticeIsMadeOnceAndHandledWhenTheAgentMovesOn() {
        let center = NoticeCenter(file: file)
        var (new, handled) = center.update(sessions: [session(1, asked)], now: now)
        XCTAssertEqual(new.map(\.state), [asked])
        XCTAssertEqual(handled, [])
        (new, handled) = center.update(sessions: [session(1, asked)], now: now)
        XCTAssertEqual(new, [], "told once")
        (new, handled) = center.update(sessions: [session(1, .working(since: now))], now: now)
        XCTAssertEqual(handled.map(\.handled?.how), [.movedOn])
        (new, handled) = center.update(sessions: [session(1, .done(said: "ok"))], now: now)
        XCTAssertEqual(new.map(\.state), [.done(said: "ok")])
        (new, handled) = center.update(sessions: [], now: now)
        XCTAssertEqual(handled.map(\.handled?.how), [.movedOn], "the session ended")
        XCTAssertEqual(center.log.count, 2)
    }

    /// NOTICE-2: handled by a device once; opened or answered names the
    /// session and the state.
    func testANoticeIsHandledOnce() throws {
        let center = NoticeCenter(file: file)
        let notice = try XCTUnwrap(center.update(sessions: [session(1, asked)], now: now).new.first)
        XCTAssertEqual(center.handle(session: 1, state: .done(said: nil), how: .opened, now: now), [], "another state")
        XCTAssertEqual(center.handle(session: 1, state: asked, how: .answered, now: now).map(\.id), [notice.id])
        XCTAssertNil(center.handle(notice.id, how: .dismissed, now: now), "handled already")
        XCTAssertEqual(center.log.first?.handled?.how, .answered)
    }

    /// NOTICE-3: every failure is a notice, for the Inbox, dismissed with
    /// the failure; only one that stopped work is a notification too.
    func testAFailureThatStoppedWorkIsANotice() throws {
        let center = NoticeCenter(file: file)
        let stopped = PartFailure(part: .session, name: "build", at: now, restarted: false)
        let notice = try XCTUnwrap(center.report(stopped, now: now))
        XCTAssertEqual(notice.title(), stopped.headline())
        XCTAssertTrue(notice.alerts)
        XCTAssertEqual(center.report(PartFailure(part: .push, name: "iPhone", at: now, restarted: false), now: now)?.alerts, false)
        XCTAssertEqual(center.report(PartFailure(part: .keepAwake, at: now, restarted: false), now: now)?.alerts, false)
        XCTAssertEqual(center.handle(failure: stopped.id, now: now).map(\.id), [notice.id])
    }

    /// NOTICE-4: what each device was told is kept, also when the host
    /// starts again, which ends what agents asked; 30 days are kept.
    func testWhatWasToldIsKeptAndOldNoticesGo() throws {
        let center = NoticeCenter(file: file)
        let first = try XCTUnwrap(center.update(sessions: [session(1, asked)], now: now).new.first)
        let second = try XCTUnwrap(center.update(sessions: [session(1, asked), session(2, .done(said: nil))], now: now).new.first)
        center.becameDue(first.id)
        center.told(first.id, to: "phone", throughApple: true)
        // Not due yet: not a notification yet, anywhere (#180).
        XCTAssertEqual(center.untold(to: "phone").map(\.id), [])
        center.becameDue(second.id)
        XCTAssertEqual(center.untold(to: "phone").map(\.id), [second.id])
        XCTAssertEqual(center.pushedTo(first.id), ["phone"])

        let again = NoticeCenter(file: file)
        XCTAssertEqual(again.log.map(\.id), [first.id, second.id])
        XCTAssertTrue(again.log.allSatisfy { $0.handled?.how == .movedOn }, "the sessions ended with the host")
        XCTAssertEqual(again.untold(to: "phone"), [])
        XCTAssertEqual(again.pushedTo(first.id), ["phone"])
        let next = try XCTUnwrap(again.update(sessions: [session(3, asked)], now: now).new.first)
        XCTAssertGreaterThan(next.id, second.id, "numbers are never used again")

        _ = again.update(sessions: [session(3, asked)], now: now.addingTimeInterval(Notice.kept + 60))
        XCTAssertEqual(again.log.map(\.id), [], "older than 30 days")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    /// NOTICE-5 (#180): read on one device is read in the log, once, and
    /// no longer to be shown; handled by being answered, opened or
    /// dismissed is read too, by moving on is not.
    func testReadOnOneDeviceIsReadForAll() throws {
        let center = NoticeCenter(file: file)
        let first = try XCTUnwrap(center.update(sessions: [session(1, asked)], now: now).new.first)
        let second = try XCTUnwrap(center.update(sessions: [session(1, asked), session(2, .done(said: nil))], now: now).new.first)
        center.becameDue(first.id)
        center.becameDue(second.id)
        XCTAssertEqual(center.read([first.id]), [first.id])
        XCTAssertEqual(center.read([first.id]), [], "read once")
        XCTAssertNil(center.pending(first.id), "read: not to be shown")
        XCTAssertEqual(center.untold(to: "phone").map(\.id), [second.id])
        XCTAssertEqual(NoticeCenter(file: file).log.first { $0.id == first.id }?.read, true, "kept")

        _ = center.handle(second.id, how: .opened, now: now)
        XCTAssertEqual(center.log.first { $0.id == second.id }?.read, true)
        let third = try XCTUnwrap(center.update(sessions: [session(1, asked), session(2, .done(said: nil)), session(3, asked)], now: now).new.first)
        _ = center.update(sessions: [session(1, asked), session(2, .done(said: nil))], now: now)
        XCTAssertEqual(center.log.first { $0.id == third.id }?.handled?.how, .movedOn)
        XCTAssertNil(center.log.first { $0.id == third.id }?.read, "moved on is not read")
    }
}
