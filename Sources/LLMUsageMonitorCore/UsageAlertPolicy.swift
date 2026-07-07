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

/// A "this account is running hot" moment worth telling the user about — a
/// window crossing into warning or depleted territory. Scoped to a single
/// window: the weekly window running low is announced independently of the
/// session one.
public struct ThresholdAlert: Equatable, Sendable {
    public var profileID: UUID
    public var windowID: String
    public var windowLabel: String
    public var riskLevel: RiskLevel
    public var usedPercent: Double
    public var resetDescription: String?

    public init(
        profileID: UUID,
        windowID: String,
        windowLabel: String,
        riskLevel: RiskLevel,
        usedPercent: Double,
        resetDescription: String? = nil
    ) {
        self.profileID = profileID
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.riskLevel = riskLevel
        self.usedPercent = usedPercent
        self.resetDescription = resetDescription
    }
}

/// Decides which of a snapshot's windows deserve a running-low notification.
/// Pure logic: persistence of what was already notified and the actual
/// posting live in the app layer.
///
/// Dedupe contract: `lastNotified` holds the risk level most recently
/// announced per window. A window fires when it reads `.warning` or
/// `.depleted` and is strictly more severe than the stored level, so a
/// warning → depleted escalation re-fires while a depleted → warning
/// de-escalation stays quiet. The caller is responsible for clearing keys
/// whose window returned to healthy, so the next climb back into warning is
/// announced again.
public struct ThresholdAlertPlanner: Sendable {
    /// Session windows (~5h) churn too fast to be worth interrupting most
    /// users; off by default so only the longer windows notify.
    public var includeSessionWindows: Bool

    public init(includeSessionWindows: Bool = false) {
        self.includeSessionWindows = includeSessionWindows
    }

    public func alerts(
        snapshot: UsageSnapshot,
        profile: AccountProfile,
        lastNotified: [AlertWindowKey: RiskLevel]
    ) -> [ThresholdAlert] {
        var result: [ThresholdAlert] = []
        for window in windows(for: snapshot) {
            guard window.riskLevel == .warning || window.riskLevel == .depleted else {
                continue
            }
            let key = AlertWindowKey(profileID: profile.id, windowID: window.id)
            // RiskLevel's Comparable puts the most severe level first
            // (depleted < warning), so `>=` reads "not more severe than what
            // was already announced".
            if let notified = lastNotified[key], window.riskLevel >= notified {
                continue
            }
            result.append(
                ThresholdAlert(
                    profileID: profile.id,
                    windowID: window.id,
                    windowLabel: window.label,
                    riskLevel: window.riskLevel,
                    usedPercent: window.usedPercent,
                    resetDescription: window.resetDescription
                )
            )
        }
        return result
    }

    /// Legacy and web-dashboard snapshots have no `windows`; fall back to a
    /// single synthetic evaluation of the scalar fields (carrying the
    /// snapshot's risk level so a depleted reading still alerts even when the
    /// used fraction could not be parsed) so they keep alerting exactly as
    /// before per-window tracking existed.
    private func windows(for snapshot: UsageSnapshot) -> [UsageWindow] {
        if !snapshot.windows.isEmpty {
            return snapshot.windows.filter { includeSessionWindows || $0.kind != .session }
        }
        return [
            UsageWindow(
                id: "quota",
                kind: .other,
                label: "Quota",
                usedPercent: (snapshot.usedFraction ?? 0) * 100,
                resetDescription: snapshot.resetDescription,
                riskLevel: snapshot.riskLevel
            )
        ]
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
