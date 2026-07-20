import Foundation

public enum PresentationTone: Equatable, Sendable {
    case secondary
    case warning
    case stale
    case success
    case danger
}

public enum AccountRowAction: Equatable, Sendable {
    case none
    case retry
    case login
    case renew

    public var title: String? {
        switch self {
        case .none:
            return nil
        case .retry:
            return "Retry"
        case .login:
            return "Log In"
        case .renew:
            return "Renew"
        }
    }
}

public struct AccountRowMessage: Equatable, Sendable {
    public var text: String
    public var icon: String
    public var tone: PresentationTone
    public var help: String
    public var action: AccountRowAction

    public init(
        text: String,
        icon: String,
        tone: PresentationTone,
        help: String? = nil,
        action: AccountRowAction = .none
    ) {
        self.text = text
        self.icon = icon
        self.tone = tone
        self.help = help ?? text
        self.action = action
    }
}

public struct BillingBadgePresentation: Equatable, Sendable {
    public var text: String
    public var tone: PresentationTone
    public var help: String

    public init(text: String, tone: PresentationTone, help: String) {
        self.text = text
        self.tone = tone
        self.help = help
    }
}

public struct AccountGaugeGroups: Equatable, Sendable {
    /// Every limit available to the card in stable display order.
    public var visible: [UsageWindow]
    public var needsSessionCaptureNote: Bool
    /// True when the visible gauges are the last reading from *before* an
    /// inactive account's windows all rolled over, so the SwiftUI layer can
    /// flag the numbers as pre-reset instead of letting stale bars contradict
    /// the green "quota restored" footer note.
    public var showsPreResetNote: Bool

    public init(
        visible: [UsageWindow],
        needsSessionCaptureNote: Bool,
        showsPreResetNote: Bool = false
    ) {
        self.visible = visible
        self.needsSessionCaptureNote = needsSessionCaptureNote
        self.showsPreResetNote = showsPreResetNote
    }
}

/// The card-level "on pace to run out" line: the most urgent window whose
/// burn-rate estimate projects depletion. The UI formats the date so locale
/// handling stays out of Core.
public struct PaceForecast: Equatable, Sendable {
    public var windowID: String
    public var windowLabel: String
    public var depletesAt: Date
    public var resetDate: Date?

    public init(windowID: String, windowLabel: String, depletesAt: Date, resetDate: Date? = nil) {
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.depletesAt = depletesAt
        self.resetDate = resetDate
    }
}

/// Immutable policy for one account card. It deliberately contains no SwiftUI
/// types, allowing status/billing/switch behavior to be unit tested in Core.
public struct AccountRowPresentation: Equatable, Sendable {
    public var identityText: String
    public var riskLevel: RiskLevel
    public var refreshProblem: AccountRowMessage?
    public var footerNote: AccountRowMessage?
    public var billingBadge: BillingBadgePresentation?
    public var gauges: AccountGaugeGroups
    /// Non-nil when a fresh reading projects a window running out before its
    /// reset — the card's visible counterpart to the pace notification.
    public var paceForecast: PaceForecast?
    public var switchTitle: String
    public var switchHelp: String
    public var highlightsSwitch: Bool
    /// Active-account renewal uses the normal login path. Inactive renewal
    /// uses the non-activating flow so the current CLI account is restored.
    public var renewalActivatesAccount: Bool

    public init(
        profile: AccountProfile,
        snapshot: UsageSnapshot?,
        hasStoredSnapshot: Bool,
        refreshState: AccountRefreshState,
        adviceReason: String?,
        estimates: [String: BurnRateEstimate] = [:],
        loginExpiresAt: Date? = nil,
        showOrganizationName: Bool = true,
        now: Date = Date()
    ) {
        self.identityText = Self.identityText(profile, showOrganizationName: showOrganizationName)
        self.riskLevel = snapshot?.riskLevel ?? .unknown
        self.renewalActivatesAccount = profile.isActiveCLI
        self.refreshProblem = Self.refreshProblem(
            state: refreshState,
            profile: profile,
            hasSnapshot: snapshot != nil,
            loginExpiresAt: loginExpiresAt,
            now: now
        )
        self.footerNote = Self.footerNote(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: hasStoredSnapshot,
            now: now
        )
        self.billingBadge = Self.billingBadge(snapshot?.billingUsageMode, spend: snapshot?.payAsYouGoSpend)
        self.gauges = Self.gaugeGroups(profile: profile, snapshot: snapshot, now: now)
        self.paceForecast = Self.paceForecast(
            snapshot: snapshot,
            gauges: self.gauges,
            estimates: estimates,
            now: now
        )

        let resetElapsed = snapshot?.allWindowsResetElapsed(asOf: now) == true
        self.switchTitle = adviceReason == nil ? "Switch" : "Best"
        let loginIsExpired = loginExpiresAt.map { now >= $0 } == true
        self.highlightsSwitch = !refreshState.requiresLogin
            && !loginIsExpired
            && (resetElapsed || adviceReason != nil)
        if refreshState.requiresLogin || loginIsExpired {
            self.switchHelp = "Log in to this account again before switching the CLI to it"
        } else if !hasStoredSnapshot {
            self.switchHelp = "Log into this account once in the terminal so its credentials can be captured"
        } else if let adviceReason {
            self.switchHelp = adviceReason
        } else if resetElapsed {
            self.switchHelp = "This account's limit window has rolled over — switch the CLI to it for fresh quota"
        } else {
            self.switchHelp = "Switch the CLI to this account's saved credentials"
        }
    }

