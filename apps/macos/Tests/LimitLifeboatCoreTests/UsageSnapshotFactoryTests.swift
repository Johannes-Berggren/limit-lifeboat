import XCTest
@testable import LimitLifeboatCore

final class UsageSnapshotFactoryTests: XCTestCase {
    func testClaudeSourcesShareStableWindowIdentity() {
        let apiSession = ClaudeUsageWindowCatalog.apiDescriptor(kindRaw: "session", scopeName: nil)
        let tuiSession = ClaudeUsageWindowCatalog.tuiDescriptor(name: "Current session")
        XCTAssertEqual(apiSession.id, tuiSession.id)
        XCTAssertEqual(apiSession.kind, tuiSession.kind)

        let apiWeekly = ClaudeUsageWindowCatalog.apiDescriptor(kindRaw: "weekly_all", scopeName: nil)
        let tuiWeekly = ClaudeUsageWindowCatalog.tuiDescriptor(name: "Current week (all models)")
        XCTAssertEqual(apiWeekly.id, tuiWeekly.id)
        XCTAssertEqual(apiWeekly.kind, tuiWeekly.kind)

        let apiScoped = ClaudeUsageWindowCatalog.apiDescriptor(kindRaw: "weekly_scoped", scopeName: "Fable")
        let tuiScoped = ClaudeUsageWindowCatalog.tuiDescriptor(name: "Current week (Fable)")
        XCTAssertEqual(apiScoped.id, tuiScoped.id)
        XCTAssertEqual(apiScoped.kind, tuiScoped.kind)
    }

    func testWindowNormalizesPercentAndRiskTogether() {
        let descriptor = UsageWindowDescriptor(id: "session", kind: .session, label: "Session")

        let belowZero = UsageSnapshotFactory.window(descriptor: descriptor, usedPercent: -10)
        XCTAssertEqual(belowZero.usedPercent, 0)
        XCTAssertEqual(belowZero.riskLevel, .healthy)

        let aboveLimit = UsageSnapshotFactory.window(descriptor: descriptor, usedPercent: 120)
        XCTAssertEqual(aboveLimit.usedPercent, 100)
        XCTAssertEqual(aboveLimit.riskLevel, .depleted)
    }

    func testSnapshotMirrorsMostConstrainedWindow() throws {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UsageSnapshotFactory.window(
            descriptor: UsageWindowDescriptor(id: "session", kind: .session, label: "Session"),
            usedPercent: 30
        )
        let weekly = UsageSnapshotFactory.window(
            descriptor: UsageWindowDescriptor(id: "weekly", kind: .weekly, label: "Weekly"),
            usedPercent: 85,
            resetDate: reset,
            resetDescription: "Friday"
        )

        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [session, weekly],
            source: "test",
            lastRefreshed: Date(),
            message: "test"
        )

        XCTAssertEqual(snapshot.includedRemaining, 15)
        XCTAssertEqual(snapshot.riskLevel, .warning)
        XCTAssertEqual(snapshot.resetDate, reset)
        XCTAssertEqual(snapshot.resetDescription, "Friday")
    }

    func testEmptySnapshotIsUnknownAndUnconfident() {
        let snapshot = UsageSnapshotFactory.snapshot(
            accountID: UUID(),
            provider: .codex,
            windows: [],
            source: "test",
            lastRefreshed: Date(),
            message: "No reading"
        )

        XCTAssertEqual(snapshot.riskLevel, .unknown)
        XCTAssertEqual(snapshot.parseConfidence, .none)
        XCTAssertEqual(snapshot.message, "No reading")
    }
}
