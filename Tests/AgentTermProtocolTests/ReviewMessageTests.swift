import AgentTermProtocol
import XCTest

/// What the review of 2026-11-22 found in what is encoded, sealed and put
/// into words from numbers a peer sends (#292, #294, #296).
final class ReviewMessageTests: XCTestCase {

    // MARK: #292

    /// #292: a message with a number JSON has no way to write (not a
    /// number, infinite) is not turned into an empty frame.
    func testAMessageThatCannotBeEncodedIsNotAnEmptyFrame() {
        for cpu in [Double.nan, .infinity] {
            let frame = MessageCoding.encode(ServerMessage.systemStats(SystemStats(cpuPercent: cpu)))
            XCTAssertFalse(frame.isEmpty, "systemStats with cpuPercent \(cpu) is encoded as \(frame.count) bytes")
        }
        let usage = AccountUsage(agent: "claude", groups: [AccountUsageGroup(limits: [AccountLimit(id: "w", title: "Week", shortTitle: "Week", usedPercent: .nan)])])
        XCTAssertFalse(MessageCoding.encode(usage).isEmpty, "an account's usage with a percentage that is not a number is encoded as nothing")
        // And read back as it was.
        let read = MessageCoding.decode(ServerMessage.self, from: MessageCoding.encode(ServerMessage.systemStats(SystemStats(cpuPercent: .infinity))))
        guard case .systemStats(let stats)? = read else { return XCTFail("not read back: \(String(describing: read))") }
        XCTAssertEqual(stats.cpuPercent, .infinity)
    }

    // MARK: #294

    /// #294: a notice of the longest kind fits in a push whatever it is
    /// written in: the relay takes 3000 characters, and Apple 4 KB in all.
    func testTheLongestNoticeFitsInAPushInAnyScript() throws {
        let question = String(repeating: "この変更をどのブランチに入れますか。", count: 40)
        let choices = (1...9).map { "選択肢\($0)" + String(repeating: "あ", count: 90) }
        let notice = Notice(
            id: UInt64.max, at: Date(), session: 4_000_000_000, name: String(repeating: "名", count: 100), folder: "/Users/someone/" + String(repeating: "フ", count: 200),
            kind: .agent(.waitingForAnswer(AgentQuestion(text: question, choices: choices))))
        let pushed = PushNotice(notice)
        let plain = try JSONEncoder().encode(pushed)
        let sealed = try PushSeal.seal(pushed, identifier: "8C2D1E7A-0B4C-4E59-9D3A-1F2E3D4C5B6A-18446744073709551615", key: PushSeal.newKey())
        XCTAssertLessThanOrEqual(sealed.count, 3000, "the notice is \(plain.count) bytes of JSON and \(sealed.count) characters sealed; the relay takes 3000")
    }

    // MARK: #296

    /// #296: what an `Int` cannot hold is the nearest it can.
    func testANumberOutOfRangeIsTheNearestWholeNumber() {
        XCTAssertEqual(Int(saturating: 1e300), .max)
        XCTAssertEqual(Int(saturating: -1e300), .min)
        XCTAssertEqual(Int(saturating: .infinity), .max)
        XCTAssertEqual(Int(saturating: .nan), 0)
        XCTAssertEqual(Int(saturating: 41.9), 41)
        XCTAssertEqual(Int(saturating: -2.5), -2)
        XCTAssertEqual(Int(saturating: Double(Int.max)), .max)
    }

    /// #296: a length of time out of range is put into words, not a stop.
    func testADurationOutOfRangeDoesNotStopTheProcess() throws {
        XCTAssertFalse(ConversationDetails.words(for: 1e300).isEmpty)
    }

    /// #296: a run's name is made of any date that can be read from a message.
    func testARunAtADateOutOfRangeDoesNotStopTheProcess() throws {
        let date = try XCTUnwrap(MessageCoding.decode([Date].self, from: Data("[1e300]".utf8))?.first, "the date is not read from a message")
        XCTAssertFalse(ScheduleOverview.Run.id(schedule: "s", at: date).isEmpty)
    }

    /// #296: a temperature out of range is shown, not a stop.
    func testATemperatureOutOfRangeDoesNotStopTheProcess() throws {
        let stats = try XCTUnwrap(MessageCoding.decode(SystemStats.self, from: MessageCoding.encode(SystemStats(temperature: 1e300))))
        XCTAssertFalse(stats.temperatureText.isEmpty)
    }

    /// #296: a Mac said to have started at a date out of range still has an
    /// uptime in words.
    func testABootDateOutOfRangeDoesNotStopTheProcess() throws {
        XCTAssertFalse(SystemStats.uptime(since: Date(timeIntervalSince1970: -1e300)).isEmpty)
    }

    /// #296: a percentage out of range is shown, not a stop.
    func testAPercentageOutOfRangeDoesNotStopTheProcess() throws {
        let limit = AccountLimit(id: "w", title: "Week", shortTitle: "Week", usedPercent: 1e300)
        let usage = AccountUsage(agent: "claude", showsRemaining: false, groups: [AccountUsageGroup(limits: [limit])])
        let read = try XCTUnwrap(MessageCoding.decode(AccountUsage.self, from: MessageCoding.encode(usage)))
        XCTAssertFalse(read.percentText(read.limits[0]).isEmpty)
    }
}
