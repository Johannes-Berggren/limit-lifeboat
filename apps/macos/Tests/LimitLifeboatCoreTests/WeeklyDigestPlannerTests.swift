import XCTest
@testable import LimitLifeboatCore

final class WeeklyDigestPlannerTests: XCTestCase {
    private let planner = WeeklyDigestPlanner()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Due-ness

    /// nil means "never sent": the app layer arms the schedule instead of
    /// firing a near-empty digest over pre-feature history.
    func testNeverSentIsNotDue() {
        XCTAssertFalse(planner.isDue(lastSent: nil, now: now, calendar: utcCalendar))
    }

    func testDueSevenCalendarDaysAfterLastSend() {
        let lastSent = now.addingTimeInterval(-7 * 24 * 3600)
        XCTAssertTrue(planner.isDue(lastSent: lastSent, now: now, calendar: utcCalendar))
        XCTAssertFalse(
            planner.isDue(lastSent: now.addingTimeInterval(-6 * 24 * 3600), now: now, calendar: utcCalendar)
        )
    }

    /// Calendar day arithmetic, not 604800-second math: a spring-forward week
    /// is only 6d23h of absolute time and must still count as seven days.
    func testDueAcrossDSTTransition() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        // 2026-03-25 09:00 UTC → seven calendar days later spans the March 29
        // spring-forward, which removes one absolute hour.
        let lastSent = Date(timeIntervalSince1970: 1_774_429_200)
        let sevenCalendarDaysLater = calendar.date(byAdding: .day, value: 7, to: lastSent)!
        XCTAssertEqual(sevenCalendarDaysLater.timeIntervalSince(lastSent), 7 * 24 * 3600 - 3600)
        XCTAssertTrue(planner.isDue(lastSent: lastSent, now: sevenCalendarDaysLater, calendar: calendar))
        XCTAssertFalse(
            planner.isDue(
                lastSent: lastSent,
                now: sevenCalendarDaysLater.addingTimeInterval(-120),
                calendar: calendar
            )
        )
    }

    /// Weeks missed while the app was closed collapse into ONE digest: the
    /// period is always the trailing seven days from "now", never a backlog.
    func testMissedWeeksCollapseIntoOneTrailingPeriod() {
        let lastSent = now.addingTimeInterval(-30 * 24 * 3600)
        XCTAssertTrue(planner.isDue(lastSent: lastSent, now: now, calendar: utcCalendar))
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        XCTAssertEqual(period.end, now)
        XCTAssertEqual(period.duration, 7 * 24 * 3600, accuracy: 3700)
    }

    // MARK: - Building

    private func window(
        id: String = "weekly-all",
        kind: UsageWindowKind = .weekly,
        label: String = "Weekly (all models)",
        readings: [(hoursAgo: Double, usedPercent: Double)]
    ) -> WeeklyDigestPlanner.WindowInput {
        WeeklyDigestPlanner.WindowInput(
            id: id,
            kind: kind,
            label: label,
            readings: readings.map {
                BurnRateEstimator.Reading(
                    timestamp: now.addingTimeInterval(-$0.hoursAgo * 3600),
                    usedPercent: $0.usedPercent
                )
            }
        )
    }

    private func account(
        label: String,
        provider: Provider = .claude,
        windows: [WeeklyDigestPlanner.WindowInput]
    ) -> WeeklyDigestPlanner.AccountInput {
        WeeklyDigestPlanner.AccountInput(
            profileID: UUID(),
            label: label,
            provider: provider,
            windows: windows
        )
    }

    func testBuildLeadsWithTheMostConstrainedAccountAndCountsHitsAsAFloor() {
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        let digest = planner.build(
            accounts: [
                account(label: "Mild", windows: [window(readings: [(hoursAgo: 24, usedPercent: 30)])]),
                account(label: "Hot", windows: [
                    window(readings: [
                        (hoursAgo: 100, usedPercent: 99.8),
                        (hoursAgo: 60, usedPercent: 10),
                        (hoursAgo: 24, usedPercent: 100)
                    ])
                ])
            ],
            events: [],
            period: period
        )

        XCTAssertEqual(digest?.title, "Your week across 2 accounts")
        let body = digest?.body ?? ""
        XCTAssertTrue(body.hasPrefix("Hot (Claude): peaked at 100% weekly (all models), hit its limit at least 2×."))
        XCTAssertTrue(body.contains("Mild (Claude): peaked at 30%"))
        XCTAssertEqual(digest?.periodEnd, period.end)
    }

    func testBuildCountsSwitchesWithAutomaticSplit() {
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        func switchEvent(hoursAgo: Double, interactive: Bool) -> AppEvent {
            AppEvent(
                timestamp: now.addingTimeInterval(-hoursAgo * 3600),
                kind: .cliSwitch,
                provider: .claude,
                toProfileID: accountID,
                interactive: interactive
            )
        }

        let digest = planner.build(
            accounts: [account(label: "Solo", windows: [window(readings: [(hoursAgo: 24, usedPercent: 42)])])],
            events: [
                switchEvent(hoursAgo: 100, interactive: true),
                switchEvent(hoursAgo: 50, interactive: false),
                switchEvent(hoursAgo: 10, interactive: false)
            ],
            period: period
        )

        XCTAssertTrue(digest!.body.contains("switched the CLI 3× (2 automatic)."))
    }

    /// The dedupe carry-forward: an account whose only reading predates the
    /// period (flat usage all week) still reports that level as its peak.
    func testBuildCarriesPrePeriodReadingsForward() {
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        let digest = planner.build(
            accounts: [
                account(label: "Flat", windows: [window(readings: [(hoursAgo: 10 * 24, usedPercent: 80)])])
            ],
            events: [],
            period: period
        )

        XCTAssertTrue(digest!.body.contains("Flat (Claude): peaked at 80%"))
    }

    /// An account added mid-week reports its partial-period peak; an account
    /// with no readings at all says nothing.
    func testBuildSkipsAccountsWithNoReadings() {
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        let digest = planner.build(
            accounts: [
                account(label: "Fresh", windows: [window(readings: [(hoursAgo: 12, usedPercent: 25)])]),
                account(label: "Empty", windows: [window(readings: [])])
            ],
            events: [],
            period: period
        )

        XCTAssertEqual(digest?.title, "Your week across 1 account")
        XCTAssertFalse(digest!.body.contains("Empty"))
    }

    func testBuildReturnsNilWhenNothingToSay() {
        let period = planner.period(endingAt: now, calendar: utcCalendar)
        XCTAssertNil(planner.build(accounts: [], events: [], period: period))
        XCTAssertNil(
            planner.build(
                accounts: [account(label: "Empty", windows: [window(readings: [])])],
                events: [],
                period: period
            )
        )
    }
}
