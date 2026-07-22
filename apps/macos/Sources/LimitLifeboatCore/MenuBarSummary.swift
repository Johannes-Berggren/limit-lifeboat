import Foundation

public struct MenuBarLimitValue: Equatable, Sendable {
    public var label: String
    public var usedPercent: Int
    public var riskLevel: RiskLevel

    public init(label: String, usedPercent: Int, riskLevel: RiskLevel) {
        self.label = label
        self.usedPercent = usedPercent
        self.riskLevel = riskLevel
    }
}

public struct MenuBarProviderLimits: Equatable, Sendable {
    public var provider: Provider
    public var limits: [MenuBarLimitValue]

    public init(provider: Provider, limits: [MenuBarLimitValue]) {
        self.provider = provider
        self.limits = limits
    }
}

/// Platform-neutral menu-bar content. Keeping its derivation in Core makes
/// active-account, staleness, and accessibility policy directly testable.
public struct MenuBarSummary: Equatable, Sendable {
    public var claudeValue: String
    public var codexValue: String
    public var compactValue: String
    public var accessibilityText: String
    public var riskLevel: RiskLevel
    /// Every reported quota for each currently active provider account, in
    /// stable provider and window display order. An empty limit array means
    /// that provider has an active account whose reading is unavailable.
    public var activeProviderLimits: [MenuBarProviderLimits]

    public init(
        claudeValue: String,
        codexValue: String,
        accessibilityText: String,
        riskLevel: RiskLevel,
        compactValue: String = "–",
        activeProviderLimits: [MenuBarProviderLimits] = []
    ) {
        self.claudeValue = claudeValue
        self.codexValue = codexValue
        self.compactValue = compactValue
        self.accessibilityText = accessibilityText
        self.riskLevel = riskLevel
        self.activeProviderLimits = activeProviderLimits
    }

    public static let empty = MenuBarSummary(
        claudeValue: "–",
        codexValue: "–",
        accessibilityText: "LLM usage has not been refreshed.",
        riskLevel: .unknown,
        compactValue: "–"
    )
}

public enum MenuBarSummaryProjector {
    public static func project(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date = Date()
    ) -> MenuBarSummary {
        let selected = mostRelevantActiveWindow(
            profiles: profiles,
            snapshots: snapshots
        )
        return MenuBarSummary(
            claudeValue: providerValue(.claude, profiles: profiles, snapshots: snapshots, now: now),
            codexValue: providerValue(.codex, profiles: profiles, snapshots: snapshots, now: now),
            accessibilityText: accessibilitySummary(profiles: profiles, snapshots: snapshots, now: now),
            riskLevel: highestRisk(
                profiles: profiles,
                snapshots: snapshots,
                selected: selected,
                now: now
            ),
            compactValue: compactValue(profiles: profiles, selected: selected),
            activeProviderLimits: activeProviderLimits(
                profiles: profiles,
                snapshots: snapshots,
                now: now
            )
        )
    }

    private struct SelectedWindow {
        var window: UsageWindow
        var snapshot: UsageSnapshot
    }

    private static func activeProfile(_ provider: Provider, profiles: [AccountProfile]) -> AccountProfile? {
        profiles.first { $0.provider == provider && $0.isActiveCLI }
    }

    private static func providerValue(
        _ provider: Provider,
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> String {
        guard let profile = activeProfile(provider, profiles: profiles) else {
            return "–"
        }
        guard let snapshot = snapshots[profile.id] else {
            return "S ? W ?"
        }

        let session = percentValue(snapshot.window(ofKind: .session))
        let weekly = percentValue(snapshot.window(ofKind: .weekly))
        var value = "S \(session) W \(weekly)"
        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            value += " PAYG"
        }
        if snapshot.isStale(asOf: now) {
            value += "*"
        }
        return value
    }

    private static func percentValue(_ window: UsageWindow?) -> String {
        guard let window else { return "–" }
        return "\(Int(window.usedPercent.rounded()))%"
    }

