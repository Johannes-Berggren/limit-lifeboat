import Foundation

/// One Claude account considered as a switch target: the profile's stable id
/// and label, whether the CLI is currently logged into it, whether a stored
/// switch eligibility for manual and automatic sources, and its latest usage
/// reading. Automatic eligibility is deliberately stricter because automatic
/// switching must never rotate credentials.
public struct SwitchCandidate: Equatable, Sendable {
    public var profileID: UUID
    public var label: String
    public var isActiveCLI: Bool
    public var manualSwitchEligibility: AccountSwitchEligibility
    public var automaticSwitchEligibility: AccountSwitchEligibility
    public var snapshot: UsageSnapshot?
    /// Position in the user's per-provider priority order; 0 is switched to
    /// first, the highest rank last.
    public var priorityRank: Int

    public init(
        profileID: UUID,
        label: String,
        isActiveCLI: Bool,
        manualSwitchEligibility: AccountSwitchEligibility,
        automaticSwitchEligibility: AccountSwitchEligibility,
        snapshot: UsageSnapshot?,
        priorityRank: Int = 0
    ) {
        self.profileID = profileID
        self.label = label
        self.isActiveCLI = isActiveCLI
        self.manualSwitchEligibility = manualSwitchEligibility
        self.automaticSwitchEligibility = automaticSwitchEligibility
        self.snapshot = snapshot
        self.priorityRank = priorityRank
    }
}

/// What the advisor concluded: the best account to switch to (set whenever at
/// least one eligible target exists, for passive UI hinting) and whether an
/// automatic switch is justified right now.
public struct SwitchAdvice: Equatable, Sendable {
    public var bestCandidateID: UUID?
    public var bestCandidateLabel: String?
    public var shouldAutoSwitch: Bool
    /// True when the switch returns to a recovered higher-priority account
    /// rather than fleeing a depleted one. Rebalances defer to manual parking
    /// in the app layer.
    public var isRebalance: Bool
    /// Short human sentence for status/notification, nil when no advice.
    public var reason: String?

    public init(
        bestCandidateID: UUID? = nil,
        bestCandidateLabel: String? = nil,
        shouldAutoSwitch: Bool = false,
        isRebalance: Bool = false,
        reason: String? = nil
    ) {
        self.bestCandidateID = bestCandidateID
        self.bestCandidateLabel = bestCandidateLabel
        self.shouldAutoSwitch = shouldAutoSwitch
        self.isRebalance = isRebalance
        self.reason = reason
    }
}

/// Ranks Claude accounts as switch targets and decides when an automatic
/// switch is justified. Pure logic: reading credentials, polling usage and
/// performing the actual switch live in the app layer.
///
/// Eligible switch targets are inactive accounts with stored credentials
/// whose every limit window has rolled over since the last reading (full
/// quota regardless of staleness) or whose reading is fresh and whose
/// tightest window is not depleted. Targets rank in the user's priority
/// order (repository order per provider), not by headroom. An automatic
/// switch requires either a depleted active account and a target clearing
/// both headroom bars, or a recovered higher-priority account clearing the
/// rebalance bar.
public struct SwitchAdvisor: Sendable {
    public struct Configuration: Sendable {
        /// Candidate readings older than this only count once every
        /// window's reset has elapsed.
        public var staleAfter: TimeInterval
        /// Candidate must have at least this much headroom to auto-switch.
        public var minimumHeadroomPercent: Double
        /// And beat the active account's headroom by at least this much.
        public var minimumImprovementPercent: Double
        /// A recovered higher-priority account needs this much headroom (or a
        /// full window reset) before the advisor suggests returning to it —
        /// deliberately higher than the escape bar so rebalances don't
        /// ping-pong onto accounts that are about to deplete again.
        public var rebalanceMinimumHeadroomPercent: Double

        public static let standard = Configuration()

