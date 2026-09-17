import XCTest
@testable import LimitLifeboatCore

final class AgentSessionCensusTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_789_000_000)
    private let mb: UInt64 = 1_048_576

    func testClassifiesNativeNpmAndCodexExecutables() {
        XCTAssertEqual(AgentProcessClassifier.provider(executablePath: "/opt/homebrew/bin/claude", arguments: []), .claude)
        XCTAssertEqual(
            AgentProcessClassifier.provider(executablePath: "/Users/me/.local/share/claude/versions/2.1.272", arguments: []),
            .claude
        )
        XCTAssertEqual(
            AgentProcessClassifier.provider(
                executablePath: "/opt/homebrew/bin/node",
                arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]
            ),
            .claude
        )
        XCTAssertEqual(AgentProcessClassifier.provider(executablePath: "/usr/local/bin/codex", arguments: []), .codex)
        XCTAssertNil(AgentProcessClassifier.provider(executablePath: "/opt/homebrew/bin/node", arguments: ["node", "server.js"]))
        XCTAssertNil(AgentProcessClassifier.provider(executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: []))
    }

    func testSumsWholeProcessTreeAndSkipsOwnProbesAndNestedAgents() {
        let records = [
            record(1, parent: 0, path: "/sbin/launchd", mb: 10),
            // A session with an MCP server and a nested claude it spawned.
            record(100, parent: 1, path: "/bin/claude", mb: 300),
            record(101, parent: 100, path: "/opt/homebrew/bin/node", mb: 200),
            record(102, parent: 100, path: "/bin/claude", mb: 50),
            record(103, parent: 102, path: "/bin/zsh", mb: 5),
            // Limit Lifeboat's own usage probe.
            record(500, parent: 1, path: "/Applications/Limit Lifeboat.app/Contents/MacOS/LimitLifeboat", mb: 80),
            record(501, parent: 500, path: "/usr/local/bin/codex", mb: 90),
            record(600, parent: 1, path: "/usr/local/bin/codex", mb: 120)
        ]

        let sessions = AgentSessionCensusBuilder().sessions(
            from: records,
            excludingDescendantsOf: 500,
            workingDirectory: { "/work/\($0)" }
        )

        XCTAssertEqual(sessions.map(\.pid), [100, 600])
        XCTAssertEqual(sessions[0].footprintBytes, 555 * mb)
        XCTAssertEqual(sessions[0].processCount, 4)
        XCTAssertEqual(sessions[0].projectName, "100")
        XCTAssertEqual(sessions[1].provider, .codex)
    }

    private func record(_ pid: Int32, parent: Int32, path: String, mb megabytes: UInt64) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: parent, executablePath: path, startedAt: start, footprintBytes: megabytes * mb)
    }
}

final class ClaudeTranscriptReaderTests: XCTestCase {
    func testProjectDirectoryNameMatchesClaudeCodeEncoding() {
        XCTAssertEqual(
            ClaudeTranscriptReader.projectDirectoryName(for: "/Users/me/.bb/worktrees/thr_abc-1/mono-repo"),
            "-Users-me--bb-worktrees-thr-abc-1-mono-repo"
        )
    }

    func testReadsNewestAssistantTurnFromTruncatedTail() throws {
        let tail = """
        ncated line from the middle of the file"}
        {"type":"assistant","timestamp":"2026-09-16T10:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":9}}}
        {"type":"assistant","timestamp":"2026-09-16T11:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"cache_read_input_tokens":63376,"cache_creation_input_tokens":19591,"output_tokens":449}}}
        {"type":"user","timestamp":"2026-09-16T11:01:00.000Z","message":{"role":"user","content":"hi"}}
        """
        let fallback = Date(timeIntervalSince1970: 0)

        let activity = try XCTUnwrap(ClaudeTranscriptReader.latestActivity(inTail: Data(tail.utf8), fallbackDate: fallback))

        XCTAssertEqual(activity.model, "claude-opus-5")
        XCTAssertEqual(activity.contextTokens, 82_969)
        XCTAssertEqual(activity.lastActivityAt, ISO8601DateFormatter().date(from: "2026-09-16T11:00:00Z"))
    }

