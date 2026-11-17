import XCTest
@testable import LimitLifeboatCore

final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(
        _ profile: AccountProfile,
        windows: [UsageWindow],
        refreshedAgo: TimeInterval = 60,
        refreshState: AccountRefreshState = .idle,
        readings: [String: [BurnRateEstimator.Reading]] = [:],
        estimates: [String: BurnRateEstimate] = [:]
    ) -> WidgetSnapshotBuilder.AccountInput {
        let snapshot = UsageSnapshot(
            accountID: profile.id,
            provider: profile.provider,
            windows: windows,
            source: "test",
            lastRefreshed: now.addingTimeInterval(-refreshedAgo)
        )
        let presentation = AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: true,
            refreshState: refreshState,
            adviceReason: nil,
            estimates: estimates,
            now: now
        )
        return WidgetSnapshotBuilder.AccountInput(
            profile: profile,
            snapshot: snapshot,
            presentation: presentation,
            readings: readings,
            estimates: estimates
        )
    }

    private func session(_ used: Double, resetIn: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(id: "session", kind: .session, label: "Current session", usedPercent: used, resetDate: now.addingTimeInterval(resetIn), windowMinutes: 300, riskLevel: .healthy)
    }

    private func weekly(_ used: Double) -> UsageWindow {
        UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly (all models)", usedPercent: used, resetDate: now.addingTimeInterval(86_400), windowMinutes: 10_080, riskLevel: .healthy)
    }

    func testGroupsByProviderWithActiveAccountFirstInPriorityOrder() {
        let codex = AccountProfile(provider: .codex, label: "Codex", isActiveCLI: true)
        let first = AccountProfile(provider: .claude, label: "First")
        let active = AccountProfile(provider: .claude, label: "Active", isActiveCLI: true)
        let third = AccountProfile(provider: .claude, label: "Third")

        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [codex, first, active, third].map { input($0, windows: [session(10)]) },
            bestNextIDs: [.claude: third.id],
            showsUsageCurves: true,
            now: now
        )

        XCTAssertEqual(snapshot.accounts.map(\.label), ["Active", "First", "Third", "Codex"])
        XCTAssertEqual(snapshot.headlineAccount?.label, "Active")
        XCTAssertEqual(snapshot.bestNext(for: .claude)?.label, "Third")
        XCTAssertNil(snapshot.bestNext(for: .codex))
    }

    func testCarriesOnlyDisplayDataAndNeverTheLoginIdentity() throws {
        let profile = AccountProfile(
            provider: .claude,
            label: "Work",
            planLabel: "Max 20x",
            identity: AccountIdentity(email: "person@example.com", organization: "Acme", source: .claudeCodeUsage),
            isActiveCLI: true
        )
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(25), weekly(40)])],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        let json = String(decoding: try JSONEncoder.appEncoder.encode(snapshot), as: UTF8.self)

        XCTAssertFalse(json.contains("person@example.com"))
        XCTAssertFalse(json.contains("Acme"))
        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.planLabel, "Max 20x")
        XCTAssertEqual(account.sessionWindow?.label, "Session")
        XCTAssertEqual(account.sessionWindow?.remainingPercent, 75)
        XCTAssertEqual(account.weeklyWindow?.label, "Week")
    }

    func testStaleReadingsAreMarkedStale() throws {
        let profile = AccountProfile(provider: .claude, label: "Old", isActiveCLI: true)
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(25)], refreshedAgo: 2 * 3600)],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.sessionWindow?.riskLevel, .stale)
        XCTAssertTrue(account.isStale(asOf: now))
        XCTAssertFalse(WidgetAccount(id: UUID(), provider: .claude, label: "x", isActive: false, lastRefreshed: now).isStale(asOf: now))
    }

    func testRiskFollowsTheWarningThresholdEvenWhenTheProviderSaysHealthy() throws {
        let profile = AccountProfile(provider: .claude, label: "Busy", isActiveCLI: true)
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(85), weekly(100)])],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        let account = try XCTUnwrap(snapshot.accounts.first)
        XCTAssertEqual(account.sessionWindow?.riskLevel, .warning)
        XCTAssertEqual(account.weeklyWindow?.riskLevel, .depleted)
        // The tighter window leads once either is in the warning band.
        XCTAssertEqual(account.headlineWindow?.id, "weekly-all")
    }

    func testHeadlineIsTheSessionWhileBothAreHealthy() throws {
        let profile = AccountProfile(provider: .claude, label: "Calm", isActiveCLI: true)
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(20), weekly(60)])],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        XCTAssertEqual(snapshot.accounts.first?.headlineWindow?.id, "session")
    }

    func testRefreshProblemBecomesTheNote() throws {
        let profile = AccountProfile(provider: .claude, label: "Broken", isActiveCLI: true)
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(20)], refreshState: .needsLogin(reason: "Signed out"))],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        let note = try XCTUnwrap(snapshot.accounts.first?.note)
        XCTAssertFalse(note.text.isEmpty)
        XCTAssertNotEqual(note.tone, .success)
    }

    func testPaceForecastUsesTheShortWindowLabel() throws {
        let profile = AccountProfile(provider: .claude, label: "Fast", isActiveCLI: true)
        let snapshot = WidgetSnapshotBuilder.build(
            accounts: [input(
                profile,
                windows: [session(60, resetIn: 4 * 3600)],
                estimates: ["session": .depletesAt(now.addingTimeInterval(2 * 3600))]
            )],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        XCTAssertEqual(snapshot.accounts.first?.note, WidgetNote(text: "Session empty in 2h", tone: .warning))
    }

    func testRunwaysFollowTheUsageCurvesSetting() throws {
        let profile = AccountProfile(provider: .claude, label: "Curvy", isActiveCLI: true)
        let readings: [String: [BurnRateEstimator.Reading]] = [
            "session": [
                BurnRateEstimator.Reading(timestamp: now.addingTimeInterval(-3000), usedPercent: 10, resetDate: now.addingTimeInterval(3600)),
                BurnRateEstimator.Reading(timestamp: now.addingTimeInterval(-600), usedPercent: 30, resetDate: now.addingTimeInterval(3600))
            ]
        ]
        let withCurves = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(35)], readings: readings)],
            bestNextIDs: [:],
            showsUsageCurves: true,
            now: now
        )
        let withoutCurves = WidgetSnapshotBuilder.build(
            accounts: [input(profile, windows: [session(35)], readings: readings)],
            bestNextIDs: [:],
            showsUsageCurves: false,
            now: now
        )
        XCTAssertNotNil(withCurves.accounts.first?.sessionWindow?.runway)
        XCTAssertNil(withoutCurves.accounts.first?.sessionWindow?.runway)
        XCTAssertFalse(withoutCurves.showsUsageCurves)
    }

    func testScopedWeeklyLabelUsesTheModelName() {
        let window = UsageWindow(id: "weekly-fable", kind: .weeklyScoped, label: "Weekly (fable)", usedPercent: 5)
        XCTAssertEqual(WidgetSnapshotBuilder.shortLabel(for: window), "Fable")
    }

    func testWindowPastItsResetIsReportedAsElapsed() {
        let window = WidgetWindow(id: "session", kind: .session, label: "Session", usedPercent: 90, resetDate: now.addingTimeInterval(-1), riskLevel: .warning)
        XCTAssertTrue(window.resetHasElapsed(asOf: now))
        XCTAssertFalse(window.resetHasElapsed(asOf: now.addingTimeInterval(-10)))
    }

    func testStoreRoundTripsInItsOwnPrivateDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WidgetSnapshotStore(applicationSupportDirectory: root)
        XCTAssertNil(store.read())

        let snapshot = WidgetSnapshot(
            generatedAt: now,
            accounts: [WidgetAccount(id: UUID(), provider: .codex, label: "Codex", isActive: true, lastRefreshed: now, windows: [
                WidgetWindow(id: "codex-10080", kind: .weekly, label: "Week", usedPercent: 12, resetDate: now, riskLevel: .healthy,
                             runway: UsageRunway(history: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.12)], nowX: 0.5))
            ])]
        )
        try store.write(snapshot)

        XCTAssertEqual(store.url.deletingLastPathComponent().lastPathComponent, WidgetSnapshot.directoryName)
        XCTAssertEqual(store.read(), snapshot)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
    }

    func testNewerSnapshotVersionsAreIgnoredRatherThanMisread() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WidgetSnapshotStore(applicationSupportDirectory: root)
        try store.write(WidgetSnapshot(version: WidgetSnapshot.currentVersion + 1, generatedAt: now, accounts: []))
        XCTAssertNil(store.read())
    }

    func testRealApplicationSupportDirectoryIsUnderTheUsersHome() throws {
        let url = try XCTUnwrap(WidgetSnapshotStore.realApplicationSupportDirectory(named: "LimitLifeboat"))
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/LimitLifeboat"))
        XCTAssertFalse(url.path.contains("/Containers/"))
    }
}

