import XCTest
@testable import LimitLifeboatCore

final class CLIStatusReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func profile(
        _ label: String,
        _ provider: Provider,
        active: Bool = false,
        email: String? = nil
    ) -> AccountProfile {
        AccountProfile(
            provider: provider,
            label: label,
            planLabel: "Max 20x",
            identity: email.map {
                AccountIdentity(email: $0, source: .claudeCodeUsage)
            },
            isActiveCLI: active
        )
    }

    private func snapshot(
        _ id: UUID,
        _ provider: Provider,
        percents: [(String, Double)],
        ageSeconds: TimeInterval = 60,
        risk: RiskLevel = .healthy
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: id,
            provider: provider,
            windows: percents.map { label, percent in
                UsageWindow(
                    id: UsageWindowID.slug(label),
                    kind: .session,
                    label: label,
                    usedPercent: percent,
                    riskLevel: .healthy
                )
            },
            riskLevel: risk,
            source: "test source",
            lastRefreshed: now.addingTimeInterval(-ageSeconds)
        )
    }

    // MARK: - Ordering and priority

    /// Priority must mean the same thing here as in the app. `AppState`
    /// filters by provider and uses the enumerated index, so a per-provider
    /// rank is correct and a global index is not — a status line that printed
    /// the global one would disagree with the app about which account is next.
    func testPriorityIsRankedWithinProviderNotGlobally() {
        let profiles = [
            profile("Claude A", .claude),
            profile("Codex A", .codex),
            profile("Claude B", .claude),
            profile("Codex B", .codex),
        ]

        let report = CLIStatusReportBuilder.report(profiles: profiles, snapshots: [:], now: now)

        XCTAssertEqual(report.accounts.map(\.label), ["Claude A", "Claude B", "Codex A", "Codex B"])
        XCTAssertEqual(report.accounts.map(\.provider), ["claude", "claude", "codex", "codex"])
        // Each provider restarts at 0, matching SwitchCandidate.priorityRank.
        XCTAssertEqual(report.accounts.map(\.priority), [0, 1, 0, 1])
    }

    func testRepositoryOrderIsPreservedRatherThanSortedByLabel() {
        let profiles = [profile("Zulu", .claude), profile("Alpha", .claude)]
        let report = CLIStatusReportBuilder.report(profiles: profiles, snapshots: [:], now: now)
        XCTAssertEqual(report.accounts.map(\.label), ["Zulu", "Alpha"])
    }

    // MARK: - Readings

    func testAccountWithoutSnapshotReportsNoReading() {
        let report = CLIStatusReportBuilder.report(
            profiles: [profile("New", .claude)],
            snapshots: [:],
            now: now
        )
        XCTAssertNil(report.accounts[0].reading)
    }

    /// The most-constrained window is the one that blocks you first, so it is
    /// the max used percentage, not the active or the first window.
    func testMostConstrainedPercentIsTheHighestWindow() throws {
        let account = profile("Work", .claude)
        let report = CLIStatusReportBuilder.report(
            profiles: [account],
            snapshots: [account.id: snapshot(
                account.id,
                .claude,
                percents: [("Session (5h)", 34), ("Weekly (all models)", 85.4), ("Weekly (Fable)", 2)]
            )],
            now: now
        )

        let reading = try XCTUnwrap(report.accounts[0].reading)
        XCTAssertEqual(reading.mostConstrainedPercent, 85)
        XCTAssertEqual(reading.windows.map(\.usedPercent), [34, 85, 2])
    }

    /// Age is the field a caller checks before trusting a number, so it has to
    /// be derived at report time rather than baked in when the app refreshed.
    func testAgeSecondsIsMeasuredFromTheReportInstant() throws {
        let account = profile("Work", .claude)
        let report = CLIStatusReportBuilder.report(
            profiles: [account],
            snapshots: [account.id: snapshot(account.id, .claude, percents: [("Session", 10)], ageSeconds: 3_600)],
            now: now
        )

        let reading = try XCTUnwrap(report.accounts[0].reading)
        XCTAssertEqual(reading.ageSeconds, 3_600)
        XCTAssertEqual(reading.lastRefreshed, now.addingTimeInterval(-3_600))
    }

    /// A snapshot recorded fractionally in the future (clock skew between the
    /// write and the read) must not report a negative age.
    func testFutureSnapshotClampsAgeToZero() throws {
        let account = profile("Work", .claude)
        let report = CLIStatusReportBuilder.report(
            profiles: [account],
            snapshots: [account.id: snapshot(account.id, .claude, percents: [("Session", 10)], ageSeconds: -30)],
            now: now
        )
        XCTAssertEqual(try XCTUnwrap(report.accounts[0].reading).ageSeconds, 0)
    }

    func testExtraUsageIsCarriedAlreadyFormatted() throws {
        let account = profile("Overage", .claude)
        var stored = snapshot(account.id, .claude, percents: [("Session", 100)])
        stored.payAsYouGoSpend = PayAsYouGoSpend(
            monthlyLimit: 5000,
            usedCredits: 1250,
            currency: "USD",
            decimalPlaces: 2
        )

        let report = CLIStatusReportBuilder.report(
            profiles: [account],
            snapshots: [account.id: stored],
            now: now
        )
        XCTAssertEqual(
            try XCTUnwrap(report.accounts[0].reading).extraUsage,
            stored.payAsYouGoSpend?.summaryText
        )
    }

    func testIdentityAndActiveFlagAreProjected() {
        let account = profile("Work", .claude, active: true, email: "dev@example.com")
        let report = CLIStatusReportBuilder.report(profiles: [account], snapshots: [:], now: now)

        XCTAssertEqual(report.accounts[0].email, "dev@example.com")
        XCTAssertEqual(report.accounts[0].plan, "Max 20x")
        XCTAssertTrue(report.accounts[0].isActive)
    }

    // MARK: - Schema

    /// Third-party status lines parse this. A rename is a breaking change and
    /// has to come with a schema bump, so pin the wire keys.
    func testJSONWireFormatIsStable() throws {
        let account = profile("Work", .claude, active: true, email: "dev@example.com")
        let report = CLIStatusReportBuilder.report(
            profiles: [account],
            snapshots: [account.id: snapshot(account.id, .claude, percents: [("Session", 10)])],
            now: now
        )

        let data = try JSONEncoder.appEncoder.encode(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["schema"] as? Int, 1)
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        XCTAssertEqual(
            Set(accounts[0].keys),
            ["id", "provider", "label", "email", "plan", "isActive", "priority", "reading"]
        )
        let reading = try XCTUnwrap(accounts[0]["reading"] as? [String: Any])
        XCTAssertEqual(
            Set(reading.keys),
            ["risk", "mostConstrainedPercent", "windows", "lastRefreshed", "ageSeconds", "source"]
        )
    }

    func testEmptyStoreProducesAnEmptyReportRatherThanFailing() {
        let report = CLIStatusReportBuilder.report(profiles: [], snapshots: [:], now: now)
        XCTAssertTrue(report.accounts.isEmpty)
        XCTAssertEqual(report.schema, CLIStatusReport.schemaVersion)
    }
}

