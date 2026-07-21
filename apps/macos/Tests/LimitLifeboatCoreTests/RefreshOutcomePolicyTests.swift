import XCTest
@testable import LimitLifeboatCore

final class RefreshOutcomePolicyTests: XCTestCase {
    func testNoCredentialsDefersLoginPresentationToStoredAvailability() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .noCredentials, isActiveCLI: active)
            XCTAssertEqual(outcome.state, .idle)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testKeychainLockedRequiresSourceSpecificAuthorizationAndNeverFallsBack() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .keychainLocked, isActiveCLI: active)
            guard case .authorizationRequired(let source, _) = outcome.state else {
                return XCTFail("Expected authorizationRequired, got \(outcome.state)")
            }
            XCTAssertEqual(source, active ? .claudeCode : .savedAccount)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testTypedLiveWriteDenialSurfacesAndNeverFallsBack() {
        let item = ClaudeKeychainItemLocation(
            serviceName: ClaudeCodeCredentialsKeychain.serviceName,
            accountName: "test",
            keychainPath: "/tmp/disposable.keychain-db",
            persistentReference: Data("item".utf8),
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 1)
        )
        let error = ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
            error: .keychainError(errSecInteractionNotAllowed),
            item: item
        )

        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: active)
            guard case .authorizationRequired(let source, _) = outcome.state else {
                return XCTFail("Expected authorizationRequired, got \(outcome.state)")
            }
            XCTAssertEqual(source, .claudeCode)
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

    func testForbiddenIsNonterminalAndNeverFallsBack() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .forbidden, isActiveCLI: active)
            guard case .providerAccessForbidden(let reason) = outcome.state else {
                return XCTFail("Expected providerAccessForbidden, got \(outcome.state)")
            }
            XCTAssertTrue(reason.lowercased().contains("administrator"))
            XCTAssertFalse(outcome.state.requiresLogin)
            XCTAssertFalse(outcome.attemptTUIFallback)
        }
    }

    func testInteractiveRefreshRequiredMapsToRotationDeferred() {
        let outcome = RefreshOutcomePolicy.outcome(
            for: .interactiveRefreshRequired,
            isActiveCLI: true
        )
        guard case .rotationDeferred = outcome.state else {
            return XCTFail("Expected rotationDeferred, got \(outcome.state)")
        }
        XCTAssertFalse(outcome.attemptTUIFallback)
        // A paused login is not expired: it keeps its healthy switch affordance.
        XCTAssertFalse(outcome.state.requiresLogin)
        XCTAssertTrue(outcome.state.isProblem)
    }

    func testCoordinatorDeferralMapsToRotationDeferredWithoutFallback() {
        let outcome = RefreshOutcomePolicy.outcome(
            for: .rotationDeferred(URLError(.resourceUnavailable)),
            isActiveCLI: true
        )

        guard case .rotationDeferred(let reason) = outcome.state else {
            return XCTFail("Expected rotationDeferred, got \(outcome.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(outcome.state.requiresLogin)
        XCTAssertFalse(outcome.attemptTUIFallback)
    }

    func testAccountActiveElsewhereRequiresSwitchWithoutFallback() {
        for active in [true, false] {
            let outcome = RefreshOutcomePolicy.outcome(for: .accountActiveElsewhere, isActiveCLI: active)
            guard case .switchRequired(let reason) = outcome.state else {
                return XCTFail("Expected switchRequired, got \(outcome.state)")
            }
            XCTAssertTrue(reason.lowercased().contains("switch"))
            XCTAssertFalse(outcome.attemptTUIFallback)
            XCTAssertFalse(outcome.state.requiresLogin)
        }
    }

    func testCredentialRepairFailureStaysRetryableAndNeverRequiresLogin() {
        let error = ClaudeAccountUsageFetchError.credentialRepairRequired(
            ClaudeCredentialRepairRequiredError(reason: "Fresh credentials are safely journaled.")
        )
        let outcome = RefreshOutcomePolicy.outcome(for: error, isActiveCLI: true)

        guard case .credentialRepairRequired(let reason) = outcome.state else {
            return XCTFail("Expected credentialRepairRequired, got \(outcome.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(outcome.state.requiresLogin)
        XCTAssertFalse(outcome.attemptTUIFallback)
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

    func testUnsafeCredentialStateNeverFallsBackToCLI() {
        let outcome = RefreshOutcomePolicy.outcome(
            for: .credentialUnavailable(
                ClaudeCodeCredentialsKeychainError.malformedCredentialJSON("test")
            ),
            isActiveCLI: true
        )
        guard case .readFailed = outcome.state else {
            return XCTFail("Expected readFailed, got \(outcome.state)")
        }
        XCTAssertFalse(outcome.attemptTUIFallback)
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