    private static func activeProviderLimits(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> [MenuBarProviderLimits] {
        Provider.allCases.compactMap { provider in
            guard let profile = activeProfile(provider, profiles: profiles) else {
                return nil
            }
            guard let snapshot = snapshots[profile.id] else {
                return MenuBarProviderLimits(provider: provider, limits: [])
            }

            let isStale = snapshot.isStale(asOf: now)
            let limits = snapshot.orderedDisplayWindows.map { window in
                MenuBarLimitValue(
                    label: shortLabel(for: window),
                    usedPercent: Int(window.usedPercent.rounded()),
                    riskLevel: isStale
                        ? .stale
                        : min(
                            window.riskLevel,
                            UsageThresholds.standard.riskLevel(usedPercent: window.usedPercent)
                        )
                )
            }
            return MenuBarProviderLimits(provider: provider, limits: limits)
        }
    }

    private static func shortLabel(for window: UsageWindow) -> String {
        switch window.kind {
        case .session:
            return "S"
        case .weekly:
            return "W"
        case .weeklyScoped:
            // Collapse the scoped window to a single-letter tag (e.g.
            // "Weekly (Fable)" -> "F") so the menu bar stays compact.
            let label = window.label
            if let opening = label.firstIndex(of: "("),
               label.last == ")",
               opening < label.index(before: label.endIndex) {
                let scope = label[label.index(after: opening)..<label.index(before: label.endIndex)]
                if let first = scope.first {
                    return String(first)
                }
            }
            return label
        case .other:
            return window.label
        }
    }

    private static func compactValue(
        profiles: [AccountProfile],
        selected: SelectedWindow?
    ) -> String {
        if let selected {
            return percentValue(selected.window)
        }
        return profiles.contains(where: \.isActiveCLI) ? "?" : "–"
    }

    /// Each provider first chooses its useful headline quota (normally session,
    /// or weekly once it enters the warning band). Stable provider traversal
    /// then chooses the tighter of those headline quotas for the menu bar.
    private static func mostRelevantActiveWindow(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot]
    ) -> SelectedWindow? {
        var selected: SelectedWindow?
        for provider in Provider.allCases {
            guard let profile = activeProfile(provider, profiles: profiles),
                  let snapshot = snapshots[profile.id] else {
                continue
            }
            guard let window = snapshot.mostRelevantWindow else {
                continue
            }
            if selected == nil || window.usedPercent > selected!.window.usedPercent {
                selected = SelectedWindow(window: window, snapshot: snapshot)
            }
        }
        return selected
    }

    private static func highestRisk(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        selected: SelectedWindow?,
        now: Date
    ) -> RiskLevel {
        let activeSnapshots = Provider.allCases
            .compactMap { activeProfile($0, profiles: profiles) }
            .compactMap { snapshots[$0.id] }
        if activeSnapshots.contains(where: { $0.billingUsageMode == .overLimitPayAsYouGo }) {
            return .depleted
        }

        guard let selected else {
            if !activeSnapshots.isEmpty,
               activeSnapshots.allSatisfy({ $0.isStale(asOf: now) }) {
                return .stale
            }
            return .unknown
        }
        if selected.snapshot.isStale(asOf: now) {
            return .stale
        }
        return min(
            selected.window.riskLevel,
            UsageThresholds.standard.riskLevel(usedPercent: selected.window.usedPercent)
        )
    }

    private static func accessibilitySummary(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> String {
        guard !profiles.isEmpty else {
            return "No accounts yet. Log into Claude Code or Codex in the terminal to register one."
        }

        return Provider.allCases.map { provider in
            guard let profile = activeProfile(provider, profiles: profiles),
                  let snapshot = snapshots[profile.id] else {
                return "\(provider.displayName) usage unknown"
            }

            let mode: String
            switch snapshot.billingUsageMode {
            case .includedSubscription:
                mode = "using included subscription usage"
            case .includedSubscriptionNearLimit:
                mode = "using included subscription usage near the limit"
            case .overLimitPayAsYouGo:
                mode = "using pay as you go or credits"
            case .payAsYouGoVisible:
                mode = "showing pay as you go status"
            case .needsLogin:
                mode = "needs login"
            case .unknown:
                mode = "usage mode unknown"
            }

            let windows = snapshot.orderedDisplayWindows
            let usage = windows.isEmpty
                ? "usage unavailable"
                : windows.map {
                    "\($0.label) \(Int($0.usedPercent.rounded())) percent used"
                }.joined(separator: ", ")
            var entry = "\(provider.displayName) active account \(profile.label): \(usage), \(mode)"
            if snapshot.isStale(asOf: now) {
                entry += ", last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))"
            }
            return entry
        }.joined(separator: ". ")
    }
}
