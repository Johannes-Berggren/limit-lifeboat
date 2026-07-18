import XCTest
@testable import LimitLifeboatCore

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

    /// The active account's snapshots alternate between the usage API's exact
    /// `resets_at` and the TUI text parse's minutes-coarse value, so the same
    /// reset can be stored and re-read minutes apart — a source flip must not
    /// re-fire the alert within the same period.
    func testSourceFlipMinutesApartDoesNotRefire() {
        let apiReset = now.addingTimeInterval(3 * 86_400 + 250)
        let parsedReset = apiReset.addingTimeInterval(-600)
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: parsedReset)])

        XCTAssertTrue(
            planner.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): apiReset],
                now: now
            ).isEmpty
        )
    }

    /// A stored date from the previous period sits a full week from the
    /// current reset — far beyond `resetMatchTolerance` — so the alert
    /// re-arms.
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
        let snapshot = windowedSnapshot([sessionWindow(resetDate: now.addingTimeInterval(3_600))])

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

    func testSessionWindowFiresWhenOptedIn() {
        let optedIn = PaceAlertPlanner(includeSessionWindows: true)
        let resetDate = now.addingTimeInterval(3_600)
        let depletion = now.addingTimeInterval(1_800)
        let snapshot = windowedSnapshot([sessionWindow(resetDate: resetDate)])

        let alerts = optedIn.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: ["session": .depletesAt(depletion)],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(alerts.map(\.windowID), ["session"])
        XCTAssertEqual(alerts[0].projectedDepletion, depletion)
    }

    /// The load-bearing tolerance split: consecutive ~5h session resets sit
    /// well inside the 24h weekly tolerance, so with a single tolerance a
    /// session alert would fire once and never re-arm. The next session
    /// period (hours later) must count as a NEW reset.
    func testSessionAlertRearmsForTheNextSessionPeriod() {
        let optedIn = PaceAlertPlanner(includeSessionWindows: true)
        let previousReset = now.addingTimeInterval(-3_600)
        let currentReset = previousReset.addingTimeInterval(5 * 3_600)
        let snapshot = windowedSnapshot([sessionWindow(resetDate: currentReset)])

        let alerts = optedIn.alerts(
            snapshot: snapshot,
            profile: profile,
            estimates: ["session": .depletesAt(now.addingTimeInterval(1_800))],
            alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "session"): previousReset],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
    }

    /// Minutes-scale reset-date jitter (API vs TUI re-anchoring) within the
    /// same session period must still dedupe.
    func testSessionAlertDedupesWithinTheSamePeriodDespiteJitter() {
        let optedIn = PaceAlertPlanner(includeSessionWindows: true)
        let storedReset = now.addingTimeInterval(3_600)
        let jitteredReset = storedReset.addingTimeInterval(-10 * 60)
        let snapshot = windowedSnapshot([sessionWindow(resetDate: jitteredReset)])

        XCTAssertTrue(
            optedIn.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["session": .depletesAt(now.addingTimeInterval(1_800))],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "session"): storedReset],
                now: now
            ).isEmpty
        )
    }

    /// Opting sessions in must not loosen the weekly dedupe.
    func testWeeklyDedupeUnchangedWhenSessionsOptedIn() {
        let optedIn = PaceAlertPlanner(includeSessionWindows: true)
        let apiReset = now.addingTimeInterval(3 * 86_400 + 250)
        let parsedReset = apiReset.addingTimeInterval(-600)
        let snapshot = windowedSnapshot([weeklyWindow(resetDate: parsedReset)])

        XCTAssertTrue(
            optedIn.alerts(
                snapshot: snapshot,
                profile: profile,
                estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(86_400))],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): apiReset],
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

    private func sessionWindow(usedPercent: Double = 70, resetDate: Date?) -> UsageWindow {
        UsageWindow(
            id: "session",
            kind: .session,
            label: "Session",
            usedPercent: usedPercent,
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent)
        )
    }
}
