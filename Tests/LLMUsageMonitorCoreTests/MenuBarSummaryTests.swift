import XCTest
@testable import LLMUsageMonitorCore

final class MenuBarSummaryTests: XCTestCase {
    func testProjectsActiveAccountsAndHonorsWindowPreference() {
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

        let session = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            preference: .session,
            now: now
        )
        let constrained = MenuBarSummaryProjector.project(
            profiles: [profile],
            snapshots: [profile.id: snapshot],
            preference: .mostConstrained,
            now: now
        )

        XCTAssertEqual(session.claudeValue, "25%")
        XCTAssertEqual(constrained.claudeValue, "85%")
        XCTAssertEqual(constrained.codexValue, "–")
        XCTAssertEqual(constrained.riskLevel, .warning)
        XCTAssertTrue(constrained.accessibilityText.contains("Primary"))
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
            preference: .mostConstrained,
            now: now
        )

        XCTAssertEqual(summary.codexValue, "20%*")
        XCTAssertEqual(summary.riskLevel, .stale)
    }
}