    private static func identityText(_ profile: AccountProfile, showOrganizationName: Bool) -> String {
        var parts: [String] = []
        if let identity = profile.identity {
            if let primary = identity.primaryLabel {
                parts.append(primary)
            }
            if showOrganizationName,
               let organization = identity.organization,
               !organization.isEmpty {
                parts.append(organization)
            }
        }
        if let plan = profile.planLabel, !plan.isEmpty {
            parts.append(plan)
        }
        return parts.isEmpty ? "Not linked to a login yet" : parts.joined(separator: " • ")
    }

    private static func refreshProblem(
        state: AccountRefreshState,
        profile: AccountProfile,
        hasSnapshot: Bool,
        loginExpiresAt: Date?,
        now: Date
    ) -> AccountRowMessage? {
        switch state {
        case .idle, .refreshing, .ok:
            break
        case .readFailed(let reason):
            return AccountRowMessage(
                text: "Couldn't refresh",
                icon: "exclamationmark.triangle",
                tone: .warning,
                help: reason,
                action: .retry
            )
        case .usagePaused:
            return AccountRowMessage(
                text: "Usage paused — click to refresh",
                icon: "pause.circle",
                tone: .secondary,
                help: "Limit Lifeboat paused auto-refresh so it won't disturb your active Claude login. Click Retry to update usage now.",
                action: .retry
            )
        case .needsLogin(let reason):
            let wasPreviouslyLinked = hasSnapshot || profile.identity != nil
            return AccountRowMessage(
                text: wasPreviouslyLinked
                    ? "Login expired — sign in again"
                    : "Not linked — log in to track usage",
                icon: "person.crop.circle.badge.questionmark",
                tone: wasPreviouslyLinked ? .warning : .secondary,
                help: reason,
                action: .login
            )
        case .keychainLocked:
            return AccountRowMessage(
                text: "Keychain access needed",
                icon: "lock",
                tone: .stale,
                help: "macOS denied access to this account's saved credentials. Tap Retry to grant access.",
                action: .retry
            )
        }

        guard profile.provider == .claude,
              let loginExpiresAt,
              loginExpiresAt <= now.addingTimeInterval(5 * 24 * 60 * 60) else {
            return nil
        }
        if loginExpiresAt <= now {
            return AccountRowMessage(
                text: "Login expired — sign in again",
                icon: "person.crop.circle.badge.questionmark",
                tone: .warning,
                help: "This Claude login expired on this Mac. Other Macs keep their own device-local logins.",
                action: .login
            )
        }

        let remaining = loginExpiresAt.timeIntervalSince(now)
        let text: String
        if remaining < 24 * 60 * 60 {
            text = "Login expires today"
        } else {
            let days = Int(ceil(remaining / (24 * 60 * 60)))
            text = "Login expires in \(days) days"
        }
        return AccountRowMessage(
            text: text,
            icon: "clock.badge.exclamationmark",
            tone: .warning,
            help: "Renew this Claude login before it expires. Renewal affects this Mac only.",
            action: .renew
        )
    }

