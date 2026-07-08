import XCTest
@testable import LLMUsageMonitorCore

final class ModelsTests: XCTestCase {
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

    func testMatchingOrganizationAloneDoesNotMatch() {
        let left = AccountIdentity(email: "a@example.com", organization: "Acme", source: .dashboard)
        let right = AccountIdentity(email: "b@example.com", organization: "Acme", source: .dashboard)
        XCTAssertFalse(left.matches(right))
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

    func testMostConstrainedWindowPicksHighestUsedPercent() {
        let snapshot = makeSnapshot(windows: [
            makeWindow(id: "session", kind: .session, usedPercent: 23),
            makeWindow(id: "weekly-all", kind: .weekly, usedPercent: 86),
            makeWindow(id: "weekly-fable", kind: .weeklyScoped, usedPercent: 51)
        ])

        XCTAssertEqual(snapshot.mostConstrainedWindow?.id, "weekly-all")
        XCTAssertNil(makeSnapshot().mostConstrainedWindow)
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
        usedPercent: Double = 0
    ) -> UsageWindow {
        UsageWindow(id: id, kind: kind, label: label ?? id, usedPercent: usedPercent)
    }
}
