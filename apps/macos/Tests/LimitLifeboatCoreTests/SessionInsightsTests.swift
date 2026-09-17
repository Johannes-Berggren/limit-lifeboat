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

    /// Codex entries have no transcript, so they must not dilute the model
    /// share of the sessions that do report one.
    func testModelShareIgnoresSessionsWithoutAModel() throws {
        let samples = [
            sample(minute: 0, [
                entry(1, "app", "claude-opus-5", idle: 10),
                SessionSample.Entry(pid: 2, provider: .codex, project: "cx", model: nil, contextTokens: 0, idleSeconds: 10)
            ])
        ]

        let summary = try XCTUnwrap(aggregator.summary(samples: samples, in: period()))

        XCTAssertEqual(summary.peakParallelSessions, 2)
        XCTAssertEqual(summary.modelShares.first?.share, 1.0)
        XCTAssertTrue(
            aggregator.digestLines(for: summary).contains { $0.contains("Opus 5 did 100% of the work") },
            "\(aggregator.digestLines(for: summary))"
        )
    }

    /// Project time is Claude-only today; the digest must say so rather than
    /// implying it covers every agent.
    func testDigestNamesProjectTimeAsClaudeWork() throws {
        let samples = [sample(minute: 0, [entry(1, "app", "claude-opus-5", idle: 10)])]
        let summary = try XCTUnwrap(aggregator.summary(samples: samples, in: period()))

        XCTAssertTrue(
            aggregator.digestLines(for: summary).contains { $0.contains("most Claude work in app") },
            "\(aggregator.digestLines(for: summary))"
        )
    }

    /// The weekly digest reads samples without calling load() first.
    func testSamplesReadLazilyWithoutAnExplicitLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionInsightStore(applicationSupportDirectory: directory)
            .append(sample(minute: 0, [entry(1, "app", "claude-opus-5", idle: 10)]))

        let fresh = SessionInsightStore(applicationSupportDirectory: directory)

        XCTAssertEqual(fresh.samples(in: period()).count, 1)
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
        XCTAssertEqual(ModelNaming.short("gpt-6-astra"), "gpt-6-astra")
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

final class ClaudeTranscriptBindingTests: XCTestCase {
    private var home: URL!
    private var directory: URL!
    private var reader: ClaudeTranscriptReader!
    private let workingDirectory = "/work/app"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        reader = ClaudeTranscriptReader(homeDirectory: home)
        directory = home.appendingPathComponent(".claude/projects/-work-app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testASessionKeepsItsTranscriptWhenAnotherIsResumedAndBecomesNewest() throws {
        let now = Date()
        // An old conversation file, and a file each running session created.
        try transcript("yesterday.jsonl", model: "claude-haiku-4-5", created: -86_400, modified: -86_000)
        try transcript("first.jsonl", model: "claude-opus-5", created: -600, modified: -60)
        try transcript("second.jsonl", model: "claude-sonnet-5", created: -300, modified: -30)
        let first = session(pid: 1, startedAt: now.addingTimeInterval(-620))
        let second = session(pid: 2, startedAt: now.addingTimeInterval(-320))
        var bindings = ClaudeTranscriptReader.Bindings()

        let firstScan = reader.activities(for: [first, second], bindings: &bindings)
        XCTAssertEqual(firstScan[1]?.model, "claude-opus-5")
        XCTAssertEqual(firstScan[2]?.model, "claude-sonnet-5")

        // A third session resumes yesterday's conversation, making that file
        // the most recently written in the directory.
        try touch("yesterday.jsonl", modified: -1)
        let resumed = session(pid: 3, startedAt: now.addingTimeInterval(-10))

        let secondScan = reader.activities(for: [first, second, resumed], bindings: &bindings)

        XCTAssertEqual(secondScan[1]?.model, "claude-opus-5")
        XCTAssertEqual(secondScan[2]?.model, "claude-sonnet-5")
        XCTAssertEqual(secondScan[3]?.model, "claude-haiku-4-5")
    }

    func testAFinishedSessionsTranscriptIsNotClaimedByANewOne() throws {
        let now = Date()
        // Left behind by a session that has already exited.
        try transcript("finished.jsonl", model: "claude-opus-5", created: -7_200, modified: -3_600)
        try transcript("mine.jsonl", model: "claude-sonnet-5", created: -60, modified: -10)
        var bindings = ClaudeTranscriptReader.Bindings()

        let activities = reader.activities(for: [session(pid: 9, startedAt: now.addingTimeInterval(-90))], bindings: &bindings)

        XCTAssertEqual(activities[9]?.model, "claude-sonnet-5")
    }

    func testClearMovesTheSessionToItsNewTranscript() throws {
        let now = Date()
        try transcript("before-clear.jsonl", model: "claude-opus-5", created: -1_800, modified: -600)
        let only = session(pid: 5, startedAt: now.addingTimeInterval(-1_900))
        var bindings = ClaudeTranscriptReader.Bindings()
        XCTAssertEqual(reader.activities(for: [only], bindings: &bindings)[5]?.model, "claude-opus-5")

        // /clear starts a fresh transcript; the old one stops changing.
        try transcript("after-clear.jsonl", model: "claude-sonnet-5", created: -60, modified: -5)

        XCTAssertEqual(reader.activities(for: [only], bindings: &bindings)[5]?.model, "claude-sonnet-5")
        XCTAssertEqual(bindings.url(forPID: 5)?.lastPathComponent, "after-clear.jsonl")
    }

    private func session(pid: Int32, startedAt: Date) -> AgentSession {
        AgentSession(pid: pid, provider: .claude, workingDirectory: workingDirectory, startedAt: startedAt, footprintBytes: 0, processCount: 1)
    }

    private func transcript(_ name: String, model: String, created: TimeInterval, modified: TimeInterval) throws {
        let url = directory.appendingPathComponent(name)
        let line = #"{"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":1}}}"#
        try Data(line.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(created), .modificationDate: Date().addingTimeInterval(modified)],
            ofItemAtPath: url.path
        )
    }

    private func touch(_ name: String, modified: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(modified)],
            ofItemAtPath: directory.appendingPathComponent(name).path
        )
    }
}
