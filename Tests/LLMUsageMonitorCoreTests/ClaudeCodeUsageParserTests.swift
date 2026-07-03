import XCTest
@testable import LLMUsageMonitorCore

final class ClaudeCodeUsageParserTests: XCTestCase {
    private let parser = ClaudeCodeUsageOutputParser()

    func testParsesClaudeCodeUsageOutput() throws {
        let output = """
        \u{001B}[2mWelcome to Claude Code\u{001B}[0m
        | berggren@findable.ai's Organization |
        | Claude Max |

        Current session
        70% used
        Resets 8pm (Europe/Oslo)

        Current week (all models)
        24% used
        Resets Jul 10 at 6am (Europe/Oslo)

        Current week (Fable)
        26% used
        Resets Jul 10 at 5:59am (Europe/Oslo)

        Approximate, based on local sessions on this machine - does not include other devices or claude.ai
        Usage credits
        63% 63% used
        $315.15 / $500.00 spent - Resets Aug 1 (Europe/Oslo) Esc to cancelLast 24h - these are independent characteristics
        """

        let report = try XCTUnwrap(
            parser.parse(text: output, now: Date(timeIntervalSince1970: 1_783_000_000))
        )

        XCTAssertEqual(report.identity?.email, "berggren@findable.ai")
        XCTAssertNil(report.identity?.organization)
        XCTAssertEqual(report.identity?.source, .claudeCodeUsage)
        XCTAssertEqual(report.limits.count, 3)
        XCTAssertEqual(report.limits[0].name, "Current session")
        XCTAssertEqual(report.limits[0].usedPercent, 70)
        XCTAssertEqual(report.limits[0].resetDescription, "8pm (Europe/Oslo)")
        XCTAssertEqual(report.limits[1].name, "Current week (all models)")
        XCTAssertEqual(report.limits[1].usedPercent, 24)
        XCTAssertEqual(report.limits[2].name, "Current week (Fable)")
        XCTAssertEqual(report.limits[2].usedPercent, 26)
        XCTAssertEqual(
            report.usageCreditStatus,
            "Usage credits 63% used - $315.15 / $500.00 spent - resets Aug 1 (Europe/Oslo)"
        )

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = report.makeSnapshot(for: profile, now: Date(timeIntervalSince1970: 1_783_000_000))
        XCTAssertEqual(snapshot.includedRemaining, 30)
        XCTAssertEqual(snapshot.includedLimit, 100)
        XCTAssertEqual(snapshot.usedFraction, 0.70)
        XCTAssertEqual(snapshot.resetDescription, "8pm (Europe/Oslo)")
        XCTAssertEqual(snapshot.riskLevel, .healthy)
        XCTAssertEqual(snapshot.source, ClaudeCodeUsageReport.source)
        XCTAssertEqual(snapshot.parseConfidence, .high)
        XCTAssertTrue(snapshot.creditStatus?.contains("Usage credits 63% used") == true)
        XCTAssertTrue(snapshot.message.contains("current session 70%"))
        XCTAssertTrue(snapshot.message.contains("weekly all models 24%"))
        XCTAssertTrue(snapshot.message.contains("weekly Fable 26%"))
    }

    func testSelectsMostConstrainedLimitForRisk() throws {
        let report = try XCTUnwrap(parser.parse(text: """
        Current session
        12% used
        Resets 5pm

        Current week (Acme)
        86% used
        Resets Friday
        """))

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = report.makeSnapshot(for: profile)

        XCTAssertEqual(snapshot.includedRemaining, 14)
        XCTAssertEqual(snapshot.usedFraction, 0.86)
        XCTAssertEqual(snapshot.resetDescription, "Friday")
        XCTAssertEqual(snapshot.riskLevel, .warning)
    }

    func testReturnsNilForUnknownOutput() {
        XCTAssertNil(parser.parse(text: "Welcome to Claude Code. Type a prompt to begin."))
    }
}
