import Foundation

/// The active account will run a window dry well before the window resets,
/// with agent sessions still running against it.
public struct QuotaShortfall: Equatable, Sendable {
    public enum Stage: Int, Comparable, Sendable {
        /// Runs dry before the reset, with time to act.
        case headsUp
        /// Runs dry within minutes.
        case warning

        public static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Which sessions to park so the rest last until the reset.
    public struct ParkSuggestion: Equatable, Sendable {
        /// Least recently active first.
        public var pids: [Int32]
        /// The share of sessions the pace says should pause, rounded up.
        public var neededCount: Int
        /// False when parking every unstarred session still falls short: the
        /// starred sessions alone burn faster than the quota allows.
        public var isEnough: Bool

        public init(pids: [Int32], neededCount: Int, isEnough: Bool) {
            self.pids = pids
            self.neededCount = neededCount
            self.isEnough = isEnough
        }
    }

    public var provider: Provider
    public var profileID: UUID
    public var windowID: String
    public var windowLabel: String
    public var stage: Stage
    public var emptyAt: Date
    public var resetAt: Date
    /// Sessions working right now against this provider.
    public var activeSessionCount: Int
    /// Sessions already parked for this provider.
    public var parkedCount: Int
    /// Nil when nothing can be parked, or a park is still taking effect.
    public var suggestion: ParkSuggestion?

    public var dryFor: TimeInterval {
        resetAt.timeIntervalSince(emptyAt)
    }

    public init(
        provider: Provider,
        profileID: UUID,
        windowID: String,
        windowLabel: String,
        stage: Stage,
        emptyAt: Date,
        resetAt: Date,
        activeSessionCount: Int,
        parkedCount: Int,
        suggestion: ParkSuggestion?
    ) {
        self.provider = provider
        self.profileID = profileID
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.stage = stage
        self.emptyAt = emptyAt
        self.resetAt = resetAt
        self.activeSessionCount = activeSessionCount
        self.parkedCount = parkedCount
        self.suggestion = suggestion
    }
}

/// Decides when a projected depletion deserves a heads-up, and which sessions
/// to park so the most important work still finishes before the reset. Pure:
/// the windows, estimates, sessions and clock are all passed in.
public struct QuotaShortfallPolicy: Sendable {
    public struct Session: Equatable, Sendable {
        public var pid: Int32
        public var provider: Provider
        /// Last transcript write; nil when unknown (Codex).
        public var lastActivityAt: Date?
        public var isStarred: Bool
        public var isParked: Bool
        /// Only Claude Code sessions run the park hook.
        public var isParkable: Bool

        public init(
            pid: Int32,
            provider: Provider,
            lastActivityAt: Date?,
            isStarred: Bool = false,
            isParked: Bool = false,
            isParkable: Bool
        ) {
            self.pid = pid
            self.provider = provider
            self.lastActivityAt = lastActivityAt
            self.isStarred = isStarred
            self.isParked = isParked
            self.isParkable = isParkable
        }
    }

    /// A projection only counts when the window would sit empty this long.
    public var minimumDryTime: TimeInterval
    /// Further out than this, the pace is too likely to change to act on.
    public var headsUpHorizon: TimeInterval
    public var warningHorizon: TimeInterval
    /// A session counts as working when its transcript moved this recently.
    public var activeWithin: TimeInterval
    /// The burn estimate looks back over the last 90 minutes, so a fresh park
    /// takes a while to show in the pace; suggesting more meanwhile would
    /// park everything.
    public var settleTime: TimeInterval

    public init(
        minimumDryTime: TimeInterval = 15 * 60,
        headsUpHorizon: TimeInterval = 2 * 3600,
        warningHorizon: TimeInterval = 30 * 60,
        activeWithin: TimeInterval = 5 * 60,
        settleTime: TimeInterval = 30 * 60
    ) {
        self.minimumDryTime = minimumDryTime
        self.headsUpHorizon = headsUpHorizon
        self.warningHorizon = warningHorizon
        self.activeWithin = activeWithin
        self.settleTime = settleTime
    }

