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
/// Weekly-shaped windows (`.weekly`, `.weeklyScoped`) are always considered.
/// Session windows are opt-in, mirroring `ThresholdAlertPlanner`'s session
/// flag — a ~5h window churns too fast to be worth an interruption for most
/// users.
///
/// Dedupe contract: one alert per window per reset period. The caller persists
/// `alreadyNotified` keyed by the alerted window's `resetDate` (or `now` when
/// the window has no reset date). A window stays quiet while the stored date
/// matches its current `resetDate` within the kind's reset tolerance, and
/// re-arms when the reset rolls over to a new period. Windows without a reset
/// date fall back to a time throttle: any stored entry newer than
/// `now - 7 days` suppresses them, so a nil-reset weekly window cannot re-fire
/// more than weekly.
public struct PaceAlertPlanner: Sendable {
    /// Whether ~5h session windows may pace-alert at all.
    public var includeSessionWindows: Bool
    /// Stored-vs-current reset dates within this interval count as the same
    /// reset period. The active account's snapshots alternate between the
    /// usage API's exact `resets_at` and the TUI text parse's minutes-coarse
    /// (or missing) value, so the same weekly reset can be reported minutes
    /// apart; a day of tolerance absorbs that while staying far inside the
    /// 7-day period, so a genuine roll-over still re-arms.
    public var resetMatchTolerance: TimeInterval
    /// The session-window counterpart. A ~5h period sits far inside the
    /// weekly tolerance — with 24h every subsequent session reset would read
    /// as "the same reset" and a session alert could never re-arm — so
    /// sessions use a much smaller value that still absorbs the minutes-scale
    /// TUI reset-date jitter.
    public var sessionResetMatchTolerance: TimeInterval

    public init(
        includeSessionWindows: Bool = false,
        resetMatchTolerance: TimeInterval = 24 * 3600,
        sessionResetMatchTolerance: TimeInterval = 30 * 60
    ) {
        self.includeSessionWindows = includeSessionWindows
        self.resetMatchTolerance = resetMatchTolerance
        self.sessionResetMatchTolerance = sessionResetMatchTolerance
    }

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
        for window in snapshot.orderedDisplayWindows where isAlertable(window.kind) {
            guard case .depletesAt(let projectedDepletion)? = estimates[window.id] else {
                continue
            }
            let key = AlertWindowKey(profileID: profile.id, windowID: window.id)
            if isSuppressed(notified: alreadyNotified[key], resetDate: window.resetDate, kind: window.kind, now: now) {
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

    private func isAlertable(_ kind: UsageWindowKind) -> Bool {
        kind == .weekly || kind == .weeklyScoped || (includeSessionWindows && kind == .session)
    }

    private func isSuppressed(notified: Date?, resetDate: Date?, kind: UsageWindowKind, now: Date) -> Bool {
        guard let notified else {
            return false
        }
        guard let resetDate else {
            // No reset date to key the period on; suppress on recency instead
            // so the window re-fires at most weekly.
            return notified > now.addingTimeInterval(-7 * 24 * 3600)
        }
        return isSameReset(notified, resetDate, kind: kind)
    }

    /// Reported dates for the same reset rarely agree exactly: snapshot dates
    /// lose sub-second precision on their .iso8601 disk round-trip, and a
    /// source flip between the usage API and the TUI text parse shifts the
    /// reset by minutes. Dates within the kind's tolerance count as the same
    /// reset.
    private func isSameReset(_ lhs: Date, _ rhs: Date, kind: UsageWindowKind) -> Bool {
        let tolerance = kind == .session ? sessionResetMatchTolerance : resetMatchTolerance
        return abs(lhs.timeIntervalSince(rhs)) < tolerance
    }
}
