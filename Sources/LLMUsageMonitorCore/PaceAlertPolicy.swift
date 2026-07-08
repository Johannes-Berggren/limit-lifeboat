import Foundation

/// A "this window runs out before it resets" moment worth telling the user
/// about — the weekly quota is on pace to hit 100% mid-period, so the user can
/// slow down or switch accounts before the hard stop. Scoped to a single
/// window: the all-models weekly running hot is announced independently of a
/// model-scoped one.
public struct PaceAlert: Equatable, Sendable {
    public var profileID: UUID
    public var profileLabel: String
    public var windowID: String
    public var windowLabel: String
    public var projectedDepletion: Date
    public var resetDate: Date?

    public init(
        profileID: UUID,
        profileLabel: String,
        windowID: String,
        windowLabel: String,
        projectedDepletion: Date,
        resetDate: Date? = nil
    ) {
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.projectedDepletion = projectedDepletion
        self.resetDate = resetDate
    }
}

/// Decides which of a snapshot's weekly windows deserve an "at this pace the
/// quota runs out before it resets" notification, based on the burn-rate
/// estimates already computed per window. Pure logic: persistence of what was
/// already notified and the actual posting live in the app layer.
///
/// Only weekly-shaped windows (`.weekly`, `.weeklyScoped`) are considered:
/// session pace is deliberately not alertable, mirroring
/// `ThresholdAlertPlanner`'s session exclusion — a ~5h window churns too fast
/// for a pace projection to be worth an interruption.
///
/// Dedupe contract: one alert per window per reset period. The caller persists
/// `alreadyNotified` keyed by the alerted window's `resetDate` (or `now` when
/// the window has no reset date). A window stays quiet while the stored date
/// matches its current `resetDate` within 1s, and re-arms when the reset rolls
/// over to a new period. Windows without a reset date fall back to a time
/// throttle: any stored entry newer than `now - 7 days` suppresses them, so a
/// nil-reset weekly window cannot re-fire more than weekly.
public struct PaceAlertPlanner: Sendable {
    public init() {}

    public func alerts(
        snapshot: UsageSnapshot,
        profile: AccountProfile,
        estimates: [String: BurnRateEstimate],
        alreadyNotified: [AlertWindowKey: Date],
        now: Date = Date()
    ) -> [PaceAlert] {
        guard snapshot.parseConfidence != .none else {
            return []
        }
        var result: [PaceAlert] = []
        for window in snapshot.orderedDisplayWindows where isWeeklyShaped(window.kind) {
            guard case .depletesAt(let projectedDepletion)? = estimates[window.id] else {
                continue
            }
            let key = AlertWindowKey(profileID: profile.id, windowID: window.id)
            if isSuppressed(notified: alreadyNotified[key], resetDate: window.resetDate, now: now) {
                continue
            }
            result.append(
                PaceAlert(
                    profileID: profile.id,
                    profileLabel: profile.label,
                    windowID: window.id,
                    windowLabel: window.label,
                    projectedDepletion: projectedDepletion,
                    resetDate: window.resetDate
                )
            )
        }
        return result
    }

    private func isWeeklyShaped(_ kind: UsageWindowKind) -> Bool {
        kind == .weekly || kind == .weeklyScoped
    }

    private func isSuppressed(notified: Date?, resetDate: Date?, now: Date) -> Bool {
        guard let notified else {
            return false
        }
        guard let resetDate else {
            // No reset date to key the period on; suppress on recency instead
            // so the window re-fires at most weekly.
            return notified > now.addingTimeInterval(-7 * 24 * 3600)
        }
        return isSameReset(notified, resetDate)
    }

    /// Snapshot dates lose sub-second precision on their .iso8601 disk
    /// round-trip while the notified store keeps the full value, so exact
    /// equality would re-fire after a relaunch. Same second = same reset
    /// (same rule as `ResetAlertPlanner`).
    private func isSameReset(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }
}
