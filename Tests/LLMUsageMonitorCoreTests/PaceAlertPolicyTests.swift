import XCTest
@testable import LLMUsageMonitorCore

final class PaceAlertPlannerTests: XCTestCase {
    private let planner = PaceAlertPlanner()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let profile = AccountProfile(provider: .claude, label: "Claude 2")

    func testWeeklyDepletesAtFiresWithCorrectFields() {
        let resetDate = now.addingTimeInterval(3 * 86_400)
        let depletion = now.addingTimeInterval(86_400)
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: resetDate)])

        let alerts = planner.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: ["weekly-all": .depletesAt(depletion)],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].profileID, profile.id)
        XCTAssertEqual(alerts[0].profileLabel, "Claude 2")
        XCTAssertEqual(alerts[0].windowID, "weekly-all")
        XCTAssertEqual(alerts[0].windowLabel, "Weekly (all models)")
        XCTAssertEqual(alerts[0].projectedDepletion, depletion)
        XCTAssertEqual(alerts[0].resetDate, resetDate)
    }

    func testAlreadyNotifiedAtSameResetDateIsSilent() {
        let resetDate = now.addingTimeInterval(3 * 86_400)
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: resetDate)])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): resetDate],
                now: now
            ).isEmpty
        )
    }

    /// Snapshot reset dates round-trip through .iso8601 JSON and lose
    /// sub-second precision while the notified store keeps the full value —
    /// dates within the same second must count as the same reset period.
    func testSubSecondPrecisionLossDoesNotRefire() {
        let preciseReset = now.addingTimeInterval(3 * 86_400 + 0.5)
        let truncatedReset = Date(timeIntervalSince1970: preciseReset.timeIntervalSince1970.rounded(.down))
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: truncatedReset)])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): preciseReset],
                now: now
            ).isEmpty
        )
    }

    func testNewResetPeriodRefires() {
        let previousReset = now.addingTimeInterval(-4 * 86_400)
        let currentReset = previousReset.addingTimeInterval(7 * 86_400)
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: currentReset)])

        let alerts = planner.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
            alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): previousReset],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].resetDate, currentReset)
    }

    func testSessionWindowNeverFires() {
        let sessionWindow = UsageWindow(
            id: "session",
            kind: .session,
            label: "Session",
            usedPercent: 70,
            resetDate: now.addingTimeInterval(3_600),
            riskLevel: .healthy
        )
        let snapshot = windowedSnapshot([sessionWindow])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["session": .depletesAt(now.addingTimeInterval(1_800))],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    func testSafeAndInsufficientDataNeverFire() {
        let snapshot = windowedSnapshot([
            weeklyWindow(resetDate: now.addingTimeInterval(3 * 86_400)),
            weeklyWindow(
                id: "weekly-fable",
                label: "Weekly (Fable)",
                kind: .weeklyScoped,
                resetDate: now.addingTimeInterval(3 * 86_400)
            )
        ])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .safe, "weekly-fable": .insufficientData],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    func testScopedWeeklyFiresIndependentlyOfWeeklyAll() {
        let resetDate = now.addingTimeInterval(3 * 86_400)
        let snapshot = windowedSnapshot([
            weeklyWindow(resetDate: resetDate),
            weeklyWindow(id: "weekly-fable", label: "Weekly (Fable)", kind: .weeklyScoped, resetDate: resetDate)
        ])

        // The all-models window was already announced for this reset; the
        // scoped window should still fire on its own.
        let alerts = planner.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: [
                "weekly-all": .depletesAt(now.addingTimeInterval(86_400)),
                "weekly-fable": .depletesAt(now.addingTimeInterval(43_200))
            ],
            alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): resetDate],
            now: now
        )

        XCTAssertEqual(alerts.map(\.windowID), ["weekly-fable"])
    }

    func testNilResetDateFiresFirstTime() {
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: nil)])

        let alerts = planner.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertNil(alerts[0].resetDate)
    }

    func testNilResetDateRecentEntrySuppresses() {
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: nil)])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [
                    AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): now.addingTimeInterval(-2 * 86_400)
                ],
                now: now
            ).isEmpty
        )
    }

    func testNilResetDateEntryOlderThanSevenDaysRefires() {
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: nil)])

        XCTAssertEqual(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [
                    AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): now.addingTimeInterval(-8 * 86_400)
                ],
                now: now
            ).count,
            1
        )
    }

    func testNoParseConfidenceIsSilent() {
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            windows: [weeklyWindow(resetDate: now.addingTimeInterval(3 * 86_400))],
            source: "test",
            lastRefreshed: now,
            parseConfidence: .none
        )

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    private func windowedSnapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            windows: windows,
            source: "test",
            lastRefreshed: now,
            parseConfidence: .high
        )
    }

    private func weeklyWindow(
        id: String = "weekly-all",
        label: String = "Weekly (all models)",
        kind: UsageWindowKind = .weekly,
        usedPercent: Double = 60,
        resetDate: Date?
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent)
        )
    }
}