    private static func footerNote(
        profile: AccountProfile,
        snapshot: UsageSnapshot?,
        hasStoredSnapshot: Bool,
        now: Date
    ) -> AccountRowMessage? {
        guard let snapshot else {
            let text: String
            if !hasStoredSnapshot {
                text = "Log in via the terminal to link this account"
            } else {
                text = profile.isActiveCLI
                    ? "Active — usage appears on the next refresh"
                    : "Credentials saved — usage appears on the next refresh"
            }
            return AccountRowMessage(text: text, icon: "person.crop.circle.badge.questionmark", tone: .secondary)
        }

        // Gated on *every* window rolling over (not just the most-constrained
        // one) so a short reset doesn't mask a still-live weekly. Codex saved
        // accounts can now be measured live on refresh; other stale sources keep
        // the older estimate wording.
        if !profile.isActiveCLI, snapshot.allWindowsResetElapsed(asOf: now) {
            let isLiveCodex = profile.provider == .codex && hasStoredSnapshot
            let help = isLiveCodex
                ? "This reading predates the reset. Refresh usage to fetch the account's current Codex limits."
                : "Estimated from the last reading's reset time, not a live measurement. Switch to this account to confirm."
            return AccountRowMessage(
                text: isLiveCodex
                    ? "Reset window passed — refresh to confirm"
                    : "Reset window passed — quota likely restored (estimate)",
                icon: "arrow.counterclockwise.circle",
                tone: .success,
                help: help
            )
        }
        if snapshot.isStale(asOf: now) {
            return AccountRowMessage(
                text: "Last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))",
                icon: "clock",
                tone: .secondary
            )
        }
        if snapshot.orderedDisplayWindows.isEmpty, !snapshot.message.isEmpty {
            return AccountRowMessage(text: snapshot.message, icon: "info.circle", tone: .secondary)
        }
        return nil
    }

    private static func billingBadge(_ mode: BillingUsageMode?, spend: PayAsYouGoSpend?) -> BillingBadgePresentation? {
        switch mode {
        case .overLimitPayAsYouGo:
            let spendClause = spend?.summaryText.map { "\($0)." } ?? "extra usage may be billed."
            return BillingBadgePresentation(
                text: "PAYG",
                tone: .danger,
                help: "Included usage appears depleted — \(spendClause) Click for details."
            )
        case .payAsYouGoVisible:
            return BillingBadgePresentation(
                text: "Credits",
                tone: .warning,
                help: "Credit/pay-as-you-go data found; included usage unclear. Click for details."
            )
        case .needsLogin:
            return BillingBadgePresentation(
                text: "Sign in",
                tone: .stale,
                help: "Connect or refresh this account before trusting its numbers. Click for details."
            )
        case .includedSubscription, .includedSubscriptionNearLimit, .unknown, .none:
            return nil
        }
    }

    private static func gaugeGroups(profile: AccountProfile, snapshot: UsageSnapshot?, now: Date) -> AccountGaugeGroups {
        let ordered = snapshot?.orderedDisplayWindows ?? []
        let needsSession = profile.isActiveCLI
            && profile.provider == .claude
            && !ordered.isEmpty
            && !ordered.contains(where: { $0.kind == .session })
        let showsPreReset = !profile.isActiveCLI
            && !ordered.isEmpty
            && snapshot?.allWindowsResetElapsed(asOf: now) == true
        return AccountGaugeGroups(
            visible: ordered,
            needsSessionCaptureNote: needsSession,
            showsPreResetNote: showsPreReset
        )
    }

    /// The earliest projected depletion among the visible windows. Suppressed
    /// entirely for stale or pre-reset readings — a forecast extrapolated from
    /// numbers the card itself flags as outdated would be noise.
    private static func paceForecast(
        snapshot: UsageSnapshot?,
        gauges: AccountGaugeGroups,
        estimates: [String: BurnRateEstimate],
        now: Date
    ) -> PaceForecast? {
        guard let snapshot,
              !snapshot.isStale(asOf: now),
              !gauges.showsPreResetNote else {
            return nil
        }

        var best: PaceForecast?
        for window in gauges.visible {
            guard case .depletesAt(let date)? = estimates[window.id],
                  date > now,
                  !window.resetHasElapsed(asOf: now) else {
                continue
            }
            // The estimator only bounds the projection by the reset when a
            // reset date exists; without one, cap the card line to imminent
            // (24h) depletion so it cannot claim a runway of weeks.
            if window.resetDate == nil, date > now.addingTimeInterval(24 * 3600) {
                continue
            }
            if best == nil || date < best!.depletesAt {
                best = PaceForecast(
                    windowID: window.id,
                    windowLabel: window.label,
                    depletesAt: date,
                    resetDate: window.resetDate
                )
            }
        }
        return best
    }
}
