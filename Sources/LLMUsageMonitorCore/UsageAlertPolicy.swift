import Foundation

/// A "this account likely has its full quota back" moment worth telling the
/// user about — the reason to switch the CLI before paying overage elsewhere.
/// Scoped to a single window: a weekly window rolling back can be announced
/// independently of the session window.
public struct ResetAlert: Equatable, Sendable {
    public var profileID: UUID
    public var profileLabel: String
    public var provider: Provider
    public var windowID: String
    public var windowLabel: String
    public var resetDate: Date

    public init(
        profileID: UUID,
        profileLabel: String,
        provider: Provider,
        windowID: String,
        windowLabel: String,
        resetDate: Date
    ) {
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.provider = provider
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.resetDate = resetDate
    }
}

/// Identifies an already-notified reset: one entry per (account, window) so
/// each window is announced once per roll-over.
public struct AlertWindowKey: Hashable, Sendable {
    public var profileID: UUID
    public var windowID: String

    public init(profileID: UUID, windowID: String) {
        self.profileID = profileID
        self.windowID = windowID
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
    /// window has since rolled over. Each window's reset is notified once, so a
    /// weekly window rolling back is announced separately from the session one.
    public func alerts(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        alreadyNotified: [AlertWindowKey: Date],
        now: Date = Date()
    ) -> [ResetAlert] {
        var result: [ResetAlert] = []
        for profile in profiles where !profile.isActiveCLI {
            guard let snapshot = snapshots[profile.id] else {
                continue
            }
            for window in windows(for: snapshot) {
                guard let resetDate = window.resetDate,
                      window.resetHasElapsed(asOf: now),
                      wasConstrained(window) else {
                    continue
                }
                let key = AlertWindowKey(profileID: profile.id, windowID: window.id)
                if let notified = alreadyNotified[key], isSameReset(notified, resetDate) {
                    continue
                }
                result.append(
                    ResetAlert(
                        profileID: profile.id,
                        profileLabel: profile.label,
                        provider: profile.provider,
                        windowID: window.id,
                        windowLabel: window.label,
                        resetDate: resetDate
                    )
                )
            }
        }
        return result
    }

    /// Legacy and web-dashboard snapshots have no `windows`; fall back to a
    /// single synthetic window from the scalar fields (carrying the snapshot's
    /// risk level so a depleted reading still alerts even when the used
    /// fraction could not be parsed) so they still alert.
    private func windows(for snapshot: UsageSnapshot) -> [UsageWindow] {
        if !snapshot.windows.isEmpty {
            return snapshot.windows
        }
        guard let resetDate = snapshot.resetDate else {
            return []
        }
        return [
            UsageWindow(
                id: "primary",
                kind: .other,
                label: "Quota",
                usedPercent: (snapshot.usedFraction ?? 0) * 100,
                resetDate: resetDate,
                resetDescription: snapshot.resetDescription,
                riskLevel: snapshot.riskLevel
            )
        ]
    }

    /// Snapshot dates lose sub-second precision on their .iso8601 disk
    /// round-trip while the notified store keeps the full value, so exact
    /// equality would re-fire after a relaunch. Same second = same reset.
    private func isSameReset(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }

    private func wasConstrained(_ window: UsageWindow) -> Bool {
        if window.riskLevel == .warning || window.riskLevel == .depleted {
            return true
        }
        return window.usedFraction >= thresholds.warningUsedFraction
    }
}
