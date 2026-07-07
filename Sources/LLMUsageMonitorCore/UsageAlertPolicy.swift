import Foundation

/// A "this account likely has its full quota back" moment worth telling the
/// user about — the reason to switch the CLI before paying overage elsewhere.
public struct ResetAlert: Equatable, Sendable {
    public var profileID: UUID
    public var profileLabel: String
    public var provider: Provider
    public var resetDate: Date

    public init(profileID: UUID, profileLabel: String, provider: Provider, resetDate: Date) {
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.provider = provider
        self.resetDate = resetDate
    }
}

/// Decides which accounts deserve a quota-restored notification. Pure logic:
/// persistence of what was already notified and the actual posting live in
/// the app layer.
public struct ResetAlertPlanner: Sendable {
    public var thresholds: UsageThresholds

    public init(thresholds: UsageThresholds = .standard) {
        self.thresholds = thresholds
    }

    /// Alerts fire for inactive accounts whose last reading was constrained
    /// (warning/depleted or past the warning threshold) and whose limit
    /// window has since rolled over. Each reset date is notified once.
    public func alerts(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        alreadyNotified: [UUID: Date],
        now: Date = Date()
    ) -> [ResetAlert] {
        profiles.compactMap { profile in
            guard !profile.isActiveCLI,
                  let snapshot = snapshots[profile.id],
                  let resetDate = snapshot.resetDate,
                  snapshot.resetHasElapsed(asOf: now),
                  wasConstrained(snapshot),
                  alreadyNotified[profile.id] != resetDate else {
                return nil
            }
            return ResetAlert(
                profileID: profile.id,
                profileLabel: profile.label,
                provider: profile.provider,
                resetDate: resetDate
            )
        }
    }

    private func wasConstrained(_ snapshot: UsageSnapshot) -> Bool {
        if snapshot.riskLevel == .warning || snapshot.riskLevel == .depleted {
            return true
        }
        if let used = snapshot.usedFraction, used >= thresholds.warningUsedFraction {
            return true
        }
        return false
    }
}
