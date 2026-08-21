import XCTest
@testable import LimitLifeboatCore

final class UsageBackoffPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)
    /// Jitter pinned to identity so the ladder is exact.
    private let policy = UsageBackoffPolicy(jitter: { delay, _ in delay })

    func testServerRetryAfterWins() {
        let state = policy.next(after: nil, retryAfter: 47, now: now)

        XCTAssertEqual(state.consecutiveThrottles, 1)
        XCTAssertEqual(state.retryAt, now.addingTimeInterval(47))
    }

    func testServerRetryAfterIsStillCappedAtTheMaximum() {
        let state = policy.next(after: nil, retryAfter: 6 * 60 * 60, now: now)

        XCTAssertEqual(state.retryAt, now.addingTimeInterval(30 * 60))
    }

    func testConsecutiveThrottlesClimbGeometricallyAndCap() {
        var state: UsageBackoffPolicy.State?
        let expected: [TimeInterval] = [2, 4, 8, 16, 30, 30].map { $0 * 60 }

        for (index, delay) in expected.enumerated() {
            state = policy.next(after: state, retryAfter: nil, now: now)
            XCTAssertEqual(state?.consecutiveThrottles, index + 1)
            XCTAssertEqual(
                state?.retryAt,
                now.addingTimeInterval(delay),
                "throttle \(index + 1)"
            )
        }
    }

    func testANonPositiveOrNonFiniteRetryAfterFallsBackToTheLadder() {
        for value: TimeInterval in [0, -30, .infinity, .nan] {
            let state = policy.next(after: nil, retryAfter: value, now: now)
            XCTAssertEqual(state.retryAt, now.addingTimeInterval(2 * 60), "\(value)")
        }
    }

    func testCoolingDownEndsExactlyAtTheRetryInstant() {
        let state = policy.next(after: nil, retryAfter: 60, now: now)

        XCTAssertTrue(policy.isCoolingDown(state, now: now))
        XCTAssertTrue(policy.isCoolingDown(state, now: now.addingTimeInterval(59)))
        // A timer that fires exactly on the deadline must proceed.
        XCTAssertFalse(policy.isCoolingDown(state, now: now.addingTimeInterval(60)))
        XCTAssertFalse(policy.isCoolingDown(state, now: now.addingTimeInterval(61)))
    }

    func testNoLedgerMeansNoCooldown() {
        XCTAssertFalse(policy.isCoolingDown(nil, now: now))
        XCTAssertEqual(policy.delayUntilRetry(nil, now: now), 0)
    }

    func testDelayUntilRetryNeverGoesNegative() {
        let state = policy.next(after: nil, retryAfter: 60, now: now)

        XCTAssertEqual(policy.delayUntilRetry(state, now: now), 60)
        XCTAssertEqual(policy.delayUntilRetry(state, now: now.addingTimeInterval(600)), 0)
    }

    func testJitterStaysWithinItsFractionAndNeverGoesNegative() {
        let configuration = UsageBackoffPolicy.Configuration(jitterFraction: 0.2)
        let jittered = UsageBackoffPolicy(configuration: configuration)

        for _ in 0..<200 {
            let state = jittered.next(after: nil, retryAfter: nil, now: now)
            let delay = state.retryAt.timeIntervalSince(now)
            XCTAssertGreaterThanOrEqual(delay, 2 * 60 * 0.8)
            XCTAssertLessThanOrEqual(delay, 2 * 60 * 1.2)
        }

        XCTAssertEqual(UsageBackoffPolicy.randomJitter(0, fraction: 0.5), 0)
        XCTAssertEqual(UsageBackoffPolicy.randomJitter(-10, fraction: 0.5), 0)
        XCTAssertEqual(UsageBackoffPolicy.randomJitter(90, fraction: 0), 90)
    }
}
