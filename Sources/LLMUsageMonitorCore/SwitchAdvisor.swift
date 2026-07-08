import Foundation

/// One Claude account considered as a switch target: the profile's stable id
/// and label, whether the CLI is currently logged into it, whether a stored
/// credential snapshot exists to switch to, and its latest usage reading.
public struct SwitchCandidate: Equatable, Sendable {
    public var profileID: UUID
    public var label: String
    public var isActiveCLI: Bool
    public var hasStoredCredentials: Bool
    public var snapshot: UsageSnapshot?

    public init(
        profileID: UUID,
        label: String,
        isActiveCLI: Bool,
        hasStoredCredentials: Bool,
        snapshot: UsageSnapshot?
    ) {
        self.profileID = profileID
        self.label = label
        self.isActiveCLI = isActiveCLI
        self.hasStoredCredentials = hasStoredCredentials
        self.snapshot = snapshot
    }
}

/// What the advisor concluded: the best account to switch to (set whenever at
/// least one eligible target exists, for passive UI hinting) and whether an
/// automatic switch is justified right now.
public struct SwitchAdvice: Equatable, Sendable {
    public var bestCandidateID: UUID?
    public var bestCandidateLabel: String?
    public var shouldAutoSwitch: Bool
    /// Short human sentence for status/notification, nil when no advice.
    public var reason: String?

    public init(
        bestCandidateID: UUID? = nil,
        bestCandidateLabel: String? = nil,
        shouldAutoSwitch: Bool = false,
        reason: String? = nil
    ) {
        self.bestCandidateID = bestCandidateID
        self.bestCandidateLabel = bestCandidateLabel
        self.shouldAutoSwitch = shouldAutoSwitch
        self.reason = reason
    }
}

/// Ranks Claude accounts as switch targets and decides when an automatic
/// switch is justified. Pure logic: reading credentials, polling usage and
/// performing the actual switch live in the app layer.
///
/// Eligible switch targets are inactive accounts with stored credentials
/// whose limit window has rolled over since the last reading (full quota
/// regardless of staleness) or whose reading is fresh and not depleted.
/// An automatic switch additionally requires the active account to be
/// depleted and the best target to clear both headroom bars.
public struct SwitchAdvisor: Sendable {
    public struct Configuration: Sendable {
        /// Candidate readings older than this only count via `resetHasElapsed`.
        public var staleAfter: TimeInterval
        /// Candidate must have at least this much headroom to auto-switch.
        public var minimumHeadroomPercent: Double
        /// And beat the active account's headroom by at least this much.
        public var minimumImprovementPercent: Double

        public static let standard = Configuration()

        public init(
            staleAfter: TimeInterval = 3 * 3600,
            minimumHeadroomPercent: Double = 30,
            minimumImprovementPercent: Double = 20
        ) {
            self.staleAfter = staleAfter
            self.minimumHeadroomPercent = minimumHeadroomPercent
            self.minimumImprovementPercent = minimumImprovementPercent
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public func advise(candidates: [SwitchCandidate], now: Date = Date()) -> SwitchAdvice {
        let targets = candidates
            .filter { !$0.isActiveCLI && $0.hasStoredCredentials }
            .compactMap { scoredTarget(for: $0, now: now) }
            .sorted { left, right in
                if left.score != right.score {
                    return left.score > right.score
                }
                return left.candidate.label < right.candidate.label
            }

        guard let best = targets.first else {
            return SwitchAdvice()
        }

        return SwitchAdvice(
            bestCandidateID: best.candidate.profileID,
            bestCandidateLabel: best.candidate.label,
            shouldAutoSwitch: shouldAutoSwitch(to: best, candidates: candidates, now: now),
            reason: reason(for: best)
        )
    }

    /// An eligible target with its headroom score. All eligible targets
    /// already satisfy the auto-switch freshness bar by construction: they
    /// are either fresh or their reset has elapsed.
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

        // A rolled-over limit window means the full quota is likely back, no
        // matter how old the reading is.
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

        // `orderedDisplayWindows` already synthesizes a window from the
        // scalar usedFraction for legacy snapshots; when even that is missing
        // there is no usage data to score, so the candidate ranks last and
        // never auto-switches.
        guard let limiting = limitingWindow(of: snapshot) else {
            return ScoredTarget(
                candidate: candidate,
                score: 0,
                resetElapsed: false,
                limitingWindow: nil,
                canAutoSwitch: false
            )
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
              best.score >= configuration.minimumHeadroomPercent,
              let active = candidates.first(where: { $0.isActiveCLI }),
              let activeSnapshot = active.snapshot,
              effectiveRiskLevel(of: activeSnapshot) == .depleted else {
            return false
        }
        return best.score - headroomScore(of: activeSnapshot, now: now) >= configuration.minimumImprovementPercent
    }

    /// The percentage of quota left on the tightest window, 100 when the
    /// limit window has rolled over since the reading.
    private func headroomScore(of snapshot: UsageSnapshot, now: Date) -> Double {
        if snapshot.resetHasElapsed(asOf: now) {
            return 100
        }
        return limitingWindow(of: snapshot)?.remainingPercent ?? 0
    }

    private func limitingWindow(of snapshot: UsageSnapshot) -> UsageWindow? {
        snapshot.orderedDisplayWindows.min { $0.remainingPercent < $1.remainingPercent }
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
