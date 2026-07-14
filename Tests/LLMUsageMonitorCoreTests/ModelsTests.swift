import XCTest
@testable import LLMUsageMonitorCore

final class ModelsTests: XCTestCase {
    func testActiveAccountOrderingIsStableWithinGroups() {
        let inactiveOne = AccountProfile(provider: .claude, label: "Inactive One")
        let active = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let inactiveTwo = AccountProfile(provider: .claude, label: "Inactive Two")

        XCTAssertEqual(
            AccountProfileOrdering.activeFirst([inactiveOne, active, inactiveTwo]).map(\.id),
            [active.id, inactiveOne.id, inactiveTwo.id]
        )
    }

    func testProviderLoginCommandsMatchCurrentCLIs() {
        XCTAssertEqual(Provider.claude.loginCommand, "claude auth login")
        XCTAssertEqual(Provider.codex.loginCommand, "codex login")
    }

    func testCodexTerminalLoginLogsOutFirstWhenSessionExists() {
        XCTAssertEqual(Provider.codex.terminalLoginCommand(hasExistingSession: false), "codex login")
        XCTAssertEqual(
            Provider.codex.terminalLoginCommand(hasExistingSession: true),
            "codex logout; codex login"
        )
    }

    func testClaudeTerminalLoginIsUnaffectedByExistingSession() {
        XCTAssertEqual(Provider.claude.terminalLoginCommand(hasExistingSession: false), "claude auth login")
        XCTAssertEqual(Provider.claude.terminalLoginCommand(hasExistingSession: true), "claude auth login")
    }

    func testIdentitiesMatchOnAccountID() {
        let left = AccountIdentity(email: "left@example.com", accountID: "acct-1", source: .codexIDToken)
        let right = AccountIdentity(email: "right@example.com", accountID: "acct-1", source: .dashboard)
        XCTAssertTrue(left.matches(right))
    }

    func testIdentitiesMatchOnEmailCaseInsensitively() {
        let left = AccountIdentity(email: "User@Example.com", source: .dashboard)
        let right = AccountIdentity(email: "user@example.com", source: .claudeCodeUsage)
        XCTAssertTrue(left.matches(right))
    }

    func testDifferentAccountIDsDoNotMatchEvenWithSameEmailAbsent() {
        let left = AccountIdentity(displayName: "A", accountID: "acct-1", source: .codexIDToken)
        let right = AccountIdentity(displayName: "A", accountID: "acct-2", source: .codexIDToken)
        XCTAssertFalse(left.matches(right))
    }

    func testSameEmailAndAccountIDDifferentOrganizationsDoNotMatch() {
        let team = AccountIdentity(
            email: "user@example.com",
            organization: "Team",
            organizationID: "org-team",
            accountID: "acct-1",
            source: .claudeCodeUsage
        )
        let individual = AccountIdentity(
            email: "user@example.com",
            organization: "user@example.com's Organization",
            organizationID: "org-individual",
            accountID: "acct-1",
            source: .claudeCodeUsage
        )

        XCTAssertFalse(team.matches(individual))
    }

    func testSameAccountIDDifferentOrganizationNamesDoNotMatchWhenOrganizationIDsAreMissing() {
        let team = AccountIdentity(
            email: "user@example.com",
            organization: "Team",
            accountID: "acct-1",
            source: .claudeCodeUsage
        )
        let individual = AccountIdentity(
            email: "user@example.com",
            organization: "user@example.com's Organization",
            accountID: "acct-1",
            source: .claudeCodeUsage
        )

        XCTAssertFalse(team.matches(individual))
    }

    func testMatchingOrganizationAloneDoesNotMatch() {
        let left = AccountIdentity(email: "a@example.com", organization: "Acme", source: .dashboard)
        let right = AccountIdentity(email: "b@example.com", organization: "Acme", source: .dashboard)
        XCTAssertFalse(left.matches(right))
    }

