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
                alreadyNotified: [profile.id: resetDate],
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
                alreadyNotified: [profile.id: preciseReset],
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
                alreadyNotified: [profile.id: now.addingTimeInterval(-90_000)],
                now: now
            ).count,
            1
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
