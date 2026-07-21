import Foundation

public enum CodexResetRedemptionState: Equatable, Sendable {
    case idle
    case redeeming
    /// A reset was authoritatively consumed, but no post-redemption quota
    /// snapshot was returned. Further spending stays disabled until refresh.
    case refreshRequired(reason: String)
    case failed(reason: String)

    public var isBusy: Bool {
        self == .redeeming
    }

    public var blocksRedemption: Bool {
        switch self {
        case .redeeming, .refreshRequired:
            return true
        case .idle, .failed:
            return false
        }
    }
}

public enum CodexResetPresentationState: Equatable, Sendable {
    case unsupported
    case zero
    case available(count: Int)
    case stale(count: Int)
    case busy(count: Int)
    case refreshRequired(count: Int, reason: String)
    case failed(count: Int, reason: String)
}

/// A small, deterministic view model for the badge and popover. In
/// particular, nil capability data is different from an authoritative zero,
/// and stale data remains visible without allowing a stale confirmation.
public struct CodexResetPresentation: Equatable, Sendable {
    public var state: CodexResetPresentationState

    public init(
        snapshot: UsageSnapshot?,
        redemptionState: CodexResetRedemptionState = .idle,
        now: Date = Date()
    ) {
        guard let snapshot,
              snapshot.provider == .codex,
              let availability = snapshot.codexRateLimitResetAvailability else {
            self.state = .unsupported
            return
        }
        let count = availability.availableCount
        if redemptionState == .redeeming {
            self.state = .busy(count: count)
        } else if case .refreshRequired(let reason) = redemptionState {
            self.state = .refreshRequired(count: count, reason: reason)
        } else if snapshot.isStale(asOf: now) {
            self.state = .stale(count: count)
        } else if case .failed(let reason) = redemptionState {
            self.state = .failed(count: count, reason: reason)
        } else if count == 0 {
            self.state = .zero
        } else {
            self.state = .available(count: count)
        }
    }

    public var availableCount: Int? {
        switch state {
        case .unsupported:
            return nil
        case .zero:
            return 0
        case .available(let count), .stale(let count), .busy(let count),
             .refreshRequired(let count, _), .failed(let count, _):
            return count
        }
    }

    public var badgeText: String? {
        guard let count = availableCount else { return nil }
        return "\(count) \(count == 1 ? "reset" : "resets")"
    }

    public var canRedeem: Bool {
        switch state {
        case .available(let count), .failed(let count, _):
            return count > 0
        case .unsupported, .zero, .stale, .busy, .refreshRequired:
            return false
        }
    }
}

public enum CodexHardLimitRecoveryStep: Equatable, Sendable {
    case redeemReset
    case evaluateAccountSwitch
}

/// Pure policy for the off-by-default automatic reset behavior.
public struct CodexResetAutomationPolicy: Sendable {
    public var retryBackoff: TimeInterval

    public init(retryBackoff: TimeInterval = 60 * 60) {
        self.retryBackoff = retryBackoff
    }

    public func shouldRedeem(
        profile: AccountProfile,
        snapshot: UsageSnapshot,
        redemptionState: CodexResetRedemptionState = .idle,
        lastAttempt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard profile.provider == .codex,
              profile.isActiveCLI,
              profile.autoUseCodexRateLimitResets,
              snapshot.provider == .codex,
              snapshot.source == "Codex app server",
              !snapshot.isStale(asOf: now),
              snapshot.codexRateLimitReachedType == "rate_limit_reached",
              snapshot.codexRateLimitResetAvailability?.availableCount ?? 0 > 0,
              !redemptionState.blocksRedemption else {
            return false
        }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryBackoff {
            return false
        }
        return true
    }

    /// Account switching is always evaluated after the optional reset step.
    /// A successful post-reset snapshot naturally makes that later policy a
    /// no-op; a failed redemption lets the existing switch behavior proceed.
    public func recoverySteps(
        profile: AccountProfile,
        snapshot: UsageSnapshot,
        redemptionState: CodexResetRedemptionState = .idle,
        lastAttempt: Date?,
        now: Date = Date()
    ) -> [CodexHardLimitRecoveryStep] {
        var steps: [CodexHardLimitRecoveryStep] = []
        if shouldRedeem(
            profile: profile,
            snapshot: snapshot,
            redemptionState: redemptionState,
            lastAttempt: lastAttempt,
            now: now
        ) {
            steps.append(.redeemReset)
        }
        steps.append(.evaluateAccountSwitch)
        return steps
    }
}

/// Persists unresolved idempotency keys so a retry after a crash or relaunch
/// cannot accidentally spend a second earned reset.
public final class CodexResetAttemptStore {
    private let defaults: UserDefaults
    private let defaultsKey: String

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "pendingCodexResetAttempts"
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
    }

    public func idempotencyKey(for profileID: UUID) -> String {
        var pending = storedAttempts()
        if let existing = pending[profileID.uuidString], !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        pending[profileID.uuidString] = created
        defaults.set(pending, forKey: defaultsKey)
        return created
    }

    public func completeAttempt(for profileID: UUID) {
        var pending = storedAttempts()
        guard pending.removeValue(forKey: profileID.uuidString) != nil else { return }
        defaults.set(pending, forKey: defaultsKey)
    }

    public func removeAccount(_ profileID: UUID) {
        completeAttempt(for: profileID)
    }

    public func pendingKey(for profileID: UUID) -> String? {
        storedAttempts()[profileID.uuidString]
    }

    private func storedAttempts() -> [String: String] {
        defaults.dictionary(forKey: defaultsKey)?.compactMapValues { $0 as? String } ?? [:]
    }
}
