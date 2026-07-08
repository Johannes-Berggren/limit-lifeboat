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

        // "8pm (Europe/Oslo)" resolves to the next 8pm Oslo time after `now`.
        var osloCalendar = Calendar(identifier: .gregorian)
        osloCalendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let snapshotTime = Date(timeIntervalSince1970: 1_783_000_000)
        var expectedReset = osloCalendar.date(
            bySettingHour: 20, minute: 0, second: 0,
            of: osloCalendar.startOfDay(for: snapshotTime)
        )!
        if expectedReset <= snapshotTime {
            expectedReset = osloCalendar.date(byAdding: .day, value: 1, to: expectedReset)!
        }
        XCTAssertEqual(snapshot.resetDate, expectedReset)
        XCTAssertFalse(snapshot.resetHasElapsed(asOf: snapshotTime))

        XCTAssertEqual(snapshot.riskLevel, .healthy)
        XCTAssertEqual(snapshot.source, ClaudeCodeUsageReport.source)
        XCTAssertEqual(snapshot.parseConfidence, .high)
        XCTAssertTrue(snapshot.creditStatus?.contains("Usage credits 63% used") == true)
        XCTAssertTrue(snapshot.message.contains("current session 70%"))
        XCTAssertTrue(snapshot.message.contains("weekly all models 24%"))
        XCTAssertTrue(snapshot.message.contains("weekly Fable 26%"))

        // All three rate-limit windows are preserved (credits stay out).
        XCTAssertEqual(snapshot.windows.count, 3)

        XCTAssertEqual(snapshot.windows[0].id, "session")
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].label, "Session")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 70)
        XCTAssertEqual(snapshot.windows[0].resetDate, expectedReset)
        XCTAssertEqual(snapshot.windows[0].riskLevel, .healthy)

        XCTAssertEqual(snapshot.windows[1].id, "weekly-all")
        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertEqual(snapshot.windows[1].label, "Weekly (all models)")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 24)

        XCTAssertEqual(snapshot.windows[2].id, "weekly-fable")
        XCTAssertEqual(snapshot.windows[2].kind, .weeklyScoped)
        XCTAssertEqual(snapshot.windows[2].label, "Weekly (Fable)")
        XCTAssertEqual(snapshot.windows[2].usedPercent, 26)

        // The scalar fields mirror the most-constrained window (session, 70%).
        XCTAssertEqual(snapshot.usedFraction, snapshot.windows[0].usedFraction)
    }

    func testWindowKeepsUnparsedResetDescription() throws {
        let report = try XCTUnwrap(parser.parse(text: """
        Current session
        40% used
        Resets soon
        """))

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = report.makeSnapshot(for: profile)

        let session = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(session.resetDescription, "soon")
        XCTAssertNil(session.resetDate)
        XCTAssertEqual(session.usedPercent, 40)
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

    func testDedupesSectionsAcrossProgressiveTUIFrames() throws {
        // The expect probe captures several progressive redraw frames: sections
        // repeat, early occurrences can lack the reset line, and overwrites can
        // mangle a header that an earlier frame still has intact.
        let output = """
        \u{001B}[2mWelcome to Claude Code\u{001B}[0m
        | berggren@findable.ai's Organization |
        | Claude Max |

        Current session
        70% used

        Current week (all models)
        24% used
        Resets Jul 10 at 6am (Europe/Oslo)

        Current week (Fable)
        26% used
        Resets Jul 10 at 5:59am (Europe/Oslo)
        \u{001B}[2J\u{001B}[H
        Current session
        70% used
        Resets 8pm (Europe/Oslo)

        Current week (all models)
        24% used
        Resets Jul 10 at 6am (Europe/Oslo)

        Esc to cancelrrent week (Fable)
        26% used
        Resets Jul 10 at 5:59am (Europe/Oslo)
        """

        let report = try XCTUnwrap(parser.parse(text: output))

        // Exactly one limit per logical section, in first-seen order.
        XCTAssertEqual(report.limits.count, 3)
        XCTAssertEqual(report.limits[0].name, "Current session")
        XCTAssertEqual(report.limits[0].usedPercent, 70)
        // The second frame completes the session section with its reset line.
        XCTAssertEqual(report.limits[0].resetDescription, "8pm (Europe/Oslo)")
        XCTAssertEqual(report.limits[1].name, "Current week (all models)")
        XCTAssertEqual(report.limits[1].usedPercent, 24)
        XCTAssertEqual(report.limits[1].resetDescription, "Jul 10 at 6am (Europe/Oslo)")
        // The mangled header drops out of the second frame; the intact first
        // frame keeps the Fable section alive.
        XCTAssertEqual(report.limits[2].name, "Current week (Fable)")
        XCTAssertEqual(report.limits[2].usedPercent, 26)
        XCTAssertEqual(report.limits[2].resetDescription, "Jul 10 at 5:59am (Europe/Oslo)")

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = report.makeSnapshot(for: profile)
        let ids = snapshot.windows.map(\.id)
        XCTAssertEqual(ids, ["session", "weekly-all", "weekly-fable"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testKeepsResetDescriptionWhenLaterFrameLacksIt() throws {
        let report = try XCTUnwrap(parser.parse(text: """
        Current session
        70% used
        Resets 8pm (Europe/Oslo)

        Current session
        72% used
        """))

        // Never trade a reset description away for a later frame without one.
        XCTAssertEqual(report.limits.count, 1)
        XCTAssertEqual(report.limits[0].usedPercent, 70)
        XCTAssertEqual(report.limits[0].resetDescription, "8pm (Europe/Oslo)")
    }

    func testMakeSnapshotDedupesDuplicateWindowIDs() throws {
        // Defensive: even a report built directly with duplicate limits must
        // never hand SwiftUI ForEach two windows with the same id.
        let report = ClaudeCodeUsageReport(
            identity: nil,
            limits: [
                ClaudeCodeUsageLimit(name: "Current session", usedPercent: 55, resetDescription: nil),
                ClaudeCodeUsageLimit(name: "Current session", usedPercent: 60, resetDescription: "9pm (Europe/Oslo)")
            ]
        )

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = report.makeSnapshot(for: profile)

        XCTAssertEqual(snapshot.windows.count, 1)
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.id, "session")
        XCTAssertEqual(window.usedPercent, 60)
        XCTAssertEqual(window.resetDescription, "9pm (Europe/Oslo)")
    }

    func testReturnsNilForUnknownOutput() {
        XCTAssertNil(parser.parse(text: "Welcome to Claude Code. Type a prompt to begin."))
    }
}
