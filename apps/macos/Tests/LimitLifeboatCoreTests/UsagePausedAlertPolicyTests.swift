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

    func testDoesNotNotifyAtOrAfterFixedLoginExpiry() {
        let expiry = start.addingTimeInterval(20 * 60)

        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: start,
                fixedLoginExpiresAt: expiry,
                now: expiry,
                alreadyNotified: false
            )
        )
        XCTAssertFalse(
            policy.shouldNotify(
                pausedSince: start,
                fixedLoginExpiresAt: expiry,
                now: expiry.addingTimeInterval(1),
                alreadyNotified: false
            )
        )
    }

    func testFixedExpiryDoesNotSuppressReminderBeforeExpiry() {
        XCTAssertTrue(
            policy.shouldNotify(
                pausedSince: start,
                fixedLoginExpiresAt: start.addingTimeInterval(60 * 60),
                now: start.addingTimeInterval(15 * 60),
                alreadyNotified: false
            )
        )
    }

    func testPastCachedExpiryDoesNotSuppressReminderWhenCredentialsAreUnreadable() {
        XCTAssertTrue(
            policy.shouldNotify(
                pausedSince: start,
                fixedLoginExpiresAt: start.addingTimeInterval(5 * 60),
                storedCredentials: .accessBlocked(
                    source: .savedAccount,
                    disposition: .unavailable,
                    reason: "Keychain unavailable"
                ),
                now: start.addingTimeInterval(20 * 60),
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
