import XCTest
@testable import LLMUsageMonitorCore

final class CodexLocalUsageReaderTests: XCTestCase {
    func testReadsMostConstrainedCodexRateLimitFromLocalSessionLogs() throws {
        let fixture = try TemporaryCodexUsageFixture()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            name: "recent.jsonl",
            lines: [
                #"{"timestamp":"2026-07-03T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1783093420},"secondary":{"used_percent":86.0,"window_minutes":10080,"resets_at":1783388580},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}"#
            ]
        )

        let profile = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = try XCTUnwrap(
            CodexLocalUsageReader(homeDirectory: fixture.home).readUsage(
                for: profile,
                now: Date(timeIntervalSince1970: 1783000000)
            )
        )

        XCTAssertEqual(snapshot.includedRemaining, 14)
        XCTAssertEqual(snapshot.includedLimit, 100)
        XCTAssertEqual(snapshot.usedFraction, 0.86)
        XCTAssertEqual(snapshot.riskLevel, .warning)
        XCTAssertEqual(snapshot.parseConfidence, .high)
        XCTAssertEqual(snapshot.source, "local Codex CLI logs")
        XCTAssertEqual(snapshot.resetDate, Date(timeIntervalSince1970: 1783388580))
        XCTAssertTrue(snapshot.message.contains("Codex CLI reports 86% used"))
        XCTAssertTrue(snapshot.message.contains("plan: pro"))

        // Both windows are preserved, not just the most-constrained one.
        XCTAssertEqual(snapshot.windows.count, 2)

        let session = snapshot.windows[0]
        XCTAssertEqual(session.id, "codex-300")
        XCTAssertEqual(session.kind, .session)
        XCTAssertEqual(session.label, "Session (5h)")
        XCTAssertEqual(session.usedPercent, 23)
        XCTAssertEqual(session.windowMinutes, 300)
        XCTAssertEqual(session.resetDate, Date(timeIntervalSince1970: 1783093420))

        let weekly = snapshot.windows[1]
        XCTAssertEqual(weekly.id, "codex-10080")
        XCTAssertEqual(weekly.kind, .weekly)
        XCTAssertEqual(weekly.label, "Weekly (7d)")
        XCTAssertEqual(weekly.usedPercent, 86)
        XCTAssertEqual(weekly.windowMinutes, 10080)
    }

    func testReadsSingleWindowWhenOnlyPrimaryPresent() throws {
        let fixture = try TemporaryCodexUsageFixture()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            name: "primary-only.jsonl",
            lines: [
                #"{"timestamp":"2026-07-03T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1783093420},"plan_type":"pro"}}}"#
            ]
        )

        let profile = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = try XCTUnwrap(
            CodexLocalUsageReader(homeDirectory: fixture.home).readUsage(
                for: profile,
                now: Date(timeIntervalSince1970: 1783000000)
            )
        )

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "codex-300")
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 23)
        XCTAssertEqual(snapshot.usedFraction ?? 0, 0.23, accuracy: 0.0001)
    }

    /// The freshness gate: an event older than the account's activation time
    /// belongs to whoever ran `codex` before the switch, so it is suppressed —
    /// a just-switched-to account is never shown the previous account's numbers.
    func testReadingSuppressedWhenLatestEventPredatesActivation() throws {
        let fixture = try TemporaryCodexUsageFixture()
        defer { fixture.cleanup() }
        try fixture.writeSession(
            name: "recent.jsonl",
            lines: [
                #"{"timestamp":"2026-07-03T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1783093420},"plan_type":"pro"}}}"#
            ]
        )

        let profile = AccountProfile(provider: .codex, label: "Codex")
        XCTAssertNil(
            CodexLocalUsageReader(homeDirectory: fixture.home).readUsage(
                for: profile,
                producedAfter: Date(timeIntervalSince1970: 1_783_200_000)
            )
        )
    }

    func testReadingAppliedWhenEventPostdatesActivation() throws {
        let fixture = try TemporaryCodexUsageFixture()
        defer { fixture.cleanup() }
        try fixture.writeSession(
            name: "recent.jsonl",
            lines: [
                #"{"timestamp":"2026-07-03T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":23.0,"window_minutes":300,"resets_at":1783093420},"plan_type":"pro"}}}"#
            ]
        )

        let profile = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = CodexLocalUsageReader(homeDirectory: fixture.home).readUsage(
            for: profile,
            producedAfter: Date(timeIntervalSince1970: 1_783_000_000),
            now: Date(timeIntervalSince1970: 1_783_200_000)
        )
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.windows.first?.usedPercent, 23)
    }

    func testReturnsNilWhenNoCodexRateLimitExists() throws {
        let fixture = try TemporaryCodexUsageFixture()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            name: "empty.jsonl",
            lines: [
                #"{"timestamp":"2026-07-03T12:00:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"hello"}}"#
            ]
        )

        let profile = AccountProfile(provider: .codex, label: "Codex")
        XCTAssertNil(CodexLocalUsageReader(homeDirectory: fixture.home).readUsage(for: profile))
    }
}

private struct TemporaryCodexUsageFixture {
    let root: URL
    let home: URL
    let sessions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMUsageMonitorCodexUsageTests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func writeSession(name: String, lines: [String]) throws {
        let url = sessions.appendingPathComponent(name)
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
