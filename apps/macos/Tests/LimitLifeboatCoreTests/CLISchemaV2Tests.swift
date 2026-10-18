import XCTest
@testable import LimitLifeboatCore

/// Schema 2: issues, history and sessions, and v1 compatibility.
final class CLISchemaV2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func account(_ id: UUID = UUID(), reading ageSeconds: Int? = 60) -> CLIAccountStatus {
        CLIAccountStatus(
            id: id.uuidString, provider: "claude", label: "Work", isActive: true, priority: 0,
            reading: ageSeconds.map {
                CLIUsageReading(risk: "healthy", mostConstrainedPercent: 10, windows: [],
                                lastRefreshed: now.addingTimeInterval(-TimeInterval($0)), ageSeconds: $0,
                                source: "test", extraUsage: nil)
            }
        )
    }

    // MARK: - Schema version and v1 compatibility

    func testSchemaIsTwoAndOneIsStillSupported() {
        XCTAssertEqual(CLIStatusReport.schemaVersion, 2)
        XCTAssertEqual(CLIStatusReport.supportedSchemaVersions, [1, 2])
    }

    /// v2 only adds keys: a v1 document's keys are a subset of v2's, with the
    /// same values, so a reader that ignores unknown keys keeps working.
    func testV2IsASupersetOfV1() throws {
        let report = CLIStatusReportBuilder.detailed(
            CLIStatusReport(generatedAt: now, accounts: [account()]),
            issueSnapshot: nil,
            appRunning: false
        )
        let v2 = try JSONSerialization.jsonObject(with: JSONEncoder.appEncoder.encode(report)) as! [String: Any]
        let v1 = try JSONSerialization.jsonObject(with: JSONEncoder.appEncoder.encode(report.pinned(to: 1))) as! [String: Any]

        XCTAssertEqual(v1["schema"] as? Int, 1)
        XCTAssertEqual(v2["schema"] as? Int, 2)
        XCTAssertEqual(Set(v1.keys), ["schema", "generatedAt", "accounts"])
        XCTAssertTrue(Set(v1.keys).isSubset(of: Set(v2.keys)))
        let v1Account = (v1["accounts"] as! [[String: Any]])[0]
        let v2Account = (v2["accounts"] as! [[String: Any]])[0]
        XCTAssertNil(v1Account["issues"])
        XCTAssertNotNil(v2Account["issues"])
        for (key, value) in v1Account {
            XCTAssertEqual(String(describing: value), String(describing: v2Account[key]!), key)
        }
    }

    func testV1DecoderReadsAV2Document() throws {
        struct V1Report: Decodable {
            struct Account: Decodable { let id: String; let isActive: Bool; let priority: Int }
            let schema: Int
            let accounts: [Account]
        }
        let report = CLIStatusReportBuilder.detailed(
            CLIStatusReport(generatedAt: now, accounts: [account()]), issueSnapshot: nil, appRunning: true
        )
        let decoded = try JSONDecoder.appDecoder.decode(V1Report.self, from: JSONEncoder.appEncoder.encode(report))
        XCTAssertEqual(decoded.accounts.count, 1)
    }

    func testIssuesAreAbsentWithoutDetail() throws {
        let text = try CLIReadCommandOutput.render(.status, report: CLIStatusReport(generatedAt: now, accounts: [account()]), json: true)
        XCTAssertFalse(text.contains("\"issues\""))
        XCTAssertFalse(text.contains("\"app\""))
    }

    // MARK: - Issues

    func testRefreshStatesMapToStableCodes() {
        let cases: [(AccountRefreshState, String?, AccountIssue.Severity?)] = [
            (.idle, nil, nil),
            (.refreshing, nil, nil),
            (.ok, nil, nil),
            (.readFailed(reason: "r"), "read_failed", .warning),
            (.rateLimited(retryAt: nil), "rate_limited", .info),
            (.providerAccessForbidden(reason: "r"), "provider_access_forbidden", .error),
            (.rotationDeferred(reason: "r"), "rotation_deferred", .warning),
            (.switchRequired(reason: "r"), "switch_required", .warning),
            (.credentialRepairRequired(reason: "r"), "credential_repair_required", .error),
            (.usagePaused, "usage_paused", .info),
            (.needsLogin(reason: "r"), "needs_login", .error),
            (.keychainLocked, "keychain_locked", .error),
        ]
        for (state, code, severity) in cases {
            let issue = AccountIssue.from(state)
            XCTAssertEqual(issue?.code, code, "\(state)")
            XCTAssertEqual(issue?.severity, severity, "\(state)")
            XCTAssertEqual(issue.map(\.source), code == nil ? nil : .app)
        }
    }

    func testRateLimitCarriesItsRetryTime() {
        let retry = now.addingTimeInterval(300)
        XCTAssertEqual(AccountIssue.from(.rateLimited(retryAt: retry))?.retryAt, retry)
    }

    func testTrackerKeepsSinceWhileTheCodeIsUnchanged() {
        let id = UUID()
        var tracker = AccountIssueTracker()
        let first = tracker.snapshot(states: [id: .needsLogin(reason: "a")], knownAccounts: [id], now: now)
        let later = tracker.snapshot(states: [id: .needsLogin(reason: "b")], knownAccounts: [id], now: now.addingTimeInterval(600))
        XCTAssertEqual(first.accounts[id.uuidString]?.first?.since, now)
        XCTAssertEqual(later.accounts[id.uuidString]?.first?.since, now, "same code keeps its first-seen time")

        let changed = tracker.snapshot(states: [id: .readFailed(reason: "x")], knownAccounts: [id], now: now.addingTimeInterval(900))
        XCTAssertEqual(changed.accounts[id.uuidString]?.first?.since, now.addingTimeInterval(900))

        let healed = tracker.snapshot(states: [id: .ok], knownAccounts: [id], now: now.addingTimeInterval(1_000))
        XCTAssertNil(healed.accounts[id.uuidString])
    }

    func testTrackerDropsRemovedAccounts() {
        let id = UUID()
        var tracker = AccountIssueTracker()
        XCTAssertTrue(tracker.snapshot(states: [id: .keychainLocked], knownAccounts: [], now: now).accounts.isEmpty)
    }

    func testDetailMergesAppAndStoreIssuesMostSevereFirst() {
        let stale = UUID()
        let fresh = UUID()
        let never = UUID()
        let snapshot = AccountIssueSnapshot(updatedAt: now, accounts: [
            stale.uuidString: [AccountIssue.from(.needsLogin(reason: "log in"), since: now)!],
        ])
        let report = CLIStatusReportBuilder.detailed(
            CLIStatusReport(generatedAt: now, accounts: [account(stale, reading: 7_200), account(fresh), account(never, reading: nil)]),
            issueSnapshot: snapshot,
            appRunning: false
        )
        XCTAssertEqual(report.app, CLIAppState(running: false, issuesUpdatedAt: now))
        XCTAssertEqual(report.accounts[0].issues?.map(\.code), ["needs_login", "stale_reading"])
        XCTAssertEqual(report.accounts[0].issues?.map(\.source), [.app, .store])
        XCTAssertEqual(report.accounts[1].issues, [])
        XCTAssertEqual(report.accounts[2].issues?.map(\.code), ["no_reading"])
    }

    func testIssueStoreRoundTripsAndIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AccountIssueStore(applicationSupportDirectory: directory)
        XCTAssertNil(store.read())

        let snapshot = AccountIssueSnapshot(updatedAt: now, accounts: ["x": [AccountIssue.from(.usagePaused)!]])
        try store.write(snapshot)
        XCTAssertEqual(store.read(), snapshot)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: - History

    func testHistoryKeepsTheWindowAndEveryAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = UUID(), b = UUID()
        let window = UsageWindowReading(id: "session", kind: .session, usedPercent: 41.6, resetDate: now, windowMinutes: 300)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var lines = Data()
        for (account, daysAgo) in [(a, 10.0), (a, 2.0), (a, 0.5)] {
            lines.append(try encoder.encode(UsageHistoryRecord(timestamp: now.addingTimeInterval(-daysAgo * 86_400), accountID: account, windows: [window])))
            lines.append(10)
        }
        lines.append(Data("{torn".utf8)) // a half-written last line is skipped
        try lines.write(to: directory.appendingPathComponent("usage-history.jsonl"))

        let records = try CLIHistoryReportBuilder.readRecords(
            applicationSupportDirectory: directory, since: now.addingTimeInterval(-7 * 86_400)
        )
        let report = CLIHistoryReportBuilder.report(
            accounts: [account(a), account(b)], records: records, days: 7, now: now
        )

        XCTAssertEqual(report.schema, 2)
        XCTAssertEqual(report.days, 7)
        XCTAssertEqual(report.since, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(report.accounts.map(\.id), [a.uuidString, b.uuidString])
        XCTAssertEqual(report.accounts[0].records.count, 2, "the 10-day-old record is outside the window")
        XCTAssertEqual(report.accounts[0].records.first?.windows.first?.usedPercent, 42)
        XCTAssertEqual(report.accounts[0].records.first?.windows.first?.windowMinutes, 300)
        XCTAssertEqual(report.accounts[1].records, [])
    }

    func testHistoryReadDoesNotWriteTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-history.jsonl")
        // Older than the app's 30-day retention: UsageHistoryStore.load would prune it.
        let old = #"{"accountID":"\#(UUID().uuidString)","timestamp":"2020-01-01T00:00:00Z","windows":[]}"# + "\n"
        try Data(old.utf8).write(to: url)
        _ = try CLIHistoryReportBuilder.readRecords(applicationSupportDirectory: directory, since: .distantPast)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), old)
    }

    // MARK: - Sessions

    func testSessionsGroupPerProviderWithActivityAndParks() {
        let started = now.addingTimeInterval(-3_600)
        let sessions = [
            AgentSession(pid: 10, provider: .claude, workingDirectory: "/w/app", startedAt: started, footprintBytes: 300, processCount: 2),
            AgentSession(pid: 11, provider: .claude, workingDirectory: nil, startedAt: started.addingTimeInterval(5), footprintBytes: 200, processCount: 1),
        ]
        let activity = ClaudeSessionActivity(model: "claude-opus-5-5", contextTokens: 1_000, lastActivityAt: now.addingTimeInterval(-90), cacheTTLSeconds: 3_600)
        let parked = [
            SessionParkState.Entry(pid: 10, startedAt: started, project: "app", reason: .shortfall, parkedAt: now, releaseAt: now.addingTimeInterval(60)),
            // Same pid, different process start: a reused pid is not parked.
            SessionParkState.Entry(pid: 11, startedAt: started.addingTimeInterval(-100), project: "x", reason: .manual, parkedAt: now),
        ]

        let report = CLISessionsReportBuilder.report(sessions: sessions, activities: [10: activity], parked: parked, now: now)

        XCTAssertEqual(report.schema, 2)
        XCTAssertEqual(report.providers.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(report.providers[0].count, 2)
        XCTAssertEqual(report.providers[0].memoryBytes, 500)
        XCTAssertEqual(report.providers[1].count, 0)
        XCTAssertEqual(report.providers[1].sessions, [])

        let first = report.providers[0].sessions[0]
        XCTAssertEqual(first.project, "app")
        XCTAssertEqual(first.model, "claude-opus-5-5")
        XCTAssertEqual(first.contextTokens, 1_000)
        XCTAssertEqual(first.idleSeconds, 90)
        XCTAssertEqual(first.cacheTTLSeconds, 3_600)
        XCTAssertEqual(first.parked?.reason, "shortfall")
        XCTAssertNil(report.providers[0].sessions[1].parked)
        XCTAssertNil(report.providers[0].sessions[1].model)
    }

    func testStaleParkFileMeansNothingIsParked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = SessionParkState.Entry(pid: 1, startedAt: now, project: "p", reason: .manual, parkedAt: now)
        try SessionParkState(parked: [entry], now: now).write(to: directory.appendingPathComponent(SessionParkState.fileName))

        XCTAssertEqual(CLISessionsReportBuilder.readParked(applicationSupportDirectory: directory, now: now).count, 1)
        XCTAssertEqual(CLISessionsReportBuilder.readParked(applicationSupportDirectory: directory, now: now.addingTimeInterval(3_600)).count, 0)
    }
}
