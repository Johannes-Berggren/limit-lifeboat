import XCTest
@testable import LLMUsageMonitorCore

final class RefreshOutcomePolicyTests: XCTestCase {
    func testNoCredentialsAlwaysNeedsLoginNoFallback() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .noCredentials, isActiveCLI: active)
            XCTAssertEqual(outcome.state, .needsLogin)
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

    func testUnauthorizedActiveTriesTUIFallbackInactiveNeedsLogin() {
        let active = RefreshOutcomePolicy.outcome(for: .unauthorized, isActiveCLI: true)
        XCTAssertEqual(active.state, .refreshing)
        XCTAssertTrue(active.attemptTUIFallback)

        let inactive = RefreshOutcomePolicy.outcome(for: .unauthorized, isActiveCLI: false)
        XCTAssertEqual(inactive.state, .needsLogin)
        XCTAssertFalse(inactive.attemptTUIFallback)
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
}