final class ProfileRepositoryReadOnlyTests: XCTestCase {
    /// The CLI runs beside the app, so its reads must not touch the store.
    /// `loadProfiles()` creates the directory and writes back sanitized
    /// identities; `readProfiles()` must do neither, or two processes end up
    /// racing over the file the app is authoritative for.
    func testReadProfilesDoesNotCreateTheDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ll-readonly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = try ProfileRepository(applicationSupportDirectory: base)

        XCTAssertEqual(try repository.readProfiles(), [])
        XCTAssertEqual(try repository.readUsageSnapshots(), [:])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.path),
            "readProfiles must not materialise the store directory"
        )
    }

    func testReadProfilesDoesNotWriteBackSanitizedIdentities() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ll-readonly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = try ProfileRepository(applicationSupportDirectory: base)
        // An identity with nothing usable in it is what sanitizing strips.
        var stored = AccountProfile(provider: .claude, label: "Work")
        stored.identity = AccountIdentity(source: .claudeCodeUsage)
        try repository.saveProfiles([stored])

        let profilesURL = base.appendingPathComponent("profiles.json")
        let before = try Data(contentsOf: profilesURL)

        let read = try repository.readProfiles()
        XCTAssertNil(read[0].identity, "the in-memory result is still sanitized")
        XCTAssertEqual(
            try Data(contentsOf: profilesURL),
            before,
            "readProfiles must leave the file byte-for-byte alone"
        )
    }
}
