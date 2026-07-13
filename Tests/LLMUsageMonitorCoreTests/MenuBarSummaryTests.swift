import XCTest
@testable import LLMUsageMonitorCore

final class MenuBarSummaryTests: XCTestCase {
    func testProjectsBothPrimaryLimitsForActiveAccount() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 25
                ),
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly", kind: .weekly, label: "Weekly"),
                    usedPercent: 85
                )
            ],
            source: "test",
            lastRefreshed: now,
            message: "test"
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            now: now
        )

        XCTAssertEqual(summary.claudeValue, "S 25% W 85%")
        XCTAssertEqual(summary.codexValue, "–")
        XCTAssertEqual(summary.riskLevel, .warning)
        XCTAssertTrue(summary.accessibilityText.contains("Primary"))
        XCTAssertTrue(summary.accessibilityText.contains("session 25 percent"))
        XCTAssertTrue(summary.accessibilityText.contains("weekly 85 percent"))
    }

    func testScopedWeeklyNeverFillsOrInfluencesMenuBar() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 25
                ),
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly-fable", kind: .weeklyScoped, label: "Weekly (Fable)"),
                    usedPercent: 100
                )
            ],
            source: "test",
            lastRefreshed: now,
            message: "test"
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            now: now
        )

        XCTAssertEqual(summary.claudeValue, "S 25% W –")
        XCTAssertEqual(summary.riskLevel, .healthy)
        XCTAssertFalse(summary.accessibilityText.contains("Fable"))
        XCTAssertFalse(summary.accessibilityText.contains("100 percent"))
    }

    func testPayAsYouGoAppendsWithoutReplacingPrimaryLimits() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 100
                ),
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly", kind: .weekly, label: "Weekly"),
                    usedPercent: 82
                )
            ],
            source: "test",
            lastRefreshed: now,
            message: "test",
            payAsYouGoState: .enabledActive
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            now: now
        )

        XCTAssertEqual(summary.claudeValue, "S 100% W 82% PAYG")
        XCTAssertEqual(summary.riskLevel, .depleted)
        XCTAssertTrue(summary.accessibilityText.contains("pay as you go"))
    }

    func testMissingSnapshotAndMissingActiveAccountHaveDistinctValues() {
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)

        let missingSnapshot = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [:]
        )
        let noActive = MenuBarSummaryProjector.project(
            profiles: [AccountProfile(provider: .claude, label: "Inactive")],
            snapshots: [:]
        )

        XCTAssertEqual(missingSnapshot.claudeValue, "S ? W ?")
        XCTAssertEqual(noActive.claudeValue, "–")
    }

    func testStaleHealthyReadingIsMarkedStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .codex, label: "Codex", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .codex,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 20
                )
            ],
            source: "test",
            lastRefreshed: now.addingTimeInterval(-UsageThresholds.standard.staleAfter - 1),
            message: "test"
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            now: now
        )

        XCTAssertEqual(summary.codexValue, "S 20% W –*")
        XCTAssertEqual(summary.riskLevel, .stale)
    }
}
