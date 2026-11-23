import AgentTermProtocol
import XCTest

/// What the review of 2026-11-22 found in when a schedule runs and how it
/// is said (#290, #291).
final class ReviewScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func moment(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// #290: "every 30 minutes, 22:00 to 06:00" runs every 30 minutes from
    /// 22:00 until 06:00 of the next day, as its label says.
    func testAWindowThatCrossesMidnightRunsAllThroughIt() {
        let when = ScheduleTime.every(minutes: 30, from: 22 * 60, until: 6 * 60)
        XCTAssertEqual(when.label(calendar: calendar), "Every 30 minutes, 22:00 to 06:00")
        XCTAssertEqual(when.next(after: moment(10, 22, 0), calendar: calendar), moment(10, 22, 30), "the run after 22:00")
        XCTAssertEqual(when.next(after: moment(10, 23, 45), calendar: calendar), moment(11, 0, 0), "the run after 23:45")
        XCTAssertEqual(when.next(after: moment(11, 5, 40), calendar: calendar), moment(11, 6, 0), "the last of the window")
        XCTAssertEqual(when.next(after: moment(11, 6, 0), calendar: calendar), moment(11, 22, 0), "none between 06:00 and 22:00")
    }

    /// #291: a weekly schedule whose label names a day runs on a day: a day
    /// of the week out of 1...7 is not shown as one that never comes.
    func testAWeekdayOutOfRangeIsNotLabelledAsADayThatNeverRuns() {
        for weekday in [0, 8] {
            let when = ScheduleTime.weekly(weekdays: [weekday], hour: 9, minute: 0)
            let label = when.label(calendar: calendar)
            let next = when.next(after: moment(10, 12, 0), calendar: calendar)
            let namesADay = calendar.shortWeekdaySymbols.contains { label.hasPrefix($0) }
            XCTAssertFalse(namesADay && next == nil, "weekday \(weekday) is labelled “\(label)” and never runs")
        }
    }

    /// #291: a day of the week of -7 or lower does not stop the process in
    /// `label()`; before the fix `($0 - 1 + 7) % 7` was a negative index.
    func testANegativeWeekdayDoesNotStopTheProcess() throws {
        let when = ScheduleTime.weekly(weekdays: [-7], hour: 9, minute: 0)
        XCTAssertFalse(when.label(calendar: calendar).isEmpty)
    }

    /// #291: a day of the week out of 1...7 is said to be none, in words
    /// both apps and the host show.
    func testADayOutOfRangeIsSaidToBeNone() {
        for days in [[-7], [0], [8], [], [1, 9]] {
            XCTAssertEqual(ScheduleTime.weekly(weekdays: days, hour: 9, minute: 0).refusal, ScheduleTime.daysRefusal, "\(days)")
        }
        XCTAssertNil(ScheduleTime.weekly(weekdays: [1, 7], hour: 9, minute: 0).refusal)
        XCTAssertNil(ScheduleTime.daily(hour: 9, minute: 0).refusal)
    }
}
