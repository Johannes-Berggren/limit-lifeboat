import Foundation

public enum PresentationTone: Equatable, Sendable {
    case secondary
    case warning
    case stale
    case success
    case danger
}

public struct AccountRowMessage: Equatable, Sendable {
    public var text: String
    public var icon: String
    public var tone: PresentationTone
    public var help: String
    public var showsRetry: Bool

    public init(text: String, icon: String, tone: PresentationTone, help: String? = nil, showsRetry: Bool = false) {
        self.text = text
        self.icon = icon
        self.tone = tone
        self.help = help ?? text
        self.showsRetry = showsRetry
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
    /// Every limit is visible in the dense card. Keeping this in the pure
    /// presentation model makes it impossible for the SwiftUI layer to
    /// accidentally reintroduce a second collapsed state.
    public var visible: [UsageWindow]
    public var needsSessionCaptureNote: Bool

    public init(visible: [UsageWindow], needsSessionCaptureNote: Bool) {
        self.visible = visible
        self.needsSessionCaptureNote = needsSessionCaptureNote
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
    public var switchTitle: String
    public var switchHelp: String
    public var highlightsSwitch: Bool

    public init(
        profile: AccountProfile,
        snapshot: UsageSnapshot?,
        hasStoredSnapshot: Bool,
        refreshState: AccountRefreshState,
        adviceReason: String?,
        now: Date = Date()
    ) {
        self.identityText = Self.identityText(profile)
        self.riskLevel = snapshot?.riskLevel ?? .unknown
        self.refreshProblem = Self.refreshProblem(
            state: refreshState,
            profile: profile,
            hasSnapshot: snapshot != nil
        )
        self.footerNote = Self.footerNote(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: hasStoredSnapshot,
            now: now
        )
        self.billingBadge = Self.billingBadge(snapshot?.billingUsageMode)
        self.gauges = Self.gaugeGroups(profile: profile, snapshot: snapshot)

        let resetElapsed = snapshot?.resetHasElapsed(asOf: now) == true
        self.switchTitle = adviceReason == nil ? "Switch" : "Best"
        self.highlightsSwitch = resetElapsed || adviceReason != nil
        if !hasStoredSnapshot {
            self.switchHelp = "Log into this account once in the terminal so its credentials can be captured"
        } else if let adviceReason {
            self.switchHelp = adviceReason
        } else if resetElapsed {
            self.switchHelp = "This account's limit window has rolled over — switch the CLI to it for fresh quota"
        } else {
            self.switchHelp = "Switch the CLI to this account's saved credentials"
        }
    }

    private static func identityText(_ profile: AccountProfile) -> String {
        var parts: [String] = []
        if let identity = profile.identity {
            if let primary = identity.primaryLabel {
                parts.append(primary)
            }
            if let organization = identity.organization, !organization.isEmpty {
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
        hasSnapshot: Bool
    ) -> AccountRowMessage? {
        switch state {
        case .idle, .refreshing, .ok:
            return nil
        case .readFailed(let reason):
            return AccountRowMessage(
                text: "Couldn't refresh",
                icon: "exclamationmark.triangle",
                tone: .warning,
                help: reason,
                showsRetry: true
            )
        case .needsLogin:
            guard hasSnapshot || profile.isActiveCLI else {
                return nil
            }
            return AccountRowMessage(
                text: "Not linked — log in to track usage",
                icon: "person.crop.circle.badge.questionmark",
                tone: .secondary,
                help: "Use the … menu → Log In via Terminal to link this account."
            )
        case .keychainLocked:
            return AccountRowMessage(
                text: "Keychain access needed",
                icon: "lock",
                tone: .stale,
                help: "macOS denied access to this account's saved credentials. Tap Retry to grant access.",
                showsRetry: true
            )
        }
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
            } else if profile.isActiveCLI {
                text = profile.provider == .codex
                    ? "Active — usage appears after you run codex"
                    : "Active — usage appears on the next refresh"
            } else {
                text = "Credentials saved — usage appears after switching to it"
            }
            return AccountRowMessage(text: text, icon: "person.crop.circle.badge.questionmark", tone: .secondary)
        }

        if !profile.isActiveCLI, snapshot.resetHasElapsed(asOf: now) {
            return AccountRowMessage(
                text: "Limit window elapsed — likely full quota again",
                icon: "arrow.counterclockwise.circle",
                tone: .success
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

    private static func billingBadge(_ mode: BillingUsageMode?) -> BillingBadgePresentation? {
        switch mode {
        case .overLimitPayAsYouGo:
            return BillingBadgePresentation(
                text: "PAYG",
                tone: .danger,
                help: "Included usage appears depleted — extra usage may be billed. Click for details."
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

    private static func gaugeGroups(profile: AccountProfile, snapshot: UsageSnapshot?) -> AccountGaugeGroups {
        let ordered = snapshot?.orderedDisplayWindows ?? []
        let needsSession = profile.isActiveCLI
            && profile.provider == .claude
            && !ordered.isEmpty
            && !ordered.contains(where: { $0.kind == .session })
        return AccountGaugeGroups(
            visible: ordered,
            needsSessionCaptureNote: needsSession
        )
    }
}
