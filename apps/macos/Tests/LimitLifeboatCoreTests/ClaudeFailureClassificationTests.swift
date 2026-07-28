import XCTest
@testable import LimitLifeboatCore

/// These two classifiers lived in AppState as private members and so were
/// unreachable from tests. They decide what the durable event log records and
/// whether a Keychain failure hardens into a sticky authorization denial, so
/// they are worth pinning.
final class ClaudeCredentialOutcomePolicyTests: XCTestCase {
    private func outcome(_ error: ClaudeAccountUsageFetchError) -> AppEvent.CredentialOutcome? {
        ClaudeCredentialOutcomePolicy.outcome(for: error)
    }

    func testAccessProblemsAreNotRecordedAsCredentialOutcomes() {
        // A locked or denied Keychain is surfaced via row state, not the log.
        XCTAssertNil(outcome(.keychainLocked))
        XCTAssertNil(outcome(.noCredentials))
        XCTAssertNil(outcome(.transport(SampleError.boom)))
        XCTAssertNil(outcome(.credentialUnavailable(SampleError.boom)))
        XCTAssertNil(outcome(.accountMismatch))
        XCTAssertNil(
            outcome(.liveCredentialAccessDenied(error: .missingLiveItem, item: nil))
        )
    }

    func testDirectFailuresMapToTheirOutcome() {
        XCTAssertEqual(outcome(.interactiveRefreshRequired), .rotationDeferred)
        XCTAssertEqual(outcome(.accountActiveElsewhere), .switchRequired)
        XCTAssertEqual(outcome(.unauthorized), .unauthorized)
        XCTAssertEqual(outcome(.forbidden), .forbidden)
        XCTAssertEqual(
            outcome(.credentialRepairRequired(SampleError.boom)),
            .repairRequired
        )
        XCTAssertEqual(
            outcome(.credentialRecoveryFailed(SampleError.boom)),
            .persistenceFailed
        )
    }

    /// rotationDeferred and refreshFailed wrap the same coordinator errors and
    /// must classify them identically — they were separate copies of one
    /// switch before this policy was extracted.
    func testCoordinatorErrorsClassifyTheSameThroughBothWrappers() {
        let cases: [(ClaudeOAuthRefreshCoordinatorError, AppEvent.CredentialOutcome)] = [
            (.busy(lock: .oauthRefresh), .rotationBusy),
            (.leaseLost(lock: .claude), .leaseLost),
            (.leaseReleased, .leaseLost),
            (.missingLease, .leaseLost),
            (.unsafePath(path: "/tmp/x", reason: "symlink"), .rotationDeferred),
            (.ambiguousConfiguration("no home"), .rotationDeferred),
            (.fileSystem(path: "/tmp/x", operation: "open", code: 13), .rotationDeferred)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(outcome(.rotationDeferred(error)), expected, "rotationDeferred(\(error))")
            XCTAssertEqual(outcome(.refreshFailed(error)), expected, "refreshFailed(\(error))")
        }
    }

    func testRefreshFailureFallsBackByUnderlyingCause() {
        // A non-coordinator, non-login failure stays a plain refresh failure.
        XCTAssertEqual(outcome(.refreshFailed(SampleError.boom)), .refreshFailed)
    }

    func testRotationDeferredFallsBackWhenNotACoordinatorError() {
        XCTAssertEqual(outcome(.rotationDeferred(SampleError.boom)), .rotationDeferred)
    }
}

final class ClaudeKeychainFailurePolicyTests: XCTestCase {
    private func transient(_ error: Error) -> TransientClaudeKeychainFailure? {
        ClaudeKeychainFailurePolicy.transientFailure(in: error)
    }

    func testRecognizesTheTwoTransientOutcomesDirectly() {
        XCTAssertEqual(
            transient(ClaudeCodeCredentialsKeychainError.securityToolError(.itemChanged)),
            .itemChanged
        )
        XCTAssertEqual(
            transient(ClaudeCodeCredentialsKeychainError.securityToolError(.keychainLocked)),
            .keychainLocked
        )
        XCTAssertEqual(transient(ClaudeAccountUsageFetchError.keychainLocked), .keychainLocked)
    }

    func testUnwrapsThroughTypedWrappers() {
        let locked = ClaudeCodeCredentialsKeychainError.securityToolError(.keychainLocked)
        XCTAssertEqual(
            transient(
                ClaudeAccountUsageFetchError.liveCredentialAccessDenied(error: locked, item: nil)
            ),
            .keychainLocked
        )
        XCTAssertEqual(
            transient(ClaudeAccountUsageFetchError.refreshFailed(locked)),
            .keychainLocked
        )
        XCTAssertEqual(
            transient(CredentialStoreError.credentialAccessUnavailable(underlying: locked)),
            .keychainLocked
        )
        XCTAssertEqual(
            transient(
                ClaudeCodeCredentialsKeychainError.credentialAccessUnavailable(underlying: locked)
            ),
            .keychainLocked
        )
    }

    func testUnwrapsThroughSeveralNestedLayers() {
        let changed = ClaudeCodeCredentialsKeychainError.securityToolError(.itemChanged)
        let nested = ClaudeAccountUsageFetchError.rotationDeferred(
            CredentialStoreError.credentialAccessUnavailable(underlying: changed)
        )
        XCTAssertEqual(
            transient(ClaudeAccountUsageFetchError.transport(nested)),
            .itemChanged
        )
    }

    func testUnrelatedFailuresAreNotTransient() {
        XCTAssertNil(transient(SampleError.boom))
        XCTAssertNil(transient(ClaudeAccountUsageFetchError.unauthorized))
        XCTAssertNil(transient(CredentialStoreError.decodeFailed(underlying: nil)))
        XCTAssertNil(transient(ClaudeCodeCredentialsKeychainError.missingLiveItem))
    }

    /// The depth bound exists so a deeply nested (or self-wrapping) Error
    /// cannot spin this UI-state path. Past the bound it must give up and
    /// report nothing rather than recurse away.
    func testGivesUpPastTheDepthBound() {
        let locked = ClaudeCodeCredentialsKeychainError.securityToolError(.keychainLocked)
        var chain: Error = locked
        for _ in 0..<50 {
            chain = CredentialStoreError.credentialAccessUnavailable(underlying: chain)
        }
        XCTAssertNil(transient(chain))

        // Just inside the bound it still resolves, proving the nil above is
        // the depth guard and not a broken unwrap.
        var shallow: Error = locked
        for _ in 0..<5 {
            shallow = CredentialStoreError.credentialAccessUnavailable(underlying: shallow)
        }
        XCTAssertEqual(transient(shallow), .keychainLocked)
    }
}

private enum SampleError: Error {
    case boom
}