    func testFindsTranscriptsTouchedSinceSessionStart() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/projects/-work-app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date()
        let old = directory.appendingPathComponent("old.jsonl")
        let fresh = directory.appendingPathComponent("fresh.jsonl")
        try Data().write(to: old)
        try Data().write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3_600)], ofItemAtPath: old.path)

        let reader = ClaudeTranscriptReader(homeDirectory: home)

        XCTAssertEqual(reader.recentTranscripts(workingDirectory: "/work/app", since: start).map(\.lastPathComponent), ["fresh.jsonl"])
    }
}

final class MemoryGuardPolicyTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824
    private let now = Date(timeIntervalSince1970: 1_789_000_000)
    private let policy = MemoryGuardPolicy()

    func testOkWithHeadroomEstimatesAdditionalSessions() {
        let assessment = policy.assess(
            memory: memory(total: 36, used: 20),
            sessions: [session(1, gb: 1), session(2, gb: 3)],
            lastActivity: [:],
            now: now
        )

        XCTAssertEqual(assessment.level, .ok)
        XCTAssertEqual(assessment.sessionFootprintBytes, 4 * gb)
        // (16 GB free - 1.5 GB reserve) / 2 GB average.
        XCTAssertEqual(assessment.estimatedAdditionalSessions, 7)
    }

    func testCautionOnKernelWarningOrNoRoomForAnotherSession() {
        XCTAssertEqual(
            policy.assess(memory: memory(total: 36, used: 10, pressure: .warning), sessions: [], lastActivity: [:], now: now).level,
            .caution
        )
        XCTAssertEqual(
            policy.assess(memory: memory(total: 36, used: 30), sessions: [session(1, gb: 6)], lastActivity: [:], now: now).level,
            .caution
        )
    }

    func testCriticalOnKernelCriticalOrNearlyNoFreeMemory() {
        XCTAssertEqual(
            policy.assess(memory: memory(total: 36, used: 10, pressure: .critical), sessions: [], lastActivity: [:], now: now).level,
            .critical
        )
        XCTAssertEqual(
            policy.assess(memory: memory(total: 36, used: 35), sessions: [], lastActivity: [:], now: now).level,
            .critical
        )
    }

    func testPicksHeaviestIdleSessionUsingTranscriptActivity() {
        let busyGiant = session(1, gb: 5)
        let idleMedium = session(2, gb: 2)
        let idleSmall = session(3, gb: 1)

        let assessment = policy.assess(
            memory: memory(total: 36, used: 20),
            sessions: [busyGiant, idleMedium, idleSmall],
            lastActivity: [1: now.addingTimeInterval(-60), 2: now.addingTimeInterval(-7_200)],
            now: now
        )

        XCTAssertEqual(assessment.heaviestIdleSession?.pid, 2)
        XCTAssertEqual(assessment.heaviestIdleSince, now.addingTimeInterval(-7_200))
    }

    func testSessionWithoutTranscriptActivityIsNeverNamedIdle() {
        // A long-running Codex session has no transcript to read; its age says
        // nothing about whether it is working right now.
        let oldCodex = AgentSession(
            pid: 7,
            provider: .codex,
            workingDirectory: "/work/codex",
            startedAt: now.addingTimeInterval(-10 * 3_600),
            footprintBytes: 8 * gb,
            processCount: 3
        )

        let assessment = policy.assess(memory: memory(total: 36, used: 20), sessions: [oldCodex], lastActivity: [:], now: now)

        XCTAssertNil(assessment.heaviestIdleSession)
    }

    func testTightMemoryIsOnlyActionableWhileAgentsRun() {
        let noAgents = policy.assess(memory: memory(total: 36, used: 10, pressure: .critical), sessions: [], lastActivity: [:], now: now)
        let withAgent = policy.assess(memory: memory(total: 36, used: 10, pressure: .critical), sessions: [session(1, gb: 1)], lastActivity: [:], now: now)

        XCTAssertEqual(noAgents.level, .critical)
        XCTAssertFalse(noAgents.isActionable)
        XCTAssertTrue(withAgent.isActionable)
    }

    func testAlertPlannerNotifiesOnEscalationAndAfterCooldownOnly() {
        let planner = MemoryGuardAlertPlanner(cooldown: 1_800)
        let caution = assessment(.caution)
        let critical = assessment(.critical)
        let record = MemoryGuardAlertPlanner.Record(level: .caution, notifiedAt: now)

        XCTAssertTrue(planner.shouldNotify(caution, lastNotified: nil, now: now))
        XCTAssertFalse(planner.shouldNotify(caution, lastNotified: record, now: now.addingTimeInterval(600)))
        XCTAssertTrue(planner.shouldNotify(critical, lastNotified: record, now: now.addingTimeInterval(600)))
        XCTAssertTrue(planner.shouldNotify(caution, lastNotified: record, now: now.addingTimeInterval(1_800)))
        XCTAssertFalse(planner.shouldNotify(assessment(.ok), lastNotified: nil, now: now))
        XCTAssertFalse(planner.shouldNotify(assessment(.critical, sessions: 0), lastNotified: nil, now: now))
    }

    func testNotificationBodyNamesHeaviestIdleSession() {
        let idle = AgentSession(pid: 9, provider: .claude, workingDirectory: "/work/lifeboat", startedAt: now, footprintBytes: 3 * gb, processCount: 4)
        let value = MemoryGuardAssessment(
            level: .critical,
            sessionCount: 7,
            sessionFootprintBytes: 10 * gb,
            availableBytes: gb,
            estimatedAdditionalSessions: 0,
            heaviestIdleSession: idle,
            heaviestIdleSince: now.addingTimeInterval(-7_200)
        )

        XCTAssertEqual(
            MemoryGuardAlertPlanner().body(for: value, now: now),
            "7 agent sessions are using 10.0 GB. Close one before starting another, or your Mac may freeze. Heaviest idle: lifeboat (Claude, idle 2 h, 3.0 GB)."
        )
    }

    private func memory(total: UInt64, used: UInt64, pressure: MemoryPressureLevel = .normal) -> SystemMemoryStatus {
        SystemMemoryStatus(totalBytes: total * gb, usedBytes: used * gb, swapUsedBytes: 0, pressure: pressure)
    }

    private func session(_ pid: Int32, gb size: UInt64) -> AgentSession {
        AgentSession(
            pid: pid,
            provider: .claude,
            workingDirectory: "/work/\(pid)",
            startedAt: now.addingTimeInterval(-86_400),
            footprintBytes: size * gb,
            processCount: 1
        )
    }

    private func assessment(_ level: MemoryGuardLevel, sessions: Int = 3) -> MemoryGuardAssessment {
        MemoryGuardAssessment(
            level: level,
            sessionCount: sessions,
            sessionFootprintBytes: 0,
            availableBytes: 0,
            estimatedAdditionalSessions: nil,
            heaviestIdleSession: nil,
            heaviestIdleSince: nil
        )
    }
}

