import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    public var commandName: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        }
    }

    public var dashboardURL: URL {
        dashboardURLs[0]
    }

    public var dashboardURLs: [URL] {
        switch self {
        case .claude:
            return [
                URL(string: "https://claude.ai/settings/usage")!
            ]
        case .codex:
            return [
                URL(string: "https://chatgpt.com/codex/settings/usage")!,
                URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
            ]
        }
    }

    public var loginCommand: String {
        switch self {
        case .claude:
            return "claude auth login"
        case .codex:
            return "\(commandName) login"
        }
    }

    /// The command to run in the terminal to start a fresh CLI login.
    /// Codex multiplexes a single `~/.codex/auth.json`, so when a session
    /// already exists it must be logged out first or `codex login` runs
    /// against the existing session instead of starting a new one.
    ///
    /// The two commands are joined with `;`, not `&&`: `codex logout` can
    /// exit non-zero (e.g. no session it recognizes, or a changed CLI exit
    /// code), and with `&&` that would short-circuit and never run
    /// `codex login` — leaving the terminal looking like it did nothing.
    public func terminalLoginCommand(
        hasExistingSession: Bool,
        exitWhenDone: Bool = false
    ) -> String {
        let command: String
        switch self {
        case .claude:
            command = loginCommand
        case .codex:
            command = hasExistingSession ? "\(commandName) logout; \(commandName) login" : loginCommand
        }
        return exitWhenDone ? "\(command); exit" : command
    }
}

public enum RiskLevel: String, Codable, Comparable, Sendable {
    case depleted
    case warning
    case healthy
    case stale
    case unknown

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: RiskLevel) -> Int {
        switch level {
        case .depleted:
            return 0
        case .warning:
            return 1
        case .healthy:
            return 2
        case .stale:
            return 3
        case .unknown:
            return 4
        }
    }
}

public enum ParseConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case none
}

/// The single home for the "how close to the limit is worrying" and "how old
/// is too old" numbers, so every reader and view agrees.
public struct UsageThresholds: Equatable, Sendable {
    public var warningUsedFraction: Double
    public var staleAfter: TimeInterval

    public static let standard = UsageThresholds()

    public init(warningUsedFraction: Double = 0.8, staleAfter: TimeInterval = 30 * 60) {
        self.warningUsedFraction = warningUsedFraction
        self.staleAfter = staleAfter
    }

    public func riskLevel(usedFraction: Double) -> RiskLevel {
        if usedFraction >= 1 {
            return .depleted
        }
        if usedFraction >= warningUsedFraction {
            return .warning
        }
        return .healthy
    }

    public func riskLevel(usedPercent: Double) -> RiskLevel {
        riskLevel(usedFraction: usedPercent / 100)
    }
}

public enum BillingUsageMode: String, Sendable {
    case includedSubscription
    case includedSubscriptionNearLimit
    case overLimitPayAsYouGo
    case payAsYouGoVisible
    case needsLogin
    case unknown
}

/// A first-class pay-as-you-go / usage-credit signal, set by sources that can
/// report it exactly (the Anthropic usage API's `extra_usage` block). nil for
/// the local TUI and web-dashboard sources, which can only be scanned for
/// keywords — those leave `billingUsageMode` on its string heuristics.
public enum PayAsYouGoState: String, Codable, Sendable {
    /// Overage / usage-credit billing is turned off for the account.
    case disabled
    /// Overage is enabled but included usage is not yet exhausted (a backstop).
    case enabledIdle
    /// Overage is enabled and included usage is exhausted — actively billing.
    case enabledActive
}

/// The pay-as-you-go spend figures the usage API reports alongside
/// `PayAsYouGoState`. Display-only: `usedCredits` is cumulative for the
/// billing month and stays non-zero after a rate-limit window resets, so it
/// must never drive `payAsYouGoState`/`billingUsageMode` (see the trigger
/// rationale in `ClaudeUsageAPIClient.payAsYouGoState(for:)`).
public struct PayAsYouGoSpend: Codable, Equatable, Sendable {
    public var monthlyLimit: Double?
    /// Cumulative extra-usage spend for the current billing month.
    public var usedCredits: Double?
    /// The API's own used/limit ratio; shape unconfirmed (fraction vs
    /// percent), so it is only a last-resort display fallback.
    public var utilization: Double?

    public init(monthlyLimit: Double? = nil, usedCredits: Double? = nil, utilization: Double? = nil) {
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }

    /// The one-line human summary, or nil when nothing usable was reported.
    public var summaryText: String? {
        if let usedCredits {
            if let monthlyLimit {
                return "\(Self.formatCredits(usedCredits)) of \(Self.formatCredits(monthlyLimit)) extra usage this month"
            }
            return "\(Self.formatCredits(usedCredits)) extra usage this month"
        }
        if let utilization {
            let percent = utilization <= 1 ? utilization * 100 : utilization
            return "Extra usage at \(Int(percent.rounded()))% of this month's cap"
        }
        return nil
    }

    /// The single home for credit formatting. The API's units are assumed to
    /// be dollars (unverified against a live overage response); if they turn
    /// out to be cents, this is the one line to fix.
    private static func formatCredits(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "$\(Int(rounded))"
        }
        return String(format: "$%.2f", rounded)
    }
}

public enum WebDataStoreKind: String, Codable, Sendable {
    case appDefault
    case isolated
}

public enum AccountIdentitySource: String, Codable, Sendable {
    case dashboard
    case codexIDToken
    case claudeCodeUsage
    case manual
}
