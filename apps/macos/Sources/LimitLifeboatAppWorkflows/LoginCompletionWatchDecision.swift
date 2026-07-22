import LimitLifeboatCore

/// Result of inspecting a login whose credential metadata has changed.
package enum LoginCompletionOutcome: Sendable, Equatable {
    case pending
    case completed
    case authorizationRequired(source: CredentialAuthorizationSource)
    case failed

    /// Only denial of Claude's provider-owned item can be repaired by the
    /// More-menu authorization action that resumes a pending login. App-owned
    /// saved credential denials require their profile-specific authorization
    /// path and must not leave a resumable Claude completion behind.
    package var retainsPendingClaudeLoginCompletion: Bool {
        self == .authorizationRequired(source: .claudeCode)
    }

    /// Another process holding Claude's shared OAuth lock is temporary. Every
    /// other coordinator failure describes an unsafe or broken lease setup and
    /// must release the login watcher rather than retrying for its full window.
    package init(leaseAcquisitionError: ClaudeOAuthRefreshCoordinatorError) {
        if case .busy = leaseAcquisitionError {
            self = .pending
        } else {
            self = .failed
        }
    }
}

/// Keeps the watcher loop's one continuation rule independently testable.
package enum LoginCompletionWatchDecision: Sendable, Equatable {
    case continuePolling
    case stopPolling

    package init(outcome: LoginCompletionOutcome) {
        self = outcome == .pending ? .continuePolling : .stopPolling
    }
}
