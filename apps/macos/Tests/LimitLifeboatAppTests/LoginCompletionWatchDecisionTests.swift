import LimitLifeboatAppWorkflows
import LimitLifeboatCore
import XCTest

final class LoginCompletionWatchDecisionTests: XCTestCase {
    func testPendingOutcomeContinuesPolling() {
        XCTAssertEqual(
            LoginCompletionWatchDecision(outcome: .pending),
            .continuePolling
        )
    }

    func testTerminalOutcomesStopPolling() {
        for outcome in [
            LoginCompletionOutcome.completed,
            .authorizationRequired(source: .claudeCode),
            .authorizationRequired(source: .savedAccount),
            .failed
        ] {
            XCTAssertEqual(
                LoginCompletionWatchDecision(outcome: outcome),
                .stopPolling
            )
        }
    }

    func testOnlyProviderAuthorizationRetainsPendingClaudeCompletion() {
        XCTAssertTrue(
            LoginCompletionOutcome.authorizationRequired(source: .claudeCode)
                .retainsPendingClaudeLoginCompletion
        )
        XCTAssertFalse(
            LoginCompletionOutcome.authorizationRequired(source: .savedAccount)
                .retainsPendingClaudeLoginCompletion
        )
        XCTAssertFalse(LoginCompletionOutcome.failed.retainsPendingClaudeLoginCompletion)
    }

    func testTemporaryLeaseContentionContinuesPolling() {
        XCTAssertEqual(
            LoginCompletionOutcome(
                leaseAcquisitionError: .busy(lock: .oauthRefresh)
            ),
            .pending
        )
    }

    func testDeterministicLeaseFailuresTerminatePolling() {
        let failures: [ClaudeOAuthRefreshCoordinatorError] = [
            .ambiguousConfiguration("unsupported"),
            .unsafePath(path: "/tmp/unsafe", reason: "not owned"),
            .missingLease,
            .leaseLost(lock: .claude),
            .leaseReleased,
            .fileSystem(path: "/tmp/lock", operation: "create", code: 13)
        ]

        for failure in failures {
            XCTAssertEqual(
                LoginCompletionOutcome(leaseAcquisitionError: failure),
                .failed
            )
        }
    }
}
