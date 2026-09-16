import XCTest
@testable import LimitLifeboatCore

final class SessionInsightAggregatorTests: XCTestCase {
    private let aggregator = SessionInsightAggregator()
    private let start = Date(timeIntervalSince1970: 1_789_000_000)

    func testSummarizesPeakParallelTopProjectsAndModelShare() throws {
        let samples = [
            sample(minute: 0, [entry(1, "app", "claude-opus-5", idle: 10), entry(2, "site", "claude-sonnet-5", idle: 10)]),
            sample(minute: 5, [entry(1, "app", "claude-opus-5", idle: 10), entry(2, "site", "claude-sonnet-5", idle: 10), entry(3, "docs", "claude-opus-5", idle: 10)]),
            // Idle entries are not counted as work.
            sample(minute: 10, [entry(1, "app", "claude-opus-5", idle: 4_000)])
        ]

        let summary = try XCTUnwrap(aggregator.summary(samples: samples, in: period()))

        XCTAssertEqual(summary.peakParallelSessions, 3)
        XCTAssertEqual(summary.topProjects.map(\.project), ["app", "site", "docs"])
        XCTAssertEqual(summary.topProjects.map(\.minutes), [10, 10, 5])
        XCTAssertEqual(summary.modelShares.first?.model, "claude-opus-5")
        XCTAssertEqual(summary.modelShares.first?.share ?? 0, 0.6, accuracy: 0.001)
    }

    func testCountsOnlyResumesThatCrossedThePromptCacheTTL() throws {
        let samples = [
            sample(minute: 0, [entry(1, "app", "claude-opus-5", idle: 4_000, context: 500_000), entry(2, "site", "claude-opus-5", idle: 600, context: 90_000)]),
            // Session 1 woke up after more than an hour idle; session 2 was
            // idle only ten minutes, so its cache was still warm.
            sample(minute: 5, [entry(1, "app", "claude-opus-5", idle: 20, context: 500_000), entry(2, "site", "claude-opus-5", idle: 30, context: 90_000)])
        ]

        let summary = try XCTUnwrap(aggregator.summary(samples: samples, in: period()))

        XCTAssertEqual(summary.coldResumeCount, 1)
        XCTAssertEqual(summary.coldResumeTokens, 500_000)
        XCTAssertTrue(
            aggregator.digestLines(for: summary).contains { $0.contains("500K tokens uncached") },
            "\(aggregator.digestLines(for: summary))"
        )
    }

    func testNoSamplesMeansNoSummary() {
        XCTAssertNil(aggregator.summary(samples: [], in: period()))
        XCTAssertNil(aggregator.summary(samples: [sample(minute: -10_000, [entry(1, "app", nil, idle: 0)])], in: period()))
    }

    func testStoreAppendsReadsBackAndPrunes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionInsightStore(applicationSupportDirectory: directory, retention: 3_600)

        try store.append(sample(minute: -120, [entry(1, "old", nil, idle: 0)]))
        try store.append(sample(minute: 0, [entry(2, "new", nil, idle: 0)]))

        let reloaded = SessionInsightStore(applicationSupportDirectory: directory, retention: 3_600)
        try reloaded.load()
        let kept = reloaded.samples(in: DateInterval(start: start.addingTimeInterval(-10_000), end: start.addingTimeInterval(10_000)))
        XCTAssertEqual(kept.map { $0.entries.first?.project }, ["new"])
    }

    func testModelNamingShortensIDs() {
        XCTAssertEqual(ModelNaming.short("claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelNaming.short("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelNaming.short("gpt-6-astra"), "Gpt 6.astra")
    }

    private func period() -> DateInterval {
        DateInterval(start: start.addingTimeInterval(-60), end: start.addingTimeInterval(3_600))
    }

    private func sample(minute: Int, _ entries: [SessionSample.Entry]) -> SessionSample {
        SessionSample(timestamp: start.addingTimeInterval(TimeInterval(minute * 60)), entries: entries)
    }

    private func entry(_ pid: Int32, _ project: String, _ model: String?, idle: Int, context: Int = 1_000) -> SessionSample.Entry {
        SessionSample.Entry(pid: pid, provider: .claude, project: project, model: model, contextTokens: context, idleSeconds: idle)
    }
}

final class ColdCacheAlertPolicyTests: XCTestCase {
    private let policy = ColdCacheAlertPolicy()

    func testWarnsOnceForBigIdleSessionsOnly() {
        let entries = [
            entry(1, "app", idle: 3_400, context: 400_000),
            entry(2, "tiny", idle: 3_400, context: 5_000),
            entry(3, "busy", idle: 60, context: 900_000),
            entry(4, "codex", idle: nil, context: 0)
        ]

        let candidates = policy.candidates(entries: entries, alreadyWarned: [])

        XCTAssertEqual(candidates.map(\.pid), [1])
        XCTAssertTrue(policy.notificationBody(for: candidates).contains("400K tokens"))
        XCTAssertTrue(policy.candidates(entries: entries, alreadyWarned: [1]).isEmpty)
    }

    private func entry(_ pid: Int32, _ project: String, idle: Int?, context: Int) -> SessionSample.Entry {
        SessionSample.Entry(pid: pid, provider: .claude, project: project, model: nil, contextTokens: context, idleSeconds: idle)
    }
}
