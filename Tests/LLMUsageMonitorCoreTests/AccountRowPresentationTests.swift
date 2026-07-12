import XCTest
@testable import LLMUsageMonitorCore

final class AccountRowPresentationTests: XCTestCase {
    func testFailureTakesPrecedenceAndRemainsRetryable() {
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .readFailed(reason: "Offline"),
            adviceReason: nil
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Couldn't refresh")
        XCTAssertEqual(presentation.refreshProblem?.help, "Offline")
        XCTAssertEqual(presentation.refreshProblem?.showsRetry, true)
        XCTAssertNotNil(presentation.footerNote)
    }

    func testEveryScopedWindowIsVisibleInDenseView() {
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let windows = [
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                usedPercent: 20
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "weekly-risk", kind: .weeklyScoped, label: "Weekly Risk"),
                usedPercent: 90
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "weekly-ok", kind: .weeklyScoped, label: "Weekly OK"),
                usedPercent: 10
            )
        ]
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: windows,
            source: "test",
            lastRefreshed: Date(),
            message: "test"
        )

        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil
        )

        XCTAssertEqual(presentation.gauges.visible.map(\.id), ["session", "weekly-risk", "weekly-ok"])
    }

    func testAdviceHighlightsAndLabelsSwitch() {
        let profile = AccountProfile(provider: .codex, label: "Spare")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .idle,
            adviceReason: "More quota available"
        )

        XCTAssertEqual(presentation.switchTitle, "Best")
        XCTAssertEqual(presentation.switchHelp, "More quota available")
        XCTAssertTrue(presentation.highlightsSwitch)
    }

    func testElapsedResetHighlightsSwitchAndExplainsFreshQuota() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Recovered")
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: .claude,
            includedRemaining: 5,
            includedLimit: 100,
            resetDate: now.addingTimeInterval(-60),
            riskLevel: .warning,
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3600)
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            now: now
        )

        XCTAssertTrue(presentation.highlightsSwitch)
        XCTAssertTrue(presentation.switchHelp.contains("fresh quota"))
        XCTAssertEqual(presentation.footerNote?.tone, .success)
    }

    func testMissingCredentialsKeepsSwitchUnavailableAndExplainsLogin() {
        let profile = AccountProfile(provider: .codex, label: "New")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: false,
            refreshState: .idle,
            adviceReason: nil
        )

        XCTAssertFalse(presentation.highlightsSwitch)
        XCTAssertTrue(presentation.switchHelp.contains("Log into this account"))
        XCTAssertTrue(presentation.footerNote?.text.contains("terminal") == true)
    }

    func testActiveStaleAccountSurfacesStaleness() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: .claude,
            riskLevel: .stale,
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3600)
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            now: now
        )

        XCTAssertEqual(presentation.riskLevel, .stale)
        XCTAssertEqual(presentation.billingBadge?.text, "Sign in")
        XCTAssertTrue(presentation.footerNote?.text.hasPrefix("Last checked") == true)
    }

    func testPayAsYouGoSnapshotGetsDangerBadge() {
        let profile = AccountProfile(provider: .codex, label: "Overage")
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: .codex,
            riskLevel: .depleted,
            source: "test",
            payAsYouGoState: .enabledActive
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil
        )

        XCTAssertEqual(presentation.billingBadge?.text, "PAYG")
        XCTAssertEqual(presentation.billingBadge?.tone, .danger)
    }
}