final class WidgetResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func text(_ seconds: TimeInterval) -> String? {
        WidgetResetCountdown.text(until: now.addingTimeInterval(seconds), now: now)
    }

    func testShowsHoursAndMinutesWithinADay() {
        XCTAssertEqual(text(2 * 3600 + 30 * 60), "2h 30m")
        XCTAssertEqual(text(4 * 3600), "4h")
        XCTAssertEqual(text(45 * 60), "45m")
        XCTAssertEqual(text(23 * 3600 + 59 * 60), "23h 59m")
    }

    func testRoundsUpSoTheResetIsNeverPromisedEarly() {
        XCTAssertEqual(text(1), "1m")
        XCTAssertEqual(text(2 * 3600 + 29 * 60 + 1), "2h 30m")
        XCTAssertEqual(text(59 * 60 + 30), "1h")
    }

    func testSwitchesToDaysAndHoursBeyondADay() {
        XCTAssertEqual(text(3 * 86_400 + 4 * 3600), "3d 4h")
        XCTAssertEqual(text(2 * 86_400), "2d")
    }

    func testNilWithoutAFutureReset() {
        XCTAssertNil(WidgetResetCountdown.text(until: nil, now: now))
        XCTAssertNil(text(0))
        XCTAssertNil(text(-60))
    }
}
