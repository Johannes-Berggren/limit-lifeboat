import Foundation

/// The visible state of a single account's most recent usage refresh, so a
/// failed read surfaces as a retryable affordance in the row instead of the
/// row silently aging into staleness with no explanation.
public enum AccountRefreshState: Equatable, Sendable {
    /// No refresh attempted yet, or the last one succeeded and nothing needs
    /// saying — the row shows its usage normally.
    case idle
    case refreshing
    case ok
    /// A transient read failure (network, server, malformed) — retryable.
    case readFailed(reason: String)
    /// The account has no usable captured credentials, or its saved refresh
    /// token can no longer recover the session. The reason is safe to surface
    /// to the user and must never contain credential material.
    case needsLogin(reason: String)
    /// The Keychain is locked or access was denied — distinct from "no
    /// credentials" so the UI can prompt to grant access rather than hiding the
    /// account's Switch affordance.
    case keychainLocked

    /// Whether this state represents a problem worth showing an affordance for.
    public var isProblem: Bool {
        switch self {
        case .idle, .refreshing, .ok:
            return false
        case .readFailed, .needsLogin, .keychainLocked:
            return true
        }
    }

    public var requiresLogin: Bool {
        if case .needsLogin = self {
            return true
        }
        return false
    }
}

/// What a Claude usage-fetch failure should do to the account: which visible
/// state to show, and whether the active account should still try the local
/// `/usage` CLI probe as a fallback. Pure so the branching that used to be a
/// swallowed `catch` is directly testable.
public struct RefreshOutcome: Equatable, Sendable {
    public var state: AccountRefreshState
    /// Only meaningful for the active account: attempt the slow CLI probe when
    /// the account-wide API failed for a reason the local read might survive.
    public var attemptTUIFallback: Bool

    public init(state: AccountRefreshState, attemptTUIFallback: Bool) {
        self.state = state
        self.attemptTUIFallback = attemptTUIFallback
    }
}

public enum RefreshOutcomePolicy {
    public static func outcome(for error: ClaudeAccountUsageFetchError, isActiveCLI: Bool) -> RefreshOutcome {
        switch error {
        case .noCredentials:
            // Expected until the account has been the active login once. No CLI
            // fallback — there is nothing to read.
            return RefreshOutcome(
                state: .needsLogin(reason: "No captured OAuth credentials are available for this account."),
                attemptTUIFallback: false
            )
        case .keychainLocked:
            return RefreshOutcome(state: .keychainLocked, attemptTUIFallback: false)
        case .interactiveRefreshRequired:
            return RefreshOutcome(
                state: .readFailed(
                    reason: "The active Claude login needs an explicit Retry before Limit Lifeboat can rotate it safely."
                ),
                attemptTUIFallback: false
            )
        case .unauthorized:
            // The API already tried one forced token refresh. A second
            // rejection confirms that this saved login needs user recovery;
            // retain the last reading instead of letting a CLI fallback hide
            // the expired-login state.
            return RefreshOutcome(
                state: .needsLogin(reason: "The provider rejected this account's credentials."),
                attemptTUIFallback: false
            )
        case .refreshFailed(let underlying):
            if let oauthError = underlying as? ClaudeOAuthError,
               oauthError.requiresLogin {
                return RefreshOutcome(
                    state: .needsLogin(reason: reason(oauthError)),
                    attemptTUIFallback: false
                )
            }
            return RefreshOutcome(
                state: .readFailed(reason: reason(underlying)),
                attemptTUIFallback: isActiveCLI
            )
        case .transport(let underlying):
            return RefreshOutcome(
                state: .readFailed(reason: reason(underlying)),
                attemptTUIFallback: isActiveCLI
            )
        }
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
