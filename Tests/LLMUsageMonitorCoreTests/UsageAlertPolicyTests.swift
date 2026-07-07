import XCTest
@testable import LLMUsageMonitorCore

final class UsageAlertPolicyTests: XCTestCase {
    private let planner = ResetAlertPlanner()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testFiresForInactiveConstrainedAccountAfterReset() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: now.addingTimeInterval(-600))

        let alerts = planner.alerts(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].profileID, profile.id)
        XCTAssertEqual(alerts[0].profileLabel, "Claude 2")
        XCTAssertEqual(alerts[0].resetDate, now.addingTimeInterval(-600))
    }

    func testDoesNotFireForActiveAccount() {
        let profile = AccountProfile(provider: .claude, label: "Claude 1", isActiveCLI: true)
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: now.addingTimeInterval(-600))

        XCTAssertTrue(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    func testDoesNotFireBeforeResetElapses() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: now.addingTimeInterval(600))

        XCTAssertTrue(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    func testDoesNotFireForUnconstrainedAccount() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = snapshot(for: profile, usedPercent: 35, resetDate: now.addingTimeInterval(-600))

        XCTAssertTrue(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [:],
                now: now
            ).isEmpty
        )
    }

    func testFiresForDepletedAccountWithoutUsageFraction() {
        let profile = AccountProfile(provider: .codex, label: "Codex 2")
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: .codex,
            resetDate: now.addingTimeInterval(-600),
            riskLevel: .depleted,
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3_600),
            parseConfidence: .high
        )

        XCTAssertEqual(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [:],
                now: now
            ).count,
            1
        )
    }

    func testEachResetDateNotifiesOnce() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let resetDate = now.addingTimeInterval(-600)
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: resetDate)

        XCTAssertTrue(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "primary"): resetDate],
                now: now
            ).isEmpty
        )
    }

    /// Snapshots round-trip through .iso8601 JSON and lose sub-second
    /// precision, while the notified store keeps the full value — the dedupe
    /// must treat dates within the same second as the same reset.
    func testSubSecondPrecisionLossDoesNotRefire() {
        let profile = AccountProfile(provider: .codex, label: "Codex 2")
        let preciseReset = now.addingTimeInterval(-600.5)
        let truncatedReset = Date(timeIntervalSince1970: preciseReset.timeIntervalSince1970.rounded(.down))
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: truncatedReset)

        XCTAssertTrue(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "primary"): preciseReset],
                now: now
            ).isEmpty
        )
    }

    func testNewResetDateNotifiesAgain() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = snapshot(for: profile, usedPercent: 92, resetDate: now.addingTimeInterval(-600))

        XCTAssertEqual(
            planner.alerts(
                profiles: [profile],
                snapshots: [profile.id: snapshot],
                alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "primary"): now.addingTimeInterval(-90_000)],
                now: now
            ).count,
            1
        )
    }

    func testFiresOnlyForTheWindowThatElapsed() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = multiWindowSnapshot(
            for: profile,
            session: (usedPercent: 90, reset: now.addingTimeInterval(600)),    // constrained, not elapsed
            weekly: (usedPercent: 90, reset: now.addingTimeInterval(-600))      // constrained, elapsed
        )

        let alerts = planner.alerts(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].windowID, "weekly-all")
        XCTAssertEqual(alerts[0].windowLabel, "Weekly (all models)")
    }

    func testFiresForEachElapsedWindow() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let snapshot = multiWindowSnapshot(
            for: profile,
            session: (usedPercent: 90, reset: now.addingTimeInterval(-300)),
            weekly: (usedPercent: 90, reset: now.addingTimeInterval(-600))
        )

        let alerts = planner.alerts(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            alreadyNotified: [:],
            now: now
        )

        XCTAssertEqual(Set(alerts.map(\.windowID)), ["session", "weekly-all"])
    }

    func testPerWindowDedupeLeavesOtherWindowFree() {
        let profile = AccountProfile(provider: .claude, label: "Claude 2")
        let sessionReset = now.addingTimeInterval(-300)
        let weeklyReset = now.addingTimeInterval(-600)
        let snapshot = multiWindowSnapshot(
            for: profile,
            session: (usedPercent: 90, reset: sessionReset),
            weekly: (usedPercent: 90, reset: weeklyReset)
        )

        // The weekly window was already announced for this reset; only the
        // session window should still fire.
        let alerts = planner.alerts(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            alreadyNotified: [AlertWindowKey(profileID: profile.id, windowID: "weekly-all"): weeklyReset],
            now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].windowID, "session")
    }

    private func multiWindowSnapshot(
        for profile: AccountProfile,
        session: (usedPercent: Double, reset: Date?),
        weekly: (usedPercent: Double, reset: Date?)
    ) -> UsageSnapshot {
        func window(id: String, kind: UsageWindowKind, label: String, used: Double, reset: Date?) -> UsageWindow {
            UsageWindow(
                id: id,
                kind: kind,
                label: label,
                usedPercent: used,
                resetDate: reset,
                riskLevel: UsageThresholds.standard.riskLevel(usedPercent: used)
            )
        }
        return UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            windows: [
                window(id: "session", kind: .session, label: "Session", used: session.usedPercent, reset: session.reset),
                window(id: "weekly-all", kind: .weekly, label: "Weekly (all models)", used: weekly.usedPercent, reset: weekly.reset)
            ],
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3_600),
            parseConfidence: .high
        )
    }

    private func snapshot(for profile: AccountProfile, usedPercent: Double, resetDate: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            includedRemaining: 100 - usedPercent,
            includedLimit: 100,
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3_600),
            parseConfidence: .high
        )
    }
}
