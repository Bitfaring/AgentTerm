import AgentTermProtocol
import XCTest

/// What a push carries (#66): encrypted for one device, bound to its name.
final class PushSealTests: XCTestCase {
    private static func agent(_ id: UInt64, session: SessionID, name: String, folder: String, state: AgentState) -> Notice {
        Notice(id: id, at: Date(), session: session, name: name, folder: folder, kind: .agent(state))
    }

    private let notice = PushNotice(
        agent(
            3, session: 7, name: "Fix the build", folder: "/Users/me/app",
            state: .waitingForAnswer(AgentQuestion(text: "Which branch?", choices: ["main", "dev"]))))

    /// PUSH-1: a notice opens with its device's key and its identifier,
    /// and with nothing else.
    func testANoticeOpensOnlyWithItsKeyAndItsName() throws {
        let key = PushSeal.newKey()
        XCTAssertEqual(key.count, 32)
        let identifier = PushNotice.identifier(mac: "4F1A-mac", notice: 3)
        let sealed = try PushSeal.seal(notice, identifier: identifier, key: key)
        XCTAssertFalse(sealed.contains("branch"), "nothing of it can be read on the way")
        XCTAssertEqual(try PushSeal.open(sealed, identifier: identifier, key: key), notice)
        XCTAssertThrowsError(try PushSeal.open(sealed, identifier: identifier, key: PushSeal.newKey()), "another device's key")
        XCTAssertThrowsError(try PushSeal.open(sealed, identifier: PushNotice.identifier(mac: "4F1A-mac", notice: 4), key: key), "moved to another notification")
        XCTAssertThrowsError(try PushSeal.open("not base64!", identifier: identifier, key: key))
        XCTAssertThrowsError(try PushSeal.seal(notice, identifier: identifier, key: Data(count: 16)), "not a key")
    }

    /// PUSH-1: the identifier is the one the app gives a notification of
    /// its own, and gives back the Mac and the session, dashes and all.
    func testTheIdentifierNamesTheMacAndTheSession() {
        let identifier = PushNotice.identifier(mac: "8C2D1E7A-0B4C-4E59-9D3A-1F2E3D4C5B6A", notice: 42)
        XCTAssertEqual(identifier, "8C2D1E7A-0B4C-4E59-9D3A-1F2E3D4C5B6A-42")
        XCTAssertLessThanOrEqual(identifier.count, 64, "APNs takes a collapse identifier of 64 bytes at most")
        XCTAssertEqual(PushNotice.parse(identifier: identifier)?.mac, "8C2D1E7A-0B4C-4E59-9D3A-1F2E3D4C5B6A")
        XCTAssertEqual(PushNotice.parse(identifier: identifier)?.notice, 42)
        XCTAssertNil(PushNotice.parse(identifier: "-42"))
        XCTAssertNil(PushNotice.parse(identifier: "mac-x"))
    }

    /// PUSH-1: what is shortened to fit is named whole by its digest, by
    /// which a reply goes only to the very state it answers.
    func testAShortenedStateIsNamedWholeByItsDigest() {
        let said = String(repeating: "All tests pass. ", count: 100)
        let pushed = PushNotice(Self.agent(1, session: 1, name: "a", folder: "/", state: .done(said: said)))
        XCTAssertEqual(pushed.state, .done(said: String(said.suffix(AgentNotice.detailLength))))
        XCTAssertEqual(pushed.stateDigest, PushNotice.digest(.done(said: said)))
        XCTAssertNotEqual(pushed.stateDigest, pushed.state.map(PushNotice.digest))
        XCTAssertNotEqual(PushNotice.digest(.done(said: "a")), PushNotice.digest(.done(said: "b")))
    }

    /// PUSH-1: a notice of the longest kind still fits in a push.
    func testTheLongestNoticeFitsInAPush() throws {
        let long = String(repeating: "word ", count: 400)
        let choices = (1...9).map { "Choice \($0) " + String(repeating: "x", count: 60) }
        let biggest = PushNotice(
            Self.agent(
                UInt64.max, session: 4_000_000_000, name: String(repeating: "n", count: 80), folder: "/Users/someone/" + String(repeating: "f", count: 120),
                state: .waitingForAnswer(AgentQuestion(text: String(long.prefix(1000)), choices: choices))))
        let sealed = try PushSeal.seal(biggest, identifier: "8C2D1E7A-0B4C-4E59-9D3A-1F2E3D4C5B6A-18446744073709551615", key: PushSeal.newKey())
        XCTAssertLessThanOrEqual(sealed.count, 3000, "the relay takes 3000 characters of it")
        let failure = PushNotice(
            Notice(
                id: 9, at: Date(), session: nil, name: "", folder: "",
                kind: .failure(PartFailure(part: .host, at: Date(), restarted: false, reason: String(repeating: "r", count: 5000)))))
        XCTAssertNil(failure.agentNotice)
        XCTAssertNotNil(failure.title)
        XCTAssertLessThanOrEqual(try PushSeal.seal(failure, identifier: "m-9", key: PushSeal.newKey()).count, 3000)
    }
}
