import XCTest
@testable import LLMUsageMonitorCore

final class UsageHistoryStoreTests: XCTestCase {
    private var root: URL!
    // ISO8601 encoding has whole-second precision, so use whole-second dates.
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherAccountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageMonitorHistoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAppendAndReloadRoundTrip() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 20, resetDate: now.addingTimeInterval(3_600))],
            lastRefreshed: now.addingTimeInterval(-600)
        )))
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 40, resetDate: now.addingTimeInterval(3_600))],
            lastRefreshed: now
        )))

        let reloaded = try UsageHistoryStore(applicationSupportDirectory: root)
        try reloaded.load(now: now)

        XCTAssertEqual(reloaded.records(for: accountID), store.records(for: accountID))
        XCTAssertEqual(reloaded.records(for: accountID).map(\.timestamp), [now.addingTimeInterval(-600), now])
    }

    func testIdenticalReadingsDoNotAppend() throws {
        let store = try makeStore()
        let windows = [window(usedPercent: 20, resetDate: now.addingTimeInterval(3_600))]
        XCTAssertTrue(try store.append(snapshot(windows: windows, lastRefreshed: now.addingTimeInterval(-600))))

        // Same readings with only a newer refresh timestamp: poll churn, not
        // a new observation.
        XCTAssertFalse(try store.append(snapshot(windows: windows, lastRefreshed: now)))

        XCTAssertEqual(try fileLineCount(), 1)
        XCTAssertEqual(store.records(for: accountID).count, 1)
    }

    func testCosmeticWindowChangesDoNotAppend() throws {
        let store = try makeStore()
        let reset = now.addingTimeInterval(3_600)
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(label: "Current session", usedPercent: 85, resetDate: reset, riskLevel: .healthy)],
            lastRefreshed: now.addingTimeInterval(-600)
        )))

        // A relabel or risk re-rank alone is not worth a history line.
        XCTAssertFalse(try store.append(snapshot(
            windows: [window(label: "Session (5h)", usedPercent: 85, resetDate: reset, riskLevel: .warning)],
            lastRefreshed: now
        )))

        XCTAssertEqual(try fileLineCount(), 1)
    }

    func testChangedPercentAppends() throws {
        let store = try makeStore()
        let reset = now.addingTimeInterval(3_600)
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 20, resetDate: reset)],
            lastRefreshed: now.addingTimeInterval(-600)
        )))
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 21, resetDate: reset)],
            lastRefreshed: now
        )))

        XCTAssertEqual(try fileLineCount(), 2)
        XCTAssertEqual(store.records(for: accountID).count, 2)
    }

    func testResetDateOnlyChangeAppends() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 20, resetDate: now.addingTimeInterval(3_600))],
            lastRefreshed: now.addingTimeInterval(-600)
        )))

        // Same percent, new reset date: the window rolled over, which the
        // burn-rate estimator needs to see.
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 20, resetDate: now.addingTimeInterval(21_600))],
            lastRefreshed: now
        )))

        XCTAssertEqual(try fileLineCount(), 2)
    }

    func testFailedParseAndEmptyWindowsAreSkipped() throws {
        let store = try makeStore()

        XCTAssertFalse(try store.append(snapshot(windows: [window(usedPercent: 20)], parseConfidence: .none)))
        XCTAssertFalse(try store.append(snapshot(windows: [])))

        XCTAssertEqual(try fileLineCount(), 0)
        XCTAssertEqual(store.records(for: accountID), [])
    }

    func testMalformedTrailingLineIsSkippedOnLoad() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.append(snapshot(windows: [window(usedPercent: 20)])))

        // Simulate a crash mid-append: a truncated JSON fragment on the last line.
        let handle = try FileHandle(forWritingTo: historyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"accountID\":\"11111111".utf8))
        try handle.close()

        let reloaded = try UsageHistoryStore(applicationSupportDirectory: root)
        try reloaded.load(now: now)

        XCTAssertEqual(reloaded.records(for: accountID).count, 1)
        XCTAssertEqual(reloaded.records(for: accountID)[0].windows[0].usedPercent, 20)
    }

    func testPruneDropsRecordsPastRetention() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.append(snapshot(
            windows: [window(usedPercent: 90)],
            lastRefreshed: now.addingTimeInterval(-31 * 24 * 3_600)
        )))
        XCTAssertTrue(try store.append(snapshot(windows: [window(usedPercent: 20)], lastRefreshed: now)))

        try store.prune(now: now)

        XCTAssertEqual(store.records(for: accountID).map(\.timestamp), [now])
        XCTAssertEqual(try fileLineCount(), 1)
    }

    func testPruneCapsRecordsPerAccount() throws {
        let store = try makeStore(maxRecordsPerAccount: 3)
        for index in 0..<5 {
            XCTAssertTrue(try store.append(snapshot(
                windows: [window(usedPercent: Double(10 + index * 10))],
                lastRefreshed: now.addingTimeInterval(TimeInterval(index * 60 - 300))
            )))
        }

        try store.prune(now: now)

        XCTAssertEqual(store.records(for: accountID).map { $0.windows[0].usedPercent }, [30, 40, 50])
        XCTAssertEqual(try fileLineCount(), 3)
    }

    func testRemoveAccountRemovesOnlyThatAccount() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.append(snapshot(windows: [window(usedPercent: 20)])))
        XCTAssertTrue(try store.append(snapshot(accountID: otherAccountID, windows: [window(usedPercent: 50)])))

        try store.removeAccount(accountID)

        XCTAssertEqual(store.records(for: accountID), [])
        XCTAssertEqual(store.records(for: otherAccountID).count, 1)
        XCTAssertEqual(try fileLineCount(), 1)

        let reloaded = try UsageHistoryStore(applicationSupportDirectory: root)
        try reloaded.load(now: now)
        XCTAssertEqual(reloaded.records(for: accountID), [])
        XCTAssertEqual(reloaded.records(for: otherAccountID).count, 1)
    }

    func testReadingsFiltersByWindowAndStaysChronological() throws {
        let store = try makeStore()
        let times = [now.addingTimeInterval(-1_200), now.addingTimeInterval(-600), now]
        for (index, time) in times.enumerated() {
            XCTAssertTrue(try store.append(snapshot(
                windows: [
                    window(id: "session", kind: .session, usedPercent: Double(20 + index * 10)),
                    window(id: "weekly-all", kind: .weekly, label: "Weekly (all models)", usedPercent: Double(5 + index)),
                ],
                lastRefreshed: time
            )))
        }

        let readings = store.readings(accountID: accountID, windowID: "session")

        XCTAssertEqual(readings.map { $0.timestamp }, times)
        XCTAssertEqual(readings.map { $0.reading.usedPercent }, [20, 30, 40])
        XCTAssertTrue(readings.allSatisfy { $0.reading.id == "session" })
        XCTAssertEqual(store.readings(accountID: accountID, windowID: "weekly-all").count, 3)
    }

    private var historyURL: URL {
        root.appendingPathComponent("usage-history.jsonl")
    }

    /// Loads with the fixed test epoch so the load-time prune never depends
    /// on the wall clock.
    private func makeStore(maxRecordsPerAccount: Int = 5000) throws -> UsageHistoryStore {
        let store = try UsageHistoryStore(
            applicationSupportDirectory: root,
            maxRecordsPerAccount: maxRecordsPerAccount
        )
        try store.load(now: now)
        return store
    }

    private func fileLineCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return 0
        }
        let contents = try String(contentsOf: historyURL, encoding: .utf8)
        return contents.split(separator: "\n").count
    }

    private func window(
        id: String = "session",
        kind: UsageWindowKind = .session,
        label: String = "Session",
        usedPercent: Double,
        resetDate: Date? = nil,
        riskLevel: RiskLevel = .healthy
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetDate: resetDate,
            windowMinutes: 300,
            riskLevel: riskLevel
        )
    }

    private func snapshot(
        accountID: UUID? = nil,
        windows: [UsageWindow],
        lastRefreshed: Date? = nil,
        parseConfidence: ParseConfidence = .high
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID ?? self.accountID,
            provider: .claude,
            windows: windows,
            source: "test",
            lastRefreshed: lastRefreshed ?? now,
            parseConfidence: parseConfidence
        )
    }
}
