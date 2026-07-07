import XCTest
@testable import LLMUsageMonitorCore

final class ClaudeResetDateParserTests: XCTestCase {
    private let parser = ClaudeResetDateParser()
    private let utc = TimeZone(identifier: "UTC")!

    /// Wednesday, 2026-07-08 10:00 UTC.
    private var now: Date {
        date(2026, 7, 8, 10, 0)
    }

    func testTimeOnlyLaterToday() {
        XCTAssertEqual(parser.parse("8pm", now: now, timeZone: utc), date(2026, 7, 8, 20, 0))
    }

    func testTimeOnlyAlreadyPassedRollsToTomorrow() {
        XCTAssertEqual(parser.parse("8am", now: now, timeZone: utc), date(2026, 7, 9, 8, 0))
    }

    func testTimeWithMinutes() {
        XCTAssertEqual(parser.parse("10:59pm", now: now, timeZone: utc), date(2026, 7, 8, 22, 59))
    }

    func testNoonAndMidnight() {
        XCTAssertEqual(parser.parse("12pm", now: now, timeZone: utc), date(2026, 7, 8, 12, 0))
        XCTAssertEqual(parser.parse("12am", now: now, timeZone: utc), date(2026, 7, 9, 0, 0))
    }

    func testExplicitTimeZoneSuffixOverridesDefault() {
        let oslo = TimeZone(identifier: "Europe/Oslo")!
        XCTAssertEqual(
            parser.parse("10:59pm (Europe/Oslo)", now: now, timeZone: utc),
            date(2026, 7, 8, 22, 59, timeZone: oslo)
        )
    }

    func testMonthDayWithTime() {
        XCTAssertEqual(parser.parse("Jul 10 at 6am", now: now, timeZone: utc), date(2026, 7, 10, 6, 0))
    }

    func testMonthDayWithoutTimeResolvesToEndOfDay() {
        XCTAssertEqual(parser.parse("Aug 1", now: now, timeZone: utc), date(2026, 8, 2, 0, 0))
    }

    func testMonthDayInPastRollsToNextYear() {
        XCTAssertEqual(parser.parse("Jan 5", now: now, timeZone: utc), date(2027, 1, 6, 0, 0))
    }

    func testMonthDayJustElapsedStaysInPast() {
        XCTAssertEqual(parser.parse("Jul 8 at 9am", now: now, timeZone: utc), date(2026, 7, 8, 9, 0))
    }

    func testWeekdayWithTime() {
        XCTAssertEqual(parser.parse("Fri 3am", now: now, timeZone: utc), date(2026, 7, 10, 3, 0))
    }

    func testWeekdayWithoutTimeResolvesToEndOfDay() {
        XCTAssertEqual(parser.parse("Friday", now: now, timeZone: utc), date(2026, 7, 11, 0, 0))
    }

    func testTodayWeekdayWithoutTimeResolvesToEndOfToday() {
        XCTAssertEqual(parser.parse("Wednesday", now: now, timeZone: utc), date(2026, 7, 9, 0, 0))
    }

    func testTodayWeekdayWithPassedTimeMeansNextWeek() {
        XCTAssertEqual(parser.parse("Wed 8am", now: now, timeZone: utc), date(2026, 7, 15, 8, 0))
    }

    func testRelativeHoursAndMinutes() {
        XCTAssertEqual(
            parser.parse("in 2h 15m", now: now, timeZone: utc),
            now.addingTimeInterval(2 * 3_600 + 15 * 60)
        )
    }

    func testRelativeDays() {
        XCTAssertEqual(parser.parse("in 3 days", now: now, timeZone: utc), now.addingTimeInterval(3 * 86_400))
    }

    func testTomorrowWithTime() {
        XCTAssertEqual(parser.parse("tomorrow at 3am", now: now, timeZone: utc), date(2026, 7, 9, 3, 0))
    }

    func testUnrecognizedTextReturnsNil() {
        XCTAssertNil(parser.parse("", now: now, timeZone: utc))
        XCTAssertNil(parser.parse("soon", now: now, timeZone: utc))
        XCTAssertNil(parser.parse("monthly", now: now, timeZone: utc))
        XCTAssertNil(parser.parse("when the window rolls over", now: now, timeZone: utc))
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        timeZone: TimeZone? = nil
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? utc
        return calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }
}