final class ModelNamingTests: XCTestCase {
    func testShortensCurrentAndLegacyClaudeModelIDs() {
        XCTAssertEqual(ModelNaming.short("claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelNaming.short("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelNaming.short("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(ModelNaming.short("claude-3-opus-20240229"), "Opus 3")
        XCTAssertEqual(ModelNaming.short("gpt-6-astra"), "gpt-6-astra")
    }
}

final class ClaudeTranscriptPairingTests: XCTestCase {
    func testSessionsSharingADirectoryEachGetTheirOwnTranscript() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/projects/-work-app")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        // a.jsonl was created first but written to most recently.
        for (name, model, created, modified) in [
            ("a.jsonl", "claude-opus-5", 500.0, 10.0),
            ("b.jsonl", "claude-sonnet-5", 200.0, 20.0)
        ] {
            let url = directory.appendingPathComponent(name)
            let line = #"{"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":1}}}"#
            try Data(line.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-created), .modificationDate: now.addingTimeInterval(-modified)],
                ofItemAtPath: url.path
            )
        }
        let older = AgentSession(pid: 1, provider: .claude, workingDirectory: "/work/app", startedAt: now.addingTimeInterval(-600), footprintBytes: 0, processCount: 1)
        let newer = AgentSession(pid: 2, provider: .claude, workingDirectory: "/work/app", startedAt: now.addingTimeInterval(-300), footprintBytes: 0, processCount: 1)

        let activities = ClaudeTranscriptReader(homeDirectory: home).activities(for: [older, newer])

        // Paired by age, not by recent writes: the older session gets the
        // older transcript, and input order does not change the pairing.
        XCTAssertEqual(activities[1]?.model, "claude-opus-5")
        XCTAssertEqual(activities[2]?.model, "claude-sonnet-5")
        XCTAssertEqual(ClaudeTranscriptReader(homeDirectory: home).activities(for: [newer, older]), activities)
    }
}
