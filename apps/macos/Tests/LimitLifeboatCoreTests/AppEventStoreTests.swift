import XCTest
@testable import LimitLifeboatCore

final class AppEventStoreTests: XCTestCase {
    private var root: URL!
    // ISO8601 encoding has whole-second precision, so use whole-second dates.
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let accountA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let accountB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboatEventTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(retention: TimeInterval = 90 * 24 * 3600, maxRecords: Int = 1000) -> AppEventStore {
        AppEventStore(applicationSupportDirectory: root, retention: retention, maxRecords: maxRecords)
    }

    private func event(
        at timestamp: Date,
        to: UUID? = nil,
        from: UUID? = nil,
        interactive: Bool = true
    ) -> AppEvent {
        AppEvent(
            timestamp: timestamp,
            kind: .cliSwitch,
            provider: .claude,
            toProfileID: to ?? accountA,
            fromProfileID: from,
            interactive: interactive
        )
    }

    func testAppendAndReloadRoundTrip() throws {
        let store = makeStore()
        try store.append(event(at: now.addingTimeInterval(-600), from: accountB, interactive: false))
        try store.append(event(at: now))

        let reloaded = makeStore()
        try reloaded.load()
        let interval = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        XCTAssertEqual(reloaded.events(in: interval), store.events(in: interval))
        XCTAssertEqual(reloaded.events(in: interval).count, 2)
        XCTAssertEqual(reloaded.events(in: interval).first?.fromProfileID, accountB)
        XCTAssertEqual(reloaded.events(in: interval).first?.interactive, false)
    }

    func testEventsInIntervalFiltersByTimestamp() throws {
        let store = makeStore()
        try store.append(event(at: now.addingTimeInterval(-10 * 24 * 3600)))
        try store.append(event(at: now))

        let lastWeek = DateInterval(start: now.addingTimeInterval(-7 * 24 * 3600), end: now)
        XCTAssertEqual(store.events(in: lastWeek).count, 1)
    }

    func testRetentionPruneDropsOldEventsAndRewrites() throws {
        let store = makeStore(retention: 24 * 3600)
        try store.append(event(at: now.addingTimeInterval(-3 * 24 * 3600)))
        try store.append(event(at: now))

        let reloaded = makeStore()
        try reloaded.load()
        let everything = DateInterval(start: now.addingTimeInterval(-30 * 24 * 3600), end: now)
        XCTAssertEqual(reloaded.events(in: everything).count, 1)
    }

    func testMaxRecordsKeepsNewest() throws {
        let store = makeStore(maxRecords: 2)
        try store.append(event(at: now.addingTimeInterval(-300)))
        try store.append(event(at: now.addingTimeInterval(-200)))
        try store.append(event(at: now.addingTimeInterval(-100)))

        let everything = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        XCTAssertEqual(
            store.events(in: everything).map(\.timestamp),
            [now.addingTimeInterval(-200), now.addingTimeInterval(-100)]
        )
    }

    func testMalformedLinesAreSkippedOnLoad() throws {
        let store = makeStore()
        try store.append(event(at: now))
        let url = root.appendingPathComponent("app-events.jsonl")
        var data = try Data(contentsOf: url)
        data.append(Data("not json\n".utf8))
        try data.write(to: url)

        let reloaded = makeStore()
        try reloaded.load()
        let everything = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        XCTAssertEqual(reloaded.events(in: everything).count, 1)
    }

    func testRemoveAccountDropsEventsTouchingIt() throws {
        let store = makeStore()
        try store.append(event(at: now.addingTimeInterval(-300), to: accountA))
        try store.append(event(at: now.addingTimeInterval(-200), to: accountB, from: accountA))
        try store.append(event(at: now.addingTimeInterval(-100), to: accountB))

        try store.removeAccount(accountA)

        let everything = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        XCTAssertEqual(store.events(in: everything).map(\.toProfileID), [accountB])

        let reloaded = makeStore()
        try reloaded.load()
        XCTAssertEqual(reloaded.events(in: everything).map(\.toProfileID), [accountB])
    }
}
