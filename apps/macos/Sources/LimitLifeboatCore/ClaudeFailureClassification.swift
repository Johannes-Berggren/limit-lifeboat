import Foundation

/// Maps a Claude usage fetch failure to the durable credential outcome
/// recorded in the event log. Sibling of `RefreshOutcomePolicy`, which maps
/// the same errors to transient row state: this one answers "what should the
/// permanent record say", that one "what should the row show now".
public enum ClaudeCredentialOutcomePolicy {
    /// The outcome to record, or nil for transient noise (network, absent
    /// token, denied Keychain) that must not disturb a profile's recorded
    /// episode. A locked or denied Keychain is an access problem, not a
    /// credential outcome — it surfaces via the Keychain row state and its
    /// own logging.
    public static func outcome(
        for error: ClaudeAccountUsageFetchError
    ) -> AppEvent.CredentialOutcome? {
        switch error {
        case .interactiveRefreshRequired:
            return .rotationDeferred
        case .accountActiveElsewhere:
            return .switchRequired
        case .rotationDeferred(let underlying):
            return coordinatorOutcome(underlying) ?? .rotationDeferred
        case .credentialRepairRequired:
            return .repairRequired
        case .credentialRecoveryFailed:
            return .persistenceFailed
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .forbidden
        case .refreshFailed(let underlying):
            if let outcome = coordinatorOutcome(underlying) {
                return outcome
            }
            if let oauth = underlying as? ClaudeOAuthError, oauth.requiresLogin {
                return .invalidGrant
            }
            return .refreshFailed
        case .keychainLocked, .liveCredentialAccessDenied, .credentialUnavailable,
             .accountMismatch, .noCredentials, .transport:
            return nil
        }
    }

    /// Rotation and refresh failures wrap the same coordinator errors and
    /// classify them identically.
    private static func coordinatorOutcome(_ error: Error) -> AppEvent.CredentialOutcome? {
        guard let error = error as? ClaudeOAuthRefreshCoordinatorError else {
            return nil
        }
        switch error {
        case .busy:
            return .rotationBusy
        case .leaseLost, .leaseReleased, .missingLease:
            return .leaseLost
        case .ambiguousConfiguration, .unsafePath, .fileSystem:
            return .rotationDeferred
        }
    }
}

/// A provider-Keychain failure that must not harden into a sticky
/// authorization denial.
public enum TransientClaudeKeychainFailure: Equatable, Sendable {
    case itemChanged
    case keychainLocked
}

public enum ClaudeKeychainFailurePolicy {
    /// Restore, refresh, and usage workflows preserve their root cause inside
    /// typed wrapper errors. Unwraps only the two transient outcomes that must
    /// not become a sticky authorization denial. The depth bound also protects
    /// this path from a pathological custom Error that wraps itself.
    public static func transientFailure(
        in error: Error,
        depth: Int = 0
    ) -> TransientClaudeKeychainFailure? {
        guard depth < 12 else { return nil }
        let nextDepth = depth + 1

        if let keychainError = error as? ClaudeCodeCredentialsKeychainError {
            switch keychainError {
            case .securityToolError(.itemChanged):
                return .itemChanged
            case .securityToolError(.keychainLocked):
                return .keychainLocked
            case .credentialAccessUnavailable(let underlying):
                return transientFailure(in: underlying, depth: nextDepth)
            default:
                return nil
            }
        }

        if let switchError = error as? CLISwitcherError {
            switch switchError {
            case .backupFailed(_, let underlying),
                 .rollbackConflict(_, _, let underlying, _):
                return transientFailure(in: underlying, depth: nextDepth)
            default:
                return nil
            }
        }

        if let fetchError = error as? ClaudeAccountUsageFetchError {
            switch fetchError {
            case .keychainLocked:
                return .keychainLocked
            case .liveCredentialAccessDenied(let underlying, _):
                return transientFailure(in: underlying, depth: nextDepth)
            case .rotationDeferred(let underlying),
                 .credentialRepairRequired(let underlying),
                 .credentialRecoveryFailed(let underlying),
                 .credentialUnavailable(let underlying),
                 .refreshFailed(let underlying),
                 .transport(let underlying):
                return transientFailure(in: underlying, depth: nextDepth)
            default:
                return nil
            }
        }

        if let storeError = error as? CredentialStoreError {
            switch storeError {
            case .credentialAccessUnavailable(let underlying):
                return transientFailure(in: underlying, depth: nextDepth)
            case .decodeFailed(let underlying?):
                return transientFailure(in: underlying, depth: nextDepth)
            default:
                return nil
            }
        }

        return nil
    }
}
