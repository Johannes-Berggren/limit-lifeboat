import XCTest
@testable import LimitLifeboatCore

final class AccountRowPresentationTests: XCTestCase {
    func testIdentityTextShowsOrganizationByDefault() {
        let profile = AccountProfile(
            provider: .claude,
            label: "Work",
            planLabel: "Team",
            identity: AccountIdentity(
                email: "person@example.com",
                organization: "Acme",
                source: .claudeCodeUsage
            )
        )

        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .idle,
            adviceReason: nil
        )

        XCTAssertEqual(presentation.identityText, "person@example.com • Acme • Team")
    }

    func testIdentityTextCanHideOrganizationWithoutHidingPrimaryIdentityOrPlan() {
        let profile = AccountProfile(
            provider: .claude,
            label: "Work",
            planLabel: "Team",
            identity: AccountIdentity(
                email: "person@example.com",
                organization: "Acme",
                source: .claudeCodeUsage
            )
        )

        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .idle,
            adviceReason: nil,
            showOrganizationName: false
        )

        XCTAssertEqual(presentation.identityText, "person@example.com • Team")
    }

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
        XCTAssertEqual(presentation.refreshProblem?.action, .retry)
        XCTAssertNotNil(presentation.footerNote)
    }

    func testUsagePausedShowsCalmRefreshAffordanceAndKeepsSwitchHealthy() {
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .usagePaused,
            adviceReason: nil
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Usage paused — click to refresh")
        XCTAssertEqual(presentation.refreshProblem?.icon, "pause.circle")
        XCTAssertEqual(presentation.refreshProblem?.tone, .secondary)
        XCTAssertEqual(presentation.refreshProblem?.action, .retry)
        // Unlike .needsLogin, a paused login is not treated as expired: its
        // switch help stays the healthy copy, not "log in again".
        XCTAssertNotEqual(
            presentation.switchHelp,
            "Log in to this account again before switching the CLI to it"
        )
    }

    func testEveryWindowRemainsVisibleInStableDisplayOrder() {
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let windows = [
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "other", kind: .other, label: "Other"),
                usedPercent: 5
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "weekly-zeta", kind: .weeklyScoped, label: "Weekly Zeta"),
                usedPercent: 90
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
                usedPercent: 20
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "weekly-all", kind: .weekly, label: "Weekly"),
                usedPercent: 80
            ),
            UsageSnapshotFactory.window(
                descriptor: UsageWindowDescriptor(id: "weekly-alpha", kind: .weeklyScoped, label: "Weekly Alpha"),
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

        XCTAssertEqual(
            presentation.gauges.visible.map(\.id),
            ["session", "weekly-all", "weekly-alpha", "weekly-zeta", "other"]
        )
    }

    func testActiveAndInactiveProfilesExposeTheSameVisibleGauges() {
        let windows = [
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
        ]
        func presentation(isActiveCLI: Bool) -> AccountRowPresentation {
            let profile = AccountProfile(
                provider: .claude,
                label: isActiveCLI ? "Active" : "Inactive",
                isActiveCLI: isActiveCLI
            )
            let snapshot = UsageSnapshotFactory.snapshot(
                accountID: profile.id,
                provider: .claude,
                windows: windows,
                source: "test",
                lastRefreshed: Date(),
                message: "test"
            )
            return AccountRowPresentation(
                profile: profile,
                snapshot: snapshot,
                hasStoredSnapshot: true,
                refreshState: .ok,
                adviceReason: nil
            )
        }

        let activeIDs = presentation(isActiveCLI: true).gauges.visible.map(\.id)
        let inactiveIDs = presentation(isActiveCLI: false).gauges.visible.map(\.id)

        XCTAssertEqual(activeIDs, ["session", "weekly-all", "weekly-fable"])
        XCTAssertEqual(inactiveIDs, activeIDs)
    }

    func testExceptionalGaugeNotesRemainProfileSpecific() {
        let now = Date()
        let window = UsageSnapshotFactory.window(
            descriptor: UsageWindowDescriptor(id: "weekly-all", kind: .weekly, label: "Weekly"),
            usedPercent: 40,
            resetDate: now.addingTimeInterval(-60)
        )
        func presentation(isActiveCLI: Bool) -> AccountRowPresentation {
            let profile = AccountProfile(
                provider: .claude,
                label: isActiveCLI ? "Active" : "Inactive",
                isActiveCLI: isActiveCLI
            )
            let snapshot = UsageSnapshotFactory.snapshot(
                accountID: profile.id,
                provider: .claude,
                windows: [window],
                source: "test",
                lastRefreshed: now,
                message: "test"
            )
            return AccountRowPresentation(
                profile: profile,
                snapshot: snapshot,
                hasStoredSnapshot: true,
                refreshState: .ok,
                adviceReason: nil,
                now: now
            )
        }

        let active = presentation(isActiveCLI: true).gauges
        XCTAssertTrue(active.needsSessionCaptureNote)
        XCTAssertFalse(active.showsPreResetNote)

        let inactive = presentation(isActiveCLI: false).gauges
        XCTAssertFalse(inactive.needsSessionCaptureNote)
        XCTAssertTrue(inactive.showsPreResetNote)
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
        XCTAssertTrue(presentation.switchHelp.contains("Log in to this account"))
        XCTAssertTrue(presentation.footerNote?.text.contains("terminal") == true)
    }

    func testSavedInactiveCodexAccountPromisesNextRefreshWithoutRequiringSwitch() {
        let profile = AccountProfile(provider: .codex, label: "Saved")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .idle,
            adviceReason: nil
        )

        XCTAssertEqual(
            presentation.footerNote?.text,
            "Credentials saved — usage appears on the next refresh"
        )
    }

    func testElapsedInactiveCodexReadingOffersLiveRefresh() {
        let now = Date()
        let profile = AccountProfile(provider: .codex, label: "Saved")
        let window = UsageSnapshotFactory.window(
            descriptor: UsageWindowDescriptor(id: "codex-10080", kind: .weekly, label: "Weekly"),
            usedPercent: 80,
            resetDate: now.addingTimeInterval(-60)
        )
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .codex,
            windows: [window],
            source: "test",
            lastRefreshed: now.addingTimeInterval(-3600),
            message: "test"
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            now: now
        )

        XCTAssertEqual(presentation.footerNote?.text, "Reset window passed — refresh to confirm")
        XCTAssertTrue(presentation.footerNote?.help.contains("Refresh usage") == true)
        XCTAssertFalse(presentation.footerNote?.help.contains("run codex") == true)
    }

    func testExpiredLoginShowsDirectLoginActionAndDoesNotHighlightSwitch() {
        let profile = AccountProfile(
            provider: .codex,
            label: "Expired",
            identity: AccountIdentity(email: "user@example.com", source: .codexIDToken)
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .needsLogin(reason: "Refresh token rejected"),
            adviceReason: "More quota available"
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Login expired — sign in again")
        XCTAssertEqual(presentation.refreshProblem?.action, .login)
        XCTAssertFalse(presentation.highlightsSwitch)
    }

    func testClaudeLoginWithinFiveDaysOffersPerMacRenewal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(4.2 * 24 * 60 * 60),
            now: now
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Login expires in 5 days")
        XCTAssertEqual(presentation.refreshProblem?.action, .renew)
        XCTAssertEqual(presentation.refreshProblem?.action.title, "Renew")
        XCTAssertTrue(presentation.refreshProblem?.help.contains("this Mac only") == true)
        XCTAssertTrue(presentation.renewalActivatesAccount)
    }

    func testInactiveClaudeRenewalPreservesCurrentCLIAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            now: now
        )

        XCTAssertEqual(presentation.refreshProblem?.action, .renew)
        XCTAssertFalse(presentation.renewalActivatesAccount)
    }

    func testExpiringLoginAndPausedUsageExposeRenewThenRetry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude", isActiveCLI: true)
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .rotationDeferred(reason: "Scheduled refresh cannot rotate."),
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            now: now
        )

        XCTAssertEqual(presentation.rowMessages.map(\.action), [.renew, .retry])
        XCTAssertEqual(presentation.refreshProblem?.action, .renew)
        XCTAssertTrue(presentation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(presentation.automaticSwitchEligibility.isEligible)
    }

    func testSharedExpiringLoginOffersSwitchInsteadOfImpossibleRetry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Shared")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .switchRequired(reason: "Shared with the active login."),
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            now: now
        )

        XCTAssertEqual(presentation.rowMessages.count, 1)
        XCTAssertEqual(presentation.refreshProblem?.action, .switchCLI)
        XCTAssertTrue(presentation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(presentation.automaticSwitchEligibility.isEligible)
    }

    func testUnreadableCredentialSuppressesCachedExpiredLogin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            storedCredentialAvailability: .authorizationRequired(source: .claudeCode),
            refreshState: .ok,
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(-60),
            now: now
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Keychain access needed")
        XCTAssertEqual(presentation.refreshProblem?.action, .authorize(source: .claudeCode))
        XCTAssertFalse(presentation.highlightsSwitch)
    }

    func testClaudeLoginBeyondFiveDaysDoesNotShowRenewal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            loginExpiresAt: now.addingTimeInterval(5 * 24 * 60 * 60 + 1),
            now: now
        )

        XCTAssertNil(presentation.refreshProblem)
    }

    func testMetadataExpiredClaudeLoginRequiresLoginAndDisablesSwitchHighlight() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: "More quota available",
            loginExpiresAt: now,
            now: now
        )

        XCTAssertEqual(presentation.refreshProblem?.text, "Login expired — sign in again")
        XCTAssertEqual(presentation.refreshProblem?.action, .login)
        XCTAssertFalse(presentation.highlightsSwitch)
    }

    func testCodexIgnoresClaudeLoginExpiryMetadata() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AccountProfile(provider: .codex, label: "Codex")
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: nil,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            loginExpiresAt: now,
            now: now
        )

        XCTAssertNil(presentation.refreshProblem)
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
        XCTAssertTrue(presentation.billingBadge?.help.contains("extra usage may be billed") == true)
    }

    func testPayAsYouGoBadgeHelpEmbedsSpendWhenReported() {
        let profile = AccountProfile(provider: .claude, label: "Overage")
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: .claude,
            riskLevel: .depleted,
            source: "test",
            payAsYouGoState: .enabledActive,
            payAsYouGoSpend: PayAsYouGoSpend(monthlyLimit: 50, usedCredits: 12.5)
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil
        )

        XCTAssertEqual(
            presentation.billingBadge?.help,
            "Included usage appears depleted — $12.50 of $50 extra usage this month. Click for details."
        )
    }

    // MARK: - Pace forecast

    private func paceSnapshot(
        profile: AccountProfile,
        windows: [UsageWindow],
        lastRefreshed: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            windows: windows,
            riskLevel: .warning,
            source: "test",
            lastRefreshed: lastRefreshed,
            parseConfidence: .high
        )
    }

    func testPaceForecastPicksEarliestDepletion() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let reset = now.addingTimeInterval(4 * 24 * 3600)
        let windows = [
            UsageWindow(id: "session", kind: .session, label: "Session (5h)", usedPercent: 60,
                        resetDate: now.addingTimeInterval(2 * 3600), riskLevel: .healthy),
            UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly (all models)", usedPercent: 80,
                        resetDate: reset, riskLevel: .warning)
        ]
        let sessionDepletion = now.addingTimeInterval(90 * 60)
        let weeklyDepletion = now.addingTimeInterval(2 * 24 * 3600)
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: [
                "session": .depletesAt(sessionDepletion),
                "weekly-all": .depletesAt(weeklyDepletion)
            ],
            now: now
        )

        XCTAssertEqual(presentation.paceForecast?.windowID, "session")
        XCTAssertEqual(presentation.paceForecast?.depletesAt, sessionDepletion)
    }

    func testPaceForecastSuppressedForStaleSnapshot() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let windows = [
            UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly", usedPercent: 80,
                        resetDate: now.addingTimeInterval(24 * 3600), riskLevel: .warning)
        ]
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now.addingTimeInterval(-3600)),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(3600))],
            now: now
        )

        XCTAssertNil(presentation.paceForecast)
    }

    func testPaceForecastSuppressedWhenAllWindowsResetElapsed() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Inactive")
        let windows = [
            UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly", usedPercent: 80,
                        resetDate: now.addingTimeInterval(-60), riskLevel: .warning)
        ]
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: ["weekly-all": .depletesAt(now.addingTimeInterval(3600))],
            now: now
        )

        XCTAssertNil(presentation.paceForecast)
    }

    /// Without a reset bound the estimator can project weeks out — the card
    /// line only claims imminent (24h) depletion for reset-less windows.
    func testPaceForecastCapsResetlessWindowsToOneDayHorizon() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let windows = [
            UsageWindow(id: "primary", kind: .other, label: "Quota", usedPercent: 55, riskLevel: .healthy)
        ]
        let farOut = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: ["primary": .depletesAt(now.addingTimeInterval(3 * 24 * 3600))],
            now: now
        )
        XCTAssertNil(farOut.paceForecast)

        let imminent = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: ["primary": .depletesAt(now.addingTimeInterval(3600))],
            now: now
        )
        XCTAssertEqual(imminent.paceForecast?.windowID, "primary")
    }

    func testPaceForecastIgnoresSafeAndInsufficientEstimates() {
        let now = Date()
        let profile = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let windows = [
            UsageWindow(id: "session", kind: .session, label: "Session", usedPercent: 30,
                        resetDate: now.addingTimeInterval(3600), riskLevel: .healthy),
            UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly", usedPercent: 20,
                        resetDate: now.addingTimeInterval(24 * 3600), riskLevel: .healthy)
        ]
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: paceSnapshot(profile: profile, windows: windows, lastRefreshed: now),
            hasStoredSnapshot: true,
            refreshState: .ok,
            adviceReason: nil,
            estimates: ["session": .safe, "weekly-all": .insufficientData],
            now: now
        )

        XCTAssertNil(presentation.paceForecast)
    }
}