    func testAccountProfileRoundTripsPlanLabel() throws {
        // Whole-second dates: appEncoder's ISO8601 drops fractional seconds,
        // so Date() would round-trip unequal by microseconds.
        let stamp = Date(timeIntervalSince1970: 1_783_000_000)
        let profile = AccountProfile(
            provider: .claude,
            label: "Personal",
            planLabel: "Max 20x",
            createdAt: stamp,
            updatedAt: stamp
        )

        let data = try JSONEncoder.appEncoder.encode(profile)
        let decoded = try JSONDecoder.appDecoder.decode(AccountProfile.self, from: data)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.planLabel, "Max 20x")
    }

    /// Profiles persisted before `planLabel` existed must still decode (with
    /// a nil plan) rather than throwing and wiping profiles.json on launch.
    func testDecodesLegacyProfileWithoutPlanLabelKey() throws {
        let id = UUID()
        let storeID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "provider": "claude",
          "label": "Personal",
          "webDataStoreKind": "isolated",
          "webDataStoreID": "\(storeID.uuidString)",
          "isActiveCLI": false,
          "createdAt": "2026-07-07T00:00:00Z",
          "updatedAt": "2026-07-07T00:00:00Z"
        }
        """

        let profile = try JSONDecoder.appDecoder.decode(AccountProfile.self, from: Data(json.utf8))

        XCTAssertNil(profile.planLabel)
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.label, "Personal")
        XCTAssertEqual(profile.webDataStoreID, storeID)
    }

    func testSnapshotStaleness() {
        let now = Date()
        let fresh = makeSnapshot(lastRefreshed: now.addingTimeInterval(-60))
        let old = makeSnapshot(lastRefreshed: now.addingTimeInterval(-3600))

        XCTAssertFalse(fresh.isStale(asOf: now))
        XCTAssertTrue(old.isStale(asOf: now))
    }

    func testResetHasElapsed() {
        let now = Date()
        let elapsed = makeSnapshot(lastRefreshed: now.addingTimeInterval(-7200), resetDate: now.addingTimeInterval(-60))
        let pending = makeSnapshot(lastRefreshed: now, resetDate: now.addingTimeInterval(3600))
        let unknown = makeSnapshot(lastRefreshed: now, resetDate: nil)

        XCTAssertTrue(elapsed.resetHasElapsed(asOf: now))
        XCTAssertFalse(pending.resetHasElapsed(asOf: now))
        XCTAssertFalse(unknown.resetHasElapsed(asOf: now))
    }

    /// `allWindowsResetElapsed` is stricter than the scalar `resetHasElapsed`:
    /// a short window rolling over while a weekly is still live must NOT read as
    /// "full quota back" — the quirk behind the over-optimistic Codex hint.
    func testAllWindowsResetElapsedRequiresEveryWindow() {
        let now = Date()
        let past = now.addingTimeInterval(-60)
        let future = now.addingTimeInterval(3600)

        let mixed = makeSnapshot(resetDate: past, windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 20, resetDate: past),
            makeWindow(id: "weekly", kind: .weekly, usedPercent: 90, resetDate: future)
        ])
        // The most-constrained scalar reset has passed, but a live weekly remains.
        XCTAssertTrue(mixed.resetHasElapsed(asOf: now))
        XCTAssertFalse(mixed.allWindowsResetElapsed(asOf: now))

        let allElapsed = makeSnapshot(resetDate: past, windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 20, resetDate: past),
            makeWindow(id: "weekly", kind: .weekly, usedPercent: 90, resetDate: past)
        ])
        XCTAssertTrue(allElapsed.allWindowsResetElapsed(asOf: now))
    }

    /// With no windows the method falls back to the snapshot-level reset date,
    /// so legacy scalar-only snapshots keep behaving as before.
    func testAllWindowsResetElapsedFallsBackToScalarWhenNoWindows() {
        let now = Date()
        let elapsed = makeSnapshot(resetDate: now.addingTimeInterval(-60))
        let pending = makeSnapshot(resetDate: now.addingTimeInterval(3600))

        XCTAssertTrue(elapsed.allWindowsResetElapsed(asOf: now))
        XCTAssertFalse(pending.allWindowsResetElapsed(asOf: now))
    }

    func testSnapshotWithWindowsRoundTrips() throws {
        let reset = Date(timeIntervalSince1970: 1_783_388_580)
        let original = UsageSnapshot(
            accountID: UUID(),
            provider: .codex,
            windows: [
                UsageWindow(id: "codex-300", kind: .session, label: "Session (5h)", usedPercent: 23,
                            resetDate: reset, resetDescription: "in 5h", windowMinutes: 300, riskLevel: .healthy),
                UsageWindow(id: "codex-10080", kind: .weekly, label: "Weekly (7d)", usedPercent: 86,
                            resetDate: reset, windowMinutes: 10080, riskLevel: .warning)
            ],
            includedRemaining: 14,
            includedLimit: 100,
            resetDate: reset,
            riskLevel: .warning,
            source: "test",
            lastRefreshed: Date(timeIntervalSince1970: 1_783_000_000),
            parseConfidence: .high,
            message: "m"
        )

        let data = try JSONEncoder.appEncoder.encode(original)
        let decoded = try JSONDecoder.appDecoder.decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// The load-bearing migration guarantee: snapshots persisted before
    /// `windows` existed must still decode (with an empty windows array) rather
    /// than throwing and wiping stored usage on first launch.
    func testDecodesLegacySnapshotWithoutWindowsKey() throws {
        let id = UUID()
        let json = """
        {
          "accountID": "\(id.uuidString)",
          "provider": "claude",
          "includedRemaining": 30,
          "includedLimit": 100,
          "resetDate": "2026-07-10T04:00:00Z",
          "resetDescription": "Jul 10",
          "riskLevel": "healthy",
          "source": "legacy",
          "lastRefreshed": "2026-07-07T00:00:00Z",
          "parseConfidence": "high",
          "message": "legacy"
        }
        """

        let snapshot = try JSONDecoder.appDecoder.decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.accountID, id)
        XCTAssertEqual(snapshot.includedRemaining, 30)
        XCTAssertEqual(snapshot.usedFraction, 0.7)
        XCTAssertEqual(snapshot.riskLevel, .healthy)
        // Legacy snapshots still surface a window for display/alerts via the fallback.
        XCTAssertEqual(snapshot.displayWindows.count, 1)
    }

    func testOrderedDisplayWindowsCollapsesDuplicateIDsKeepingLastOccurrence() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "weekly-all", kind: .weekly, usedPercent: 40),
            makeWindow(id: "session", kind: .session, usedPercent: 10),
            makeWindow(id: "weekly-all", kind: .weekly, usedPercent: 86)
        ])

        let ordered = snapshot.orderedDisplayWindows
        XCTAssertEqual(ordered.map(\.id), ["session", "weekly-all"])
        // The later capture wins: the stale 40% reading is dropped.
        XCTAssertEqual(ordered.last?.usedPercent, 86)
    }

    func testOrderedDisplayWindowsSortsSessionWeeklyScopedOther() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "extra", kind: .other),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped),
            makeWindow(id: "weekly-all", kind: .weekly),
            makeWindow(id: "session", kind: .session)
        ])

        XCTAssertEqual(
            snapshot.orderedDisplayWindows.map(\.kind),
            [.session, .weekly, .weeklyScoped, .other]
        )
    }

    func testOrderedDisplayWindowsTieBreaksOnLabelWithinAKind() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, label: "Week (Fable)"),
            makeWindow(id: "weekly-all", kind: .weeklyScoped, label: "Week (All)")
        ])

        XCTAssertEqual(snapshot.orderedDisplayWindows.map(\.id), ["weekly-all", "weekly-fable"])
    }

    /// Legacy scalar-only snapshots (no windows, just includedRemaining/Limit)
    /// still surface their synthesized fallback window through the ordered API.
    func testOrderedDisplayWindowsSynthesizesWindowForLegacyScalarSnapshot() {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            includedRemaining: 30,
            includedLimit: 100,
            riskLevel: .healthy,
            source: "legacy",
            parseConfidence: .high
        )

        let ordered = snapshot.orderedDisplayWindows
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ordered.first?.id, "primary")
        XCTAssertEqual(ordered.first?.kind, .other)
        XCTAssertEqual(ordered.first?.usedPercent ?? 0, 70, accuracy: 0.0001)
    }

    func testOrderedDisplayWindowsEmptyWhenNoWindowsAndNoScalars() {
        XCTAssertTrue(makeSnapshot().orderedDisplayWindows.isEmpty)
    }

    func testWindowOfKindReturnsFirstMatchInDisplayOrder() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, label: "Week (Fable)", usedPercent: 12),
            makeWindow(id: "session", kind: .session, usedPercent: 40),
            makeWindow(id: "weekly-all", kind: .weeklyScoped, label: "Week (All)", usedPercent: 55)
        ])

        XCTAssertEqual(snapshot.window(ofKind: .session)?.id, "session")
        // Two weeklyScoped windows: the first in display order (label tie-break) wins.
        XCTAssertEqual(snapshot.window(ofKind: .weeklyScoped)?.id, "weekly-all")
        XCTAssertNil(snapshot.window(ofKind: .weekly))
    }

    func testPrimaryWeeklyWindowPrefersWeeklyThenFallsBackToScoped() {
        let both = makeSnapshot(windows: [
            makeWindow(id: "weekly-fable", kind: .weeklyScoped),
            makeWindow(id: "weekly-all", kind: .weekly)
        ])
        XCTAssertEqual(both.primaryWeeklyWindow?.id, "weekly-all")

        let scopedOnly = makeSnapshot(windows: [
            makeWindow(id: "session", kind: .session),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped)
        ])
        XCTAssertEqual(scopedOnly.primaryWeeklyWindow?.id, "weekly-fable")

        XCTAssertNil(makeSnapshot(windows: [makeWindow(id: "session", kind: .session)]).primaryWeeklyWindow)
    }

    /// Window-id slugs are a contract between the TUI parser and the usage
    /// API client: alert dedupe keys must survive flipping between sources,
    /// so the shared slug behavior is pinned here.
    func testUsageWindowIDSlug() {
        XCTAssertEqual(UsageWindowID.slug("Fable"), "fable")
        XCTAssertEqual(UsageWindowID.slug("All Models"), "all-models")
        XCTAssertEqual(UsageWindowID.slug(""), "window")
    }

    func testFlexibleISO8601ParsesWithAndWithoutFractionalSeconds() throws {
        XCTAssertEqual(
            FlexibleISO8601.date(from: "2026-07-13T06:00:00+00:00"),
            Date(timeIntervalSince1970: 1_783_922_400)
        )
        let fractional = try XCTUnwrap(FlexibleISO8601.date(from: "2026-07-08T00:49:59.940321+00:00"))
        XCTAssertEqual(fractional.timeIntervalSince1970, 1_783_471_799.940321, accuracy: 0.01)
        XCTAssertNil(FlexibleISO8601.date(from: "not a date"))
    }

    func testDurationPhraseShortRoundsUpThroughTiers() {
        XCTAssertEqual(DurationPhrase.short(0), "1m")
        XCTAssertEqual(DurationPhrase.short(-30), "1m")
        XCTAssertEqual(DurationPhrase.short(59 * 60), "59m")
        XCTAssertEqual(DurationPhrase.short(59 * 60 + 1), "1h")
        XCTAssertEqual(DurationPhrase.short(3 * 3_600), "3h")
        XCTAssertEqual(DurationPhrase.short(47 * 3_600), "47h")
        XCTAssertEqual(DurationPhrase.short(47 * 3_600 + 1), "2d")
        XCTAssertEqual(DurationPhrase.short(5 * 24 * 3_600), "5d")
    }

    func testUsageResetTimingFormatsFutureDatesAcrossDurationTiers() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)

        XCTAssertEqual(
            UsageResetTiming.compactText(resetDate: now.addingTimeInterval(3 * 60), resetDescription: nil, now: now),
            "Resets in 3m"
        )
        XCTAssertEqual(
            UsageResetTiming.compactText(resetDate: now.addingTimeInterval(3 * 3_600), resetDescription: nil, now: now),
            "Resets in 3h"
        )
        XCTAssertEqual(
            UsageResetTiming.compactText(resetDate: now.addingTimeInterval(3 * 24 * 3_600), resetDescription: nil, now: now),
            "Resets in 3d"
        )
    }

    func testUsageResetTimingMarksElapsedDateAndPrefersItOverProviderText() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)

        XCTAssertEqual(
            UsageResetTiming.compactText(
                resetDate: now.addingTimeInterval(-1),
                resetDescription: "tomorrow",
                now: now
            ),
            "Reset passed"
        )
    }

    func testUsageResetTimingNormalizesProviderTextFallback() {
        XCTAssertEqual(
            UsageResetTiming.compactText(resetDate: nil, resetDescription: " in 5h "),
            "Resets in 5h"
        )
        XCTAssertEqual(
            UsageResetTiming.compactText(resetDate: nil, resetDescription: "resets Tuesday"),
            "Resets Tuesday"
        )
        XCTAssertNil(UsageResetTiming.compactText(resetDate: nil, resetDescription: "  "))
        XCTAssertNil(UsageResetTiming.compactText(resetDate: nil, resetDescription: nil))
    }

    func testMostConstrainedWindowPicksHighestUsedPercent() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 23),
            makeWindow(id: "weekly-all", kind: .weekly, usedPercent: 86),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, usedPercent: 51)
        ])

        XCTAssertEqual(snapshot.mostConstrainedWindow?.id, "weekly-all")
        XCTAssertNil(makeSnapshot().mostConstrainedWindow)
    }

    func testPrimaryLimitsExcludeScopedWeekly() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 3, riskLevel: .healthy),
            makeWindow(id: "weekly-all", kind: .weekly, usedPercent: 12, riskLevel: .healthy),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, usedPercent: 100, riskLevel: .depleted)
        ])

        XCTAssertEqual(snapshot.primaryLimitWindows.map(\.id), ["session", "weekly-all"])
        XCTAssertEqual(snapshot.primaryConstrainedWindow?.id, "weekly-all")
    }

    func testPrimaryWeeklyDoesNotFallBackToScopedWeekly() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 3, riskLevel: .healthy),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, usedPercent: 22, riskLevel: .warning)
        ])

        XCTAssertEqual(snapshot.primaryLimitWindows.map(\.id), ["session"])
        XCTAssertEqual(snapshot.primaryConstrainedWindow?.id, "session")
    }

    // MARK: - billingUsageMode

    /// An explicit `.enabledActive` from the API overrides the used-fraction
    /// bands: even a low-utilization reading is "over limit, paying" when the
    /// account has exhausted included usage onto credits.
    func testBillingModeEnabledActiveOverridesUsedFractionBands() {
        let snapshot = makeBillingSnapshot(payState: .enabledActive, usedFraction: 0.2)
        XCTAssertEqual(snapshot.billingUsageMode, .overLimitPayAsYouGo)
    }

    /// Overage merely *enabled* as a backstop (`.enabledIdle`) while included
    /// usage is fine must NOT alarm — it reads as a normal included
    /// subscription, not pay-as-you-go. (Regression guard for the false
    /// "Pay as you go" badge on healthy accounts.)
    func testBillingModeEnabledIdleReadsAsIncludedSubscription() {
        XCTAssertEqual(makeBillingSnapshot(payState: .enabledIdle, usedFraction: 0.3).billingUsageMode,
                       .includedSubscription)
        XCTAssertEqual(makeBillingSnapshot(payState: .enabledIdle, usedFraction: 0.9).billingUsageMode,
                       .includedSubscriptionNearLimit)
    }

    /// `.disabled` (overage explicitly off) falls through to the used-fraction
    /// bands exactly as before.
    func testBillingModeDisabledFallsBackToUsedFractionBands() {
        XCTAssertEqual(makeBillingSnapshot(payState: .disabled, usedFraction: 0.9).billingUsageMode,
                       .includedSubscriptionNearLimit)
        XCTAssertEqual(makeBillingSnapshot(payState: .disabled, usedFraction: 0.4).billingUsageMode,
                       .includedSubscription)
    }

    /// A nil state (TUI / dashboard / legacy) keeps the pre-existing string-scan
    /// behavior — nothing regresses for sources that can't report the block.
    func testBillingModeNilStateUsesStringScanFallback() {
        let payg = makeBillingSnapshot(payState: nil, usedFraction: nil,
                                       creditStatus: "You are on pay-as-you-go credits.",
                                       riskLevel: .depleted)
        XCTAssertEqual(payg.billingUsageMode, .overLimitPayAsYouGo)

        let included = makeBillingSnapshot(payState: nil, usedFraction: 0.5)
        XCTAssertEqual(included.billingUsageMode, .includedSubscription)
    }

    func testBillingModeStaleShortCircuitsToNeedsLogin() {
        let snapshot = makeBillingSnapshot(payState: .enabledActive, usedFraction: 0.2, riskLevel: .stale)
        XCTAssertEqual(snapshot.billingUsageMode, .needsLogin)
    }

    private func makeBillingSnapshot(
        payState: PayAsYouGoState?,
        usedFraction: Double?,
        creditStatus: String? = nil,
        riskLevel: RiskLevel = .healthy
    ) -> UsageSnapshot {
        // usedFraction is derived from includedRemaining/includedLimit, so map
        // the requested fraction back onto those scalar fields.
        let includedRemaining = usedFraction.map { (1 - $0) * 100 }
        return UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            includedRemaining: includedRemaining,
            includedLimit: includedRemaining == nil ? nil : 100,
            creditStatus: creditStatus,
            riskLevel: riskLevel,
            source: "test",
            payAsYouGoState: payState
        )
    }

    private func makeSnapshot(
        lastRefreshed: Date = Date(),
        resetDate: Date? = nil,
        windows: [UsageWindow] = []
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: windows,
            resetDate: resetDate,
            riskLevel: .healthy,
            source: "test",
            lastRefreshed: lastRefreshed,
            parseConfidence: .high
        )
    }

    private func makeWindow(
        id: String,
        kind: UsageWindowKind,
        label: String? = nil,
        usedPercent: Double = 0,
        resetDate: Date? = nil,
        riskLevel: RiskLevel = .unknown
    ) -> UsageWindow {
        UsageWindow(id: id, kind: kind, label: label ?? id, usedPercent: usedPercent, resetDate: resetDate, riskLevel: riskLevel)
    }
}
