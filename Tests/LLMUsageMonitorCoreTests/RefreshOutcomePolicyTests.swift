import XCTest
@testable import LLMUsageMonitorCore

final class RefreshOutcomePolicyTests: XCTestCase {
    func testNoCredentialsAlwaysNeedsLoginNoFallback() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .noCredentials, isActiveCLI: active)
            XCTAssertTrue(outcome.state.requiresLogin)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testKeychainLockedSurfacesAndNeverFallsBack() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .keychainLocked, isActiveCLI: active)
            XCTAssertEqual(outcome.state, .keychainLocked)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testRepeatedUnauthorizedAlwaysNeedsLoginWithoutFallback() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .unauthorized, isActiveCLI: active)
            XCTAssertTrue(outcome.state.requiresLogin)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testTransportFailureIsReadFailedAndActiveFallsBack() {
        let error = ClaudeAccountUsageFetchError.transport(URLError(.timedOut))
        let active = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: true)
        guard case .readFailed = active.state else {
            return XCTFail("Expected readFailed, got \(active.state)")
        }
        XCTAssertTrue(active.attemptTUIFallback)

        let inactive = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: false)
        guard case .readFailed = inactive.state else {
            return XCTFail("Expected readFailed, got \(inactive.state)")
        }
        XCTAssertFalse(inactive.attemptTUIFallback)
    }

    func testRefreshFailedCarriesReason() {
        let error = ClaudeAccountUsageFetchError.refreshFailed(ClaudeUsageAPIError.malformedResponse)
        let outcome = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: false)
        guard case .readFailed(let reason) = outcome.state else {
            return XCTFail("Expected readFailed, got \(outcome.state)")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testPermanentRefreshFailureRequiresLogin() {
        let error = ClaudeAccountUsageFetchError.refreshFailed(
            ClaudeOAuthError.refreshRejected(status: 400, body: #"{"error":"invalid_grant"}"#)
        )
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: active)
            XCTAssertTrue(outcome.state.requiresLogin)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }
}
