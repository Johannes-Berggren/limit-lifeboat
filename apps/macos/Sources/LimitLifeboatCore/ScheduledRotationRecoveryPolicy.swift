import Foundation

/// Decides whether a scheduled cycle may automatically run the Retry workflow
/// for a Claude account whose read-only fetch was deferred. Automatic recovery
/// is limited to inactive accounts whose refresh chain no other holder relies
/// on; the shared refresh lease prevents races with the live login. Pure so
/// the eligibility and backoff rules are unit-testable; AppState owns the
/// per-profile ledger and the actual recovery flight.
public struct ScheduledRotationRecoveryPolicy: Sendable {
    /// Outcome of the most recent automatic attempt for one profile. Callers
    /// clear the record on any successful snapshot or explicit user action,
    /// which re-arms the next expiry episode.
    public struct AttemptRecord: Equatable, Sendable {
        public var lastAttempt: Date
        public var consecutiveFailures: Int

        public init(lastAttempt: Date, consecutiveFailures: Int) {
            self.lastAttempt = lastAttempt
            self.consecutiveFailures = consecutiveFailures
        }
    }

    /// Minimum spacing between automatic attempts for one profile. Keeps a
    /// flaky account from spending a token exchange every poll cycle.
    public var cooloff: TimeInterval
    /// After this many consecutive failures the account waits for the user
    /// (Retry) or a fresh snapshot before automating again.
    public var maxConsecutiveFailures: Int

    public init(
        cooloff: TimeInterval = 30 * 60,
        maxConsecutiveFailures: Int = 3
    ) {
        self.cooloff = cooloff
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    /// Eligible errors are exactly the two deferrals the manual Retry path
    /// heals: an expired token whose rotation was declined by the read-only
    /// intent, and a pending recovery-journal repair. Terminal login failures,
    /// keychain problems, and transport errors stay with the user — retrying
    /// them automatically either cannot succeed or would spend tokens blindly.
    public func shouldAttempt(
        after error: ClaudeAccountUsageFetchError,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        previous: AttemptRecord?,
        now: Date
    ) -> Bool {
        guard !isActiveCLI, !accountIsLiveElsewhere else { return false }
        switch error {
        case .interactiveRefreshRequired, .credentialRepairRequired:
            break
        default:
            return false
        }
        guard let previous else { return true }
        guard previous.consecutiveFailures < maxConsecutiveFailures else { return false }
        return now.timeIntervalSince(previous.lastAttempt) >= cooloff
    }
}
