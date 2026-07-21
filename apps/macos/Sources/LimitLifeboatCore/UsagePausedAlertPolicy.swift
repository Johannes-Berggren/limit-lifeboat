import Foundation

/// Decides when to nudge the user that the active Claude account's usage
/// tracking has been paused too long. The active login's access token can
/// expire while the CLI is idle; a background cycle then declines to rotate it
/// (rotating the live login is what causes real logouts), leaving the row in
/// `.usagePaused` until an explicit Retry. Without a nudge this can sit silent
/// for hours and read as "logged out". Pure so the timing is unit-testable;
/// `UsageAlertController` owns the actual posting.
public struct UsagePausedAlertPolicy: Sendable {
    /// How long the active account may stay paused before it's worth a
    /// notification. Time-based rather than cycle-based because the refresh
    /// interval is user-configurable.
    public var threshold: TimeInterval

    public init(threshold: TimeInterval = 15 * 60) {
        self.threshold = threshold
    }

    /// Notify only once per paused episode, only after the pause has persisted
    /// past `threshold`, and never once the device-local login itself is known
    /// expired. Callers clear `pausedSince` and the already-notified flag the
    /// moment the account reaches any other state, which re-arms the next
    /// episode.
    public func shouldNotify(
        pausedSince: Date?,
        fixedLoginExpiresAt: Date? = nil,
        storedCredentials: StoredCredentialAvailability = .available,
        now: Date,
        alreadyNotified: Bool
    ) -> Bool {
        let trustedFixedExpiry: Date?
        if case .available = storedCredentials {
            trustedFixedExpiry = fixedLoginExpiresAt
        } else {
            // A cached date cannot diagnose expiry while its credential owner
            // is locked, unreadable, or absent. Keep the stuck-usage reminder
            // live so authorization—not a false expiry claim—wins.
            trustedFixedExpiry = nil
        }
        guard let pausedSince,
              !alreadyNotified,
              trustedFixedExpiry.map({ now >= $0 }) != true else {
            return false
        }
        return now.timeIntervalSince(pausedSince) >= threshold
    }
}
