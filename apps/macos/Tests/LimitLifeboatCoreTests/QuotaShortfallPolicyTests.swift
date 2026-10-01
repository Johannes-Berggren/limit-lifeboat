import XCTest
@testable import LimitLifeboatCore

final class QuotaShortfallPolicyTests: XCTestCase {
    private let policy = QuotaShortfallPolicy()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let profile = AccountProfile(provider: .claude, label: "Work")

    func testEmptyInTwentyMinutesWithTwoHoursToResetWarnsAndParksMostSessions() throws {
        // The example from the request: 10 sessions, empty in 20m, reset in 2h.
        // Lasting until the reset needs 1/6 of today's burn, so 9 of 10 pause;
        // two are starred, so only the 8 others can be offered.
        let sessions = (1...10).map { index in
            session(Int32(index), activeSecondsAgo: Double(index), starred: index <= 2)
        }

        let shortfall = try XCTUnwrap(evaluate(emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: sessions))

        XCTAssertEqual(shortfall.stage, .warning)
        XCTAssertEqual(shortfall.activeSessionCount, 10)
        XCTAssertEqual(shortfall.dryFor, 100 * 60, accuracy: 1)
        let suggestion = try XCTUnwrap(shortfall.suggestion)
        XCTAssertEqual(suggestion.neededCount, 9)
        XCTAssertFalse(suggestion.isEnough)
        // Least recently active first, starred never.
        XCTAssertEqual(suggestion.pids, [10, 9, 8, 7, 6, 5, 4, 3])
    }

    func testHeadsUpParksOnlyTheShareNeeded() throws {
        let sessions = (1...4).map { session(Int32($0), activeSecondsAgo: Double($0) * 10) }

        let shortfall = try XCTUnwrap(evaluate(emptyIn: 90 * 60, resetIn: 3 * 3_600, sessions: sessions))

        XCTAssertEqual(shortfall.stage, .headsUp)
        // Half the burn must go: 2 of 4.
        XCTAssertEqual(shortfall.suggestion?.pids, [4, 3])
        XCTAssertEqual(shortfall.suggestion?.isEnough, true)
    }

    func testNoShortfallWhenTheQuotaLastsOrIsFarOff() {
        let sessions = [session(1, activeSecondsAgo: 5)]
        // Runs dry only 5 minutes before the reset: not worth interrupting.
        XCTAssertNil(evaluate(emptyIn: 55 * 60, resetIn: 3_600, sessions: sessions))
        // Too far out to trust the pace.
        XCTAssertNil(evaluate(emptyIn: 5 * 3_600, resetIn: 24 * 3_600, sessions: sessions))
        // Nobody is working.
        XCTAssertNil(evaluate(emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: [session(1, activeSecondsAgo: 3_600)]))
        XCTAssertNil(evaluate(emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: []))
    }

    func testOtherProvidersAndUnparkableSessionsAreNotOffered() throws {
        let sessions = [
            session(1, activeSecondsAgo: 5),
            QuotaShortfallPolicy.Session(pid: 2, provider: .codex, lastActivityAt: nil, isParkable: false),
        ]
        let shortfall = try XCTUnwrap(evaluate(emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: sessions))
        XCTAssertEqual(shortfall.activeSessionCount, 1)
        XCTAssertEqual(shortfall.suggestion?.pids, [1])

        let codexProfile = AccountProfile(provider: .codex, label: "Codex")
        let codex = try XCTUnwrap(policy.shortfall(
            profile: codexProfile,
            windows: [window(resetIn: 2 * 3_600)],
            estimates: ["session": .depletesAt(now.addingTimeInterval(20 * 60))],
            sessions: sessions,
            lastParkedAt: nil,
            now: now
        ))
        XCTAssertNil(codex.suggestion, "Codex sessions are shown but cannot be parked")
    }

    func testARecentParkSettlesBeforeSuggestingMore() throws {
        let sessions = [
            session(1, activeSecondsAgo: 5),
            session(2, activeSecondsAgo: 5, parked: true),
        ]
        let settling = try XCTUnwrap(evaluate(
            emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: sessions, lastParkedAt: now.addingTimeInterval(-60)
        ))
        XCTAssertNil(settling.suggestion)
        XCTAssertEqual(settling.parkedCount, 1)
        XCTAssertEqual(settling.activeSessionCount, 1)

        let settled = try XCTUnwrap(evaluate(
            emptyIn: 20 * 60, resetIn: 2 * 3_600, sessions: sessions, lastParkedAt: now.addingTimeInterval(-3_600)
        ))
        XCTAssertEqual(settled.suggestion?.pids, [1])
    }

    func testText() throws {
        let shortfall = try XCTUnwrap(evaluate(
            emptyIn: 20 * 60, resetIn: 2 * 3_600,
            sessions: (1...4).map { session(Int32($0), activeSecondsAgo: 5) }
        ))
        XCTAssertEqual(QuotaShortfallText.headline(shortfall, now: now), "Session runs dry in 20m, 1h 40m before it resets.")
        XCTAssertTrue(QuotaShortfallText.detail(shortfall).hasPrefix("4 sessions are working."))
        XCTAssertEqual(QuotaShortfallText.parkButtonTitle(try XCTUnwrap(shortfall.suggestion)), "Park 4 sessions")
    }

    func testPreciseDurations() {
        XCTAssertEqual(DurationPhrase.precise(20 * 60), "20m")
        XCTAssertEqual(DurationPhrase.precise(95 * 60), "1h 35m")
        XCTAssertEqual(DurationPhrase.precise(119 * 60), "2h")
        XCTAssertEqual(DurationPhrase.precise(30 * 3_600), "30h")
    }

    // MARK: - Helpers

    private func evaluate(
        emptyIn: TimeInterval,
        resetIn: TimeInterval,
        sessions: [QuotaShortfallPolicy.Session],
        lastParkedAt: Date? = nil
    ) -> QuotaShortfall? {
        policy.shortfall(
            profile: profile,
            windows: [window(resetIn: resetIn)],
            estimates: ["session": .depletesAt(now.addingTimeInterval(emptyIn))],
            sessions: sessions,
            lastParkedAt: lastParkedAt,
            now: now
        )
    }

    private func window(resetIn: TimeInterval) -> UsageWindow {
        UsageWindow(id: "session", kind: .session, label: "Session", usedPercent: 80, resetDate: now.addingTimeInterval(resetIn))
    }

    private func session(
        _ pid: Int32,
        activeSecondsAgo: TimeInterval,
        starred: Bool = false,
        parked: Bool = false
    ) -> QuotaShortfallPolicy.Session {
        .init(
            pid: pid,
            provider: .claude,
            lastActivityAt: now.addingTimeInterval(-activeSecondsAgo),
            isStarred: starred,
            isParked: parked,
            isParkable: true
        )
    }
}
