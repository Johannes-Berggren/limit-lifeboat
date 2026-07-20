import XCTest
@testable import LimitLifeboatCore

final class UsagePausedAlertPolicyTests: XCTestCase {
    private let policy = UsagePausedAlertPolicy(threshold: 15 * 60)
    private let start = Date(timeIntervalSince1970: 1_783_000_000)

    func testDoesNotNotifyBeforeThreshold() {
        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: start,
                now: start.addingTimeInterval(10 * 60),
                alreadyNotified: false
            )
        )
    }

    func testNotifiesOnceAtThreshold() {
        XCTAssertTrue(
            policy.shouldNotify(
                pausedSince: start,
                now: start.addingTimeInterval(15 * 60),
                alreadyNotified: false
            )
        )
    }

    func testDoesNotRenotifyWhenAlreadyNotified() {
        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: start,
                now: start.addingTimeInterval(60 * 60),
                alreadyNotified: true
            )
        )
    }

    func testDoesNotNotifyWhenNotPaused() {
        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: nil,
                now: start.addingTimeInterval(60 * 60),
                alreadyNotified: false
            )
        )
    }

    func testReArmsAfterRecovery() {
        // Simulating a fresh episode: pausedSince reset to a later time, and the
        // notified flag cleared. The nudge fires again once the new episode
        // crosses the threshold.
        let secondEpisode = start.addingTimeInterval(3 * 3600)
        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: secondEpisode,
                now: secondEpisode.addingTimeInterval(5 * 60),
                alreadyNotified: false
            )
        )
        XCTAssertTrue(
            policy.shouldNotify(
                pausedSince: secondEpisode,
                now: secondEpisode.addingTimeInterval(20 * 60),
                alreadyNotified: false
            )
        )
    }
}