    /// The most urgent shortfall on this account, or nil.
    public func shortfall(
        profile: AccountProfile,
        windows: [UsageWindow],
        estimates: [String: BurnRateEstimate],
        sessions: [Session],
        lastParkedAt: Date?,
        now: Date
    ) -> QuotaShortfall? {
        let mine = sessions.filter { $0.provider == profile.provider }
        let active = mine.filter { !$0.isParked && isActive($0, now: now) }
        // Nothing running means nothing to pace or park; the existing pace
        // alert covers an idle account.
        guard !active.isEmpty else {
            return nil
        }

        var best: (window: UsageWindow, emptyAt: Date, resetAt: Date)?
        for window in windows {
            guard case .depletesAt(let emptyAt)? = estimates[window.id],
                  let resetAt = window.resetDate,
                  emptyAt > now,
                  resetAt.timeIntervalSince(emptyAt) >= minimumDryTime,
                  emptyAt.timeIntervalSince(now) <= headsUpHorizon else {
                continue
            }
            if best == nil || emptyAt < best!.emptyAt {
                best = (window, emptyAt, resetAt)
            }
        }
        guard let best else {
            return nil
        }

        let timeToEmpty = best.emptyAt.timeIntervalSince(now)
        let stage: QuotaShortfall.Stage = timeToEmpty <= warningHorizon ? .warning : .headsUp
        let settling = lastParkedAt.map { now.timeIntervalSince($0) < settleTime } ?? false

        return QuotaShortfall(
            provider: profile.provider,
            profileID: profile.id,
            windowID: best.window.id,
            windowLabel: best.window.label,
            stage: stage,
            emptyAt: best.emptyAt,
            resetAt: best.resetAt,
            activeSessionCount: active.count,
            parkedCount: mine.filter(\.isParked).count,
            suggestion: settling ? nil : suggestion(
                active: active,
                timeToEmpty: timeToEmpty,
                timeToReset: best.resetAt.timeIntervalSince(now)
            )
        )
    }

    /// To last until the reset, the burn rate must fall to
    /// timeToEmpty / timeToReset of today's. Burn is split evenly across the
    /// working sessions — crude, but the only attribution there is — so that
    /// fraction of them keeps going and the rest pause.
    func suggestion(
        active: [Session],
        timeToEmpty: TimeInterval,
        timeToReset: TimeInterval
    ) -> QuotaShortfall.ParkSuggestion? {
        guard timeToReset > 0 else {
            return nil
        }
        let share = max(0, min(1, 1 - timeToEmpty / timeToReset))
        let needed = Int((Double(active.count) * share).rounded(.up))
        let candidates = active
            .filter { $0.isParkable && !$0.isStarred }
            .sorted { ($0.lastActivityAt ?? .distantPast, $0.pid) < ($1.lastActivityAt ?? .distantPast, $1.pid) }
        guard needed > 0, !candidates.isEmpty else {
            return nil
        }
        let chosen = candidates.prefix(needed).map(\.pid)
        return .init(pids: Array(chosen), neededCount: needed, isEnough: chosen.count >= needed)
    }

    private func isActive(_ session: Session, now: Date) -> Bool {
        // Without a transcript to read (Codex), a running process is the best
        // available sign of work.
        guard let last = session.lastActivityAt else {
            return true
        }
        return now.timeIntervalSince(last) < activeWithin
    }
}

public enum QuotaShortfallText {
    /// "Session runs dry in 20m, 1h 40m before it resets."
    public static func headline(_ shortfall: QuotaShortfall, now: Date) -> String {
        let empty = DurationPhrase.precise(max(60, shortfall.emptyAt.timeIntervalSince(now)))
        let dry = DurationPhrase.precise(shortfall.dryFor)
        return "\(shortfall.windowLabel) runs dry in \(empty), \(dry) before it resets."
    }

    public static func detail(_ shortfall: QuotaShortfall) -> String {
        let sessions = shortfall.activeSessionCount == 1
            ? "1 session is working"
            : "\(shortfall.activeSessionCount) sessions are working"
        guard shortfall.parkedCount == 0 else {
            return "\(sessions), \(shortfall.parkedCount) parked. Parked sessions resume when the limit resets."
        }
        guard let suggestion = shortfall.suggestion else {
            return "\(sessions)."
        }
        if suggestion.isEnough {
            return "\(sessions). Parking about \(suggestion.pids.count) would make the rest last until the reset."
        }
        return "\(sessions). Even with every unstarred session parked, the starred ones alone run out before the reset."
    }

    public static func parkButtonTitle(_ suggestion: QuotaShortfall.ParkSuggestion) -> String {
        suggestion.pids.count == 1 ? "Park 1 session" : "Park \(suggestion.pids.count) sessions"
    }
}