        public init(
            staleAfter: TimeInterval = 3 * 3600,
            minimumHeadroomPercent: Double = 30,
            minimumImprovementPercent: Double = 20,
            rebalanceMinimumHeadroomPercent: Double = 50
        ) {
            self.staleAfter = staleAfter
            self.minimumHeadroomPercent = minimumHeadroomPercent
            self.minimumImprovementPercent = minimumImprovementPercent
            self.rebalanceMinimumHeadroomPercent = rebalanceMinimumHeadroomPercent
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public func advise(candidates: [SwitchCandidate], now: Date = Date()) -> SwitchAdvice {
        // User priority is the ranking; headroom only gates eligibility and
        // feeds the reason string. The label tie-break is defensive — ranks
        // are array indices and should never collide.
        let targets = candidates
            .filter { !$0.isActiveCLI && $0.manualSwitchEligibility.isEligible }
            .compactMap { scoredTarget(for: $0, now: now) }
            .sorted { left, right in
                if left.candidate.priorityRank != right.candidate.priorityRank {
                    return left.candidate.priorityRank < right.candidate.priorityRank
                }
                return left.candidate.label < right.candidate.label
            }

        guard let manualBest = targets.first else {
            return SwitchAdvice()
        }

        // If the active account is depleted, walk the priority order and pick
        // the first read-only target that actually clears the auto-switch
        // bars — a preferred account below the bars must not block a healthy
        // one further down. Otherwise preserve the highest-priority manually
        // switchable account as the passive UI hint.
        if let automaticBest = targets.first(where: {
            $0.candidate.automaticSwitchEligibility.isEligible
                && shouldAutoSwitch(to: $0, candidates: candidates, now: now)
        }) {
            return SwitchAdvice(
                bestCandidateID: automaticBest.candidate.profileID,
                bestCandidateLabel: automaticBest.candidate.label,
                shouldAutoSwitch: true,
                reason: reason(for: automaticBest)
            )
        }

        // The active account still has quota, but a higher-priority account
        // may have recovered. Suggest returning to it once it clears the
        // stricter rebalance bar; the app layer defers this to manual parking
        // and its own backoffs.
        if let activeRank = candidates.first(where: { $0.isActiveCLI })?.priorityRank,
           let rebalanceTarget = targets.first(where: {
               $0.candidate.priorityRank < activeRank
                   && $0.canAutoSwitch
                   && $0.candidate.automaticSwitchEligibility.isEligible
                   && ($0.resetElapsed || $0.score >= configuration.rebalanceMinimumHeadroomPercent)
           }) {
            return SwitchAdvice(
                bestCandidateID: rebalanceTarget.candidate.profileID,
                bestCandidateLabel: rebalanceTarget.candidate.label,
                shouldAutoSwitch: true,
                isRebalance: true,
                reason: "\(rebalanceTarget.candidate.label) is higher priority and \(recoveryPhrase(for: rebalanceTarget))"
            )
        }

        return SwitchAdvice(
            bestCandidateID: manualBest.candidate.profileID,
            bestCandidateLabel: manualBest.candidate.label,
            shouldAutoSwitch: false,
            reason: reason(for: manualBest)
        )
    }

    /// An eligible target with its headroom score. All eligible targets
    /// already satisfy the auto-switch freshness bar by construction: they
    /// are either fresh or every window's reset has elapsed.
    private struct ScoredTarget {
        var candidate: SwitchCandidate
        var score: Double
        var resetElapsed: Bool
        /// The window with the least headroom — the one the score reflects.
        var limitingWindow: UsageWindow?
        /// False for snapshots with no usage data at all: rankable last as a
        /// hint, never an auto-switch target.
        var canAutoSwitch: Bool
    }

    private func scoredTarget(for candidate: SwitchCandidate, now: Date) -> ScoredTarget? {
        guard let snapshot = candidate.snapshot else {
            return nil
        }

        // `orderedDisplayWindows` already synthesizes a window from the
        // scalar usedFraction for legacy snapshots; when even that is missing
        // the snapshot-level reset date is the only signal left, so keep the
        // whole-snapshot roll-over rule for those.
        let windows = snapshot.orderedDisplayWindows
        guard !windows.isEmpty else {
            if snapshot.resetHasElapsed(asOf: now) {
                return ScoredTarget(
                    candidate: candidate,
                    score: 100,
                    resetElapsed: true,
                    limitingWindow: nil,
                    canAutoSwitch: true
                )
            }
            guard !snapshot.isStale(asOf: now, maxAge: configuration.staleAfter),
                  effectiveRiskLevel(of: snapshot) != .depleted else {
                return nil
            }
            // No usage data to score, so the candidate ranks last and never
            // auto-switches.
            return ScoredTarget(
                candidate: candidate,
                score: 0,
                resetElapsed: false,
                limitingWindow: nil,
                canAutoSwitch: false
            )
        }

        // Resets roll over per window: an elapsed session reset restores the
        // session quota but says nothing about the weekly window. Only when
        // every window has rolled over is the full quota likely back, no
        // matter how old the reading is.
        if snapshot.allWindowsResetElapsed(asOf: now) {
            return ScoredTarget(
                candidate: candidate,
                score: 100,
                resetElapsed: true,
                limitingWindow: nil,
                canAutoSwitch: true
            )
        }

        // A stale reading with any window still inside its period cannot be
        // trusted — and its elapsed session must not mask a nearly-depleted
        // weekly.
        guard !snapshot.isStale(asOf: now, maxAge: configuration.staleAfter) else {
            return nil
        }

        // Windows whose reset has elapsed count as full headroom, so the
        // tightest window is always one still inside its period — and its
        // reading is fresh, so a depleted one keeps the candidate ineligible.
        let limiting = windows
            .filter { !$0.resetHasElapsed(asOf: now) }
            .min { $0.remainingPercent < $1.remainingPercent }
        guard let limiting, limiting.riskLevel != .depleted else {
            return nil
        }

        return ScoredTarget(
            candidate: candidate,
            score: limiting.remainingPercent,
            resetElapsed: false,
            limitingWindow: limiting,
            canAutoSwitch: true
        )
    }

    private func shouldAutoSwitch(to best: ScoredTarget, candidates: [SwitchCandidate], now: Date) -> Bool {
        guard best.canAutoSwitch,
              best.candidate.automaticSwitchEligibility.isEligible,
              best.score >= configuration.minimumHeadroomPercent,
              let active = candidates.first(where: { $0.isActiveCLI }),
              let activeSnapshot = active.snapshot,
              effectiveRiskLevel(of: activeSnapshot) == .depleted else {
            return false
        }
        return best.score - headroomScore(of: activeSnapshot, now: now) >= configuration.minimumImprovementPercent
    }

    /// The percentage of quota left on the tightest window as of `now`;
    /// windows whose reset has rolled over since the reading count as full.
    private func headroomScore(of snapshot: UsageSnapshot, now: Date) -> Double {
        let windows = snapshot.orderedDisplayWindows
        guard !windows.isEmpty else {
            return snapshot.resetHasElapsed(asOf: now) ? 100 : 0
        }
        return windows.map { effectiveHeadroom(of: $0, now: now) }.min() ?? 0
    }

    /// A window's quota left as of `now`: full once its reset has rolled
    /// over since the reading, the recorded remainder otherwise.
    private func effectiveHeadroom(of window: UsageWindow, now: Date) -> Double {
        window.resetHasElapsed(asOf: now) ? 100 : window.remainingPercent
    }

    /// The snapshot's most-constrained window leads; the scalar risk level is
    /// the fallback for snapshots with no windows and no used fraction.
    private func effectiveRiskLevel(of snapshot: UsageSnapshot) -> RiskLevel {
        snapshot.mostConstrainedWindow?.riskLevel ?? snapshot.riskLevel
    }

    private func reason(for target: ScoredTarget) -> String {
        if target.resetElapsed {
            return "\(target.candidate.label)'s limit window has reset"
        }
        let percent = Int(target.score.rounded())
        return "\(target.candidate.label) has ~\(percent)% of its \(phrase(for: target.limitingWindow)) left"
    }

    /// Trailing clause of a rebalance reason ("<label> is higher priority
    /// and …"): why the account counts as recovered.
    private func recoveryPhrase(for target: ScoredTarget) -> String {
        if target.resetElapsed {
            return "its limit window has reset"
        }
        let percent = Int(target.score.rounded())
        return "has ~\(percent)% of its \(phrase(for: target.limitingWindow)) left"
    }

    private func phrase(for window: UsageWindow?) -> String {
        switch window?.kind {
        case .session:
            return "session window"
        case .weekly, .weeklyScoped:
            return "weekly window"
        case .other, nil:
            return "quota"
        }
    }
}
