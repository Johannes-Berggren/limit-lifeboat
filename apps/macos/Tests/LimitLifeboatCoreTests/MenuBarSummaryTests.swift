import XCTest
@testable import LimitLifeboatCore

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
        XCTAssertEqual(summary.compactValue, "85%")
        XCTAssertEqual(
            summary.activeProviderLimits,
            [
                MenuBarProviderLimits(
                    provider: .claude,
                    limits: [
                        MenuBarLimitValue(label: "S", usedPercent: 25, riskLevel: .healthy),
                        MenuBarLimitValue(label: "W", usedPercent: 85, riskLevel: .warning)
                    ]
                )
            ]
        )
        XCTAssertEqual(summary.riskLevel, .warning)
        XCTAssertTrue(summary.accessibilityText.contains("Primary"))
        XCTAssertTrue(summary.accessibilityText.contains("Session 25 percent"))
        XCTAssertTrue(summary.accessibilityText.contains("Weekly 85 percent"))
    }

    func testScopedWeeklyStaysOutOfProviderValueButDrivesCompactStatus() {
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
        XCTAssertEqual(summary.compactValue, "100%")
        XCTAssertEqual(summary.riskLevel, .depleted)
        XCTAssertEqual(summary.activeProviderLimits[0].limits.map(\.label), ["S", "Fable"])
        XCTAssertTrue(summary.accessibilityText.contains("Fable"))
        XCTAssertTrue(summary.accessibilityText.contains("100 percent"))
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
        XCTAssertEqual(summary.compactValue, "100%")
        XCTAssertEqual(summary.riskLevel, .depleted)
        XCTAssertTrue(summary.accessibilityText.contains("pay as you go"))
    }

    func testCompactValuePrefersPrimaryWeeklyOverExhaustedScopedLimit() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 48
                ),
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly-all", kind: .weekly, label: "Weekly (all models)"),
                    usedPercent: 94
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

        XCTAssertEqual(summary.compactValue, "94%")
        XCTAssertEqual(summary.riskLevel, .warning)
        XCTAssertTrue(summary.accessibilityText.contains("Weekly (Fable) 100 percent"))
    }

    func testCompactValueKeepsSessionWhileWeeklyIsHealthy() {
        let now = Date(timeIntervalSince1970: 10_000)
        let profile = AccountProfile(provider: .claude, label: "Primary", isActiveCLI: true)
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 30
                ),
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly", kind: .weekly, label: "Weekly"),
                    usedPercent: 70
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

        XCTAssertEqual(summary.compactValue, "30%")
        XCTAssertEqual(summary.riskLevel, .healthy)
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
        XCTAssertEqual(
            missingSnapshot.activeProviderLimits,
            [MenuBarProviderLimits(provider: .claude, limits: [])]
        )
        XCTAssertTrue(noActive.activeProviderLimits.isEmpty)
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
        XCTAssertEqual(summary.compactValue, "20%")
        XCTAssertEqual(summary.riskLevel, .stale)
        XCTAssertEqual(summary.activeProviderLimits[0].limits[0].riskLevel, .stale)
    }

    func testCompactValueChoosesTightestWindowAcrossActiveProviders() {
        let now = Date(timeIntervalSince1970: 10_000)
        let claude = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let codex = AccountProfile(provider: .codex, label: "Codex", isActiveCLI: true)
        let claudeSnapshot = UsageSnapshotFactory.snapshot(
            accountID: claude.id,
            provider: .claude,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "weekly-model", kind: .weeklyScoped, label: "Model"),
                    usedPercent: 72
                )
            ],
            source: "test",
            lastRefreshed: now,
            message: "test"
        )
        let codexSnapshot = UsageSnapshotFactory.snapshot(
            accountID: codex.id,
            provider: .codex,
            windows: [
                UsageSnapshotFactory.window(
                    descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                    usedPercent: 91
                )
            ],
            source: "test",
            lastRefreshed: now,
            message: "test"
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [claude, codex],
            snapshots: [claude.id: claudeSnapshot, codex.id: codexSnapshot],
            now: now
        )

        XCTAssertEqual(summary.compactValue, "91%")
        XCTAssertEqual(summary.riskLevel, .warning)
        XCTAssertEqual(summary.activeProviderLimits.map(\.provider), [.claude, .codex])
        XCTAssertEqual(summary.activeProviderLimits[0].limits.map(\.usedPercent), [72])
        XCTAssertEqual(summary.activeProviderLimits[1].limits.map(\.usedPercent), [91])
    }

    func testCompactValueDistinguishesUnavailableFromNoActiveAccount() {
        let active = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let unavailable = MenuBarSummaryProjector.project(profiles: [active], snapshots: [:])
        XCTAssertEqual(unavailable.compactValue, "?")
        XCTAssertEqual(unavailable.riskLevel, .unknown)
        XCTAssertEqual(
            MenuBarSummaryProjector.project(profiles: [], snapshots: [:]).compactValue,
            "–"
        )
    }

    func testEqualCompactValuesUseProviderOrderDeterministically() {
        let now = Date(timeIntervalSince1970: 10_000)
        let claude = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let codex = AccountProfile(provider: .codex, label: "Codex", isActiveCLI: true)
        let descriptor = UsageWindowDescriptor(id: "session", kind: .session, label: "Session")
        let claudeSnapshot = UsageSnapshotFactory.snapshot(
            accountID: claude.id,
            provider: .claude,
            windows: [UsageSnapshotFactory.window(descriptor: descriptor, usedPercent: 80)],
            source: "test",
            lastRefreshed: now,
            message: "test"
        )
        let codexSnapshot = UsageSnapshotFactory.snapshot(
            accountID: codex.id,
            provider: .codex,
            windows: [UsageSnapshotFactory.window(descriptor: descriptor, usedPercent: 80)],
            source: "test",
            lastRefreshed: now.addingTimeInterval(-UsageThresholds.standard.staleAfter - 1),
            message: "test"
        )

        let summary = MenuBarSummaryProjector.project(
            profiles: [codex, claude],
            snapshots: [claude.id: claudeSnapshot, codex.id: codexSnapshot],
            now: now
        )

        XCTAssertEqual(summary.compactValue, "80%")
        XCTAssertEqual(summary.riskLevel, .warning)
    }
}
