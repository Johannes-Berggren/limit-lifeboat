import XCTest
@testable import LimitLifeboatCore

final class AccountSessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testExactFiveDayBoundaryShowsRenewalAndRemainsSwitchable() {
        let evaluation = evaluate(
            refreshState: .ok,
            expiresAt: now.addingTimeInterval(AccountSessionPolicy.loginExpiryWarningInterval)
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.text), ["Login expires in 5 days"])
        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.renew])
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertTrue(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testBeyondFiveDayBoundaryHasNoExpiryMessage() {
        let evaluation = evaluate(
            refreshState: .ok,
            expiresAt: now.addingTimeInterval(AccountSessionPolicy.loginExpiryWarningInterval + 0.001)
        )

        XCTAssertTrue(evaluation.rowMessages.isEmpty)
    }

    func testExpiryAtNowRequiresLoginAndBlocksEverySwitchSource() {
        let evaluation = evaluate(refreshState: .ok, expiresAt: now)

        XCTAssertEqual(evaluation.rowMessages.first?.action, .login)
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testUnreadableStoredCredentialOutranksCachedExpiry() {
        let evaluation = evaluate(
            storedCredentials: .authorizationRequired(source: .savedAccount),
            refreshState: .ok,
            expiresAt: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(evaluation.rowMessages.count, 1)
        XCTAssertEqual(evaluation.rowMessages.first?.text, "Keychain access needed")
        XCTAssertEqual(evaluation.rowMessages.first?.action, .authorize(source: .savedAccount))
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testBlockedCodeSignatureOffersRelaunchInsteadOfAuthorizationOrLogin() {
        let evaluation = evaluate(
            storedCredentials: .accessBlocked(
                source: .claudeCode,
                disposition: .codeSignatureInvalid,
                reason: ""
            ),
            refreshState: .ok,
            expiresAt: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Credential access blocked")
        XCTAssertEqual(evaluation.rowMessages.first?.action, AccountRowAction.none)
        XCTAssertTrue(evaluation.rowMessages.first?.help.lowercased().contains("relaunch") == true)
    }

    func testTerminalRefreshStateRequiresLoginBeforeMissingCredentialFallback() {
        let evaluation = evaluate(
            storedCredentials: .missing,
            refreshState: .needsLogin(reason: "invalid_grant"),
            expiresAt: nil,
            wasPreviouslyLinked: true
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Login expired — sign in again")
        XCTAssertEqual(evaluation.rowMessages.first?.help, "invalid_grant")
        XCTAssertEqual(evaluation.rowMessages.first?.action, .login)
    }

    func testMissingCredentialIsNotSwitchableAndOffersLogin() {
        let evaluation = evaluate(
            storedCredentials: .missing,
            refreshState: .idle,
            expiresAt: nil,
            wasPreviouslyLinked: false
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Not linked — log in to track usage")
        XCTAssertEqual(evaluation.rowMessages.first?.action, .login)
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testActiveAccountWithoutRestorableSnapshotIsNotTreatedAsExpired() {
        // The active account's live CLI credential is authoritative; a missing
        // *restorable snapshot* must not surface a false "Login expired" row or
        // block switching for a healthy, currently-active login.
        let evaluation = evaluate(
            storedCredentials: .missing,
            refreshState: .ok,
            expiresAt: nil,
            isActiveCLI: true,
            wasPreviouslyLinked: true
        )

        XCTAssertTrue(evaluation.rowMessages.isEmpty)
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertTrue(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testActiveAccountMissingSnapshotStillHonorsGenuineExpiry() {
        // Exempting the active account from the missing-snapshot block must not
        // suppress a genuinely expired login, which is decided earlier.
        let evaluation = evaluate(
            storedCredentials: .missing,
            refreshState: .ok,
            expiresAt: now,
            isActiveCLI: true,
            wasPreviouslyLinked: true
        )

        XCTAssertEqual(evaluation.rowMessages.first?.action, .login)
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
    }

    func testSharedExpiringLoginUsesSwitchInsteadOfRenewAndNeverAutoSwitches() {
        let evaluation = evaluate(
            refreshState: .switchRequired(reason: "Shared with the live CLI login."),
            expiresAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            isActiveCLI: false
        )

        XCTAssertEqual(evaluation.rowMessages.count, 1)
        XCTAssertEqual(evaluation.rowMessages.first?.action, .switchCLI)
        XCTAssertTrue(evaluation.rowMessages.first?.help.contains("Switch") == true)
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testKnownSharedChainOffersSwitchBeforeARefreshFailureOccurs() {
        let evaluation = evaluate(
            refreshState: .ok,
            expiresAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.switchCLI])
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        // A still-valid credential remains read-only-switchable; chain sharing
        // changes renewal UX, while rotationDeferred controls auto eligibility.
        XCTAssertTrue(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testIndependentExpiryKeepsCompatibleRetryAsSecondMessage() {
        let evaluation = evaluate(
            refreshState: .readFailed(reason: "Offline"),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60)
        )

        XCTAssertEqual(evaluation.rowMessages.count, 2)
        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.renew, .retry])
        XCTAssertEqual(evaluation.rowMessages[1].help, "Offline")
    }

    func testSharedExpiryKeepsRepairRetryAsSecondMessage() {
        let evaluation = evaluate(
            refreshState: .credentialRepairRequired(reason: "Fresh credentials are safely journaled."),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.switchCLI, .retry])
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
    }

    func testSharedExpiryKeepsTransientRetryAsSecondMessage() {
        let evaluation = evaluate(
            refreshState: .readFailed(reason: "Offline"),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.switchCLI, .retry])
        XCTAssertEqual(evaluation.rowMessages[1].help, "Offline")
    }

    func testSharedExpiryKeepsDeferredRotationRetryAsSecondMessage() {
        let evaluation = evaluate(
            refreshState: .rotationDeferred(reason: "The shared lease is busy."),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.switchCLI, .retry])
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testRotationDeferredAllowsManualButBlocksAutomaticSwitch() {
        let evaluation = evaluate(
            refreshState: .rotationDeferred(reason: "Scheduled reads cannot rotate."),
            expiresAt: nil
        )

        XCTAssertEqual(evaluation.rowMessages.first?.action, .retry)
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testCredentialRepairBlocksSwitchUntilRetryCompletes() {
        let evaluation = evaluate(
            refreshState: .credentialRepairRequired(reason: "Fresh credentials are safely journaled."),
            expiresAt: nil
        )

        XCTAssertEqual(evaluation.rowMessages.first?.action, .retry)
        XCTAssertFalse(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
        XCTAssertTrue(evaluation.manualSwitchEligibility.blockerReason?.contains("Repair") == true)
    }

    func testForbiddenUsageAccessOffersRenewalWithoutClaimingLoginExpired() {
        let evaluation = evaluate(
            refreshState: .providerAccessForbidden(reason: "Ask your administrator."),
            expiresAt: nil
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Usage access denied")
        XCTAssertEqual(evaluation.rowMessages.first?.action, .renew)
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertFalse(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testSharedForbiddenUsageRequiresSwitchInsteadOfInactiveRenewal() {
        let evaluation = evaluate(
            refreshState: .providerAccessForbidden(reason: "Ask your administrator."),
            expiresAt: nil,
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Usage access denied")
        XCTAssertEqual(evaluation.rowMessages.first?.action, .switchCLI)
        XCTAssertTrue(evaluation.rowMessages.first?.help.contains("Switch the CLI") == true)
    }

    func testSharedExpiryRetainsForbiddenGuidanceWithoutDuplicateSwitchButton() {
        let evaluation = evaluate(
            refreshState: .providerAccessForbidden(reason: "Ask your administrator."),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            isActiveCLI: false,
            sharesActiveCredentialChain: true
        )

        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.switchCLI, .none])
        XCTAssertEqual(evaluation.rowMessages[1].text, "Usage access denied")
    }

    func testExpiryAndForbiddenGuidanceDoNotDuplicateRenewButtons() {
        let evaluation = evaluate(
            refreshState: .providerAccessForbidden(reason: "Ask your administrator."),
            expiresAt: now.addingTimeInterval(4 * 24 * 60 * 60)
        )

        XCTAssertEqual(evaluation.rowMessages.count, 2)
        XCTAssertEqual(evaluation.rowMessages.map(\.action), [.renew, .none])
    }

    func testCodexIgnoresClaudeFixedExpiryMetadata() {
        let evaluation = AccountSessionPolicy.evaluate(
            provider: .codex,
            isActiveCLI: false,
            wasPreviouslyLinked: true,
            storedCredentials: .available,
            refreshState: .ok,
            loginExpiresAt: now.addingTimeInterval(-60),
            now: now
        )

        XCTAssertTrue(evaluation.rowMessages.isEmpty)
        XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        XCTAssertTrue(evaluation.automaticSwitchEligibility.isEligible)
    }

    func testRefreshStateAuthorizationCarriesExactSourceToAction() {
        let evaluation = evaluate(
            refreshState: .authorizationRequired(
                source: .claudeCode,
                reason: "Always Allow is required."
            ),
            expiresAt: nil
        )

        XCTAssertEqual(evaluation.rowMessages.first?.action, .authorize(source: .claudeCode))
        XCTAssertEqual(evaluation.rowMessages.first?.help, "Always Allow is required.")
    }

    // MARK: - Transient failures over still-current numbers

    /// The complaint this exists to fix: a throttled cycle used to put an
    /// orange "Couldn't refresh" on every card while all of them were showing
    /// numbers read minutes ago.
    func testTransientFailuresStaySilentWhileTheReadingIsRecent() {
        for state: AccountRefreshState in [
            .readFailed(reason: "The Anthropic usage API responded with status 502."),
            .rateLimited(retryAt: now.addingTimeInterval(4 * 60))
        ] {
            let evaluation = evaluate(
                refreshState: state,
                expiresAt: nil,
                lastSuccessfulRefresh: now.addingTimeInterval(-3 * 60)
            )
            XCTAssertTrue(evaluation.rowMessages.isEmpty, "\(state)")
            // Silence is not a block: the account is still switchable.
            XCTAssertTrue(evaluation.manualSwitchEligibility.isEligible)
        }
    }

    func testTransientFailuresSurfaceOnceTheReadingAges() {
        let stale = now.addingTimeInterval(-20 * 60)

        let readFailed = evaluate(
            refreshState: .readFailed(reason: "boom"),
            expiresAt: nil,
            lastSuccessfulRefresh: stale
        )
        XCTAssertEqual(readFailed.rowMessages.first?.text, "Couldn't refresh")
        XCTAssertEqual(readFailed.rowMessages.first?.tone, .warning)

        let throttled = evaluate(
            refreshState: .rateLimited(retryAt: now.addingTimeInterval(4 * 60)),
            expiresAt: nil,
            lastSuccessfulRefresh: stale
        )
        // Calm, not alarming: nothing here is the user's to fix.
        XCTAssertEqual(throttled.rowMessages.first?.text, "Usage service busy — retrying in 4m")
        XCTAssertEqual(throttled.rowMessages.first?.tone, .stale)
        XCTAssertEqual(throttled.rowMessages.first?.action, .retry)
    }

    func testThrottleWithoutARetryInstantStillReads() {
        let evaluation = evaluate(
            refreshState: .rateLimited(retryAt: nil),
            expiresAt: nil,
            lastSuccessfulRefresh: now.addingTimeInterval(-20 * 60)
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Usage service busy — retrying shortly")
    }

    func testWithNoReadingToProtectATransientFailureReportsImmediately() {
        let evaluation = evaluate(
            refreshState: .readFailed(reason: "boom"),
            expiresAt: nil,
            lastSuccessfulRefresh: nil
        )

        XCTAssertEqual(evaluation.rowMessages.first?.text, "Couldn't refresh")
    }

    /// The grace covers self-healing reads only. Anything needing the user is
    /// reported however fresh the numbers are.
    func testActionableStatesAreNeverSuppressedByTheGrace() {
        let recent = now.addingTimeInterval(-30)
        let actionable: [AccountRefreshState] = [
            .needsLogin(reason: "Log in again."),
            .providerAccessForbidden(reason: "Ask your administrator."),
            .credentialRepairRequired(reason: "Repair needed."),
            .switchRequired(reason: "Switch first."),
            .usagePaused
        ]

        for state in actionable {
            let evaluation = evaluate(
                refreshState: state,
                expiresAt: nil,
                lastSuccessfulRefresh: recent
            )
            XCTAssertFalse(evaluation.rowMessages.isEmpty, "\(state)")
        }
    }

    private func evaluate(
        storedCredentials: StoredCredentialAvailability = .available,
        refreshState: AccountRefreshState,
        expiresAt: Date?,
        isActiveCLI: Bool = false,
        sharesActiveCredentialChain: Bool = false,
        wasPreviouslyLinked: Bool = true,
        lastSuccessfulRefresh: Date? = nil
    ) -> AccountSessionEvaluation {
        AccountSessionPolicy.evaluate(
            provider: .claude,
            isActiveCLI: isActiveCLI,
            wasPreviouslyLinked: wasPreviouslyLinked,
            storedCredentials: storedCredentials,
            sharesActiveCredentialChain: sharesActiveCredentialChain,
            refreshState: refreshState,
            loginExpiresAt: expiresAt,
            lastSuccessfulRefresh: lastSuccessfulRefresh,
            now: now
        )
    }
}
