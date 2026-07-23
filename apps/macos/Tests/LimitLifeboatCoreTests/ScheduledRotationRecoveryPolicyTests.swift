import Foundation
import XCTest
@testable import LimitLifeboatCore

final class ScheduledRotationRecoveryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let policy = ScheduledRotationRecoveryPolicy()

    func testFirstDeferralIsEligible() {
        XCTAssertTrue(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: nil,
            now: now
        ))
        XCTAssertTrue(policy.shouldAttempt(
            after: .credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(reason: "pending journal")
            ),
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: nil,
            now: now
        ))
    }

    func testActiveOrSharedAccountsAreNeverEligible() {
        XCTAssertFalse(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: true,
            accountIsLiveElsewhere: false,
            previous: nil,
            now: now
        ))
        XCTAssertFalse(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: true,
            previous: nil,
            now: now
        ))
    }

    func testNonDeferralErrorsAreNeverEligible() {
        let ineligible: [ClaudeAccountUsageFetchError] = [
            .noCredentials,
            .keychainLocked,
            .accountActiveElsewhere,
            .rotationDeferred(ClaudeCredentialRepairRequiredError(reason: "lease busy")),
            .credentialRecoveryFailed(ClaudeCredentialRepairRequiredError(reason: "terminal")),
            .credentialUnavailable(ClaudeCredentialRepairRequiredError(reason: "duplicate")),
            .refreshFailed(ClaudeOAuthError.missingRefreshToken),
            .unauthorized,
            .forbidden,
            .transport(ClaudeUsageAPIError.malformedResponse)
        ]
        for error in ineligible {
            XCTAssertFalse(policy.shouldAttempt(
                after: error,
                isActiveCLI: false,
                accountIsLiveElsewhere: false,
                previous: nil,
                now: now
            ), "Expected \(error) to be ineligible for automatic recovery")
        }
    }

    func testCooloffSpacesConsecutiveAttempts() {
        let previous = ScheduledRotationRecoveryPolicy.AttemptRecord(
            lastAttempt: now,
            consecutiveFailures: 1
        )
        XCTAssertFalse(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: previous,
            now: now.addingTimeInterval(policy.cooloff - 1)
        ))
        XCTAssertTrue(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: previous,
            now: now.addingTimeInterval(policy.cooloff)
        ))
    }

    func testFailureCapWaitsForUserOrFreshSnapshot() {
        let exhausted = ScheduledRotationRecoveryPolicy.AttemptRecord(
            lastAttempt: now,
            consecutiveFailures: policy.maxConsecutiveFailures
        )
        // Cooloff alone never re-arms an exhausted episode; only clearing the
        // record (successful snapshot or explicit user Retry) does.
        XCTAssertFalse(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: exhausted,
            now: now.addingTimeInterval(policy.cooloff * 100)
        ))
        XCTAssertTrue(policy.shouldAttempt(
            after: .interactiveRefreshRequired,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            previous: nil,
            now: now.addingTimeInterval(policy.cooloff * 100)
        ))
    }
}
