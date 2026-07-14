import Foundation

/// Platform-neutral menu-bar content. Keeping its derivation in Core makes
/// active-account, staleness, and accessibility policy directly testable.
public struct MenuBarSummary: Equatable, Sendable {
    public var claudeValue: String
    public var codexValue: String
    public var accessibilityText: String
    public var riskLevel: RiskLevel

    public init(claudeValue: String, codexValue: String, accessibilityText: String, riskLevel: RiskLevel) {
        self.claudeValue = claudeValue
        self.codexValue = codexValue
        self.accessibilityText = accessibilityText
        self.riskLevel = riskLevel
    }

    public static let empty = MenuBarSummary(
        claudeValue: "–",
        codexValue: "–",
        accessibilityText: "LLM usage has not been refreshed.",
        riskLevel: .unknown
    )
}

public enum MenuBarSummaryProjector {
    public static func project(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date = Date()
    ) -> MenuBarSummary {
        MenuBarSummary(
            claudeValue: providerValue(.claude, profiles: profiles, snapshots: snapshots, now: now),
            codexValue: providerValue(.codex, profiles: profiles, snapshots: snapshots, now: now),
            accessibilityText: accessibilitySummary(profiles: profiles, snapshots: snapshots, now: now),
            riskLevel: highestRisk(profiles: profiles, snapshots: snapshots, now: now)
        )
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

    private static func highestRisk(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> RiskLevel {
        let activeSnapshots = Provider.allCases
            .compactMap { activeProfile($0, profiles: profiles) }
            .compactMap { snapshots[$0.id] }
        if activeSnapshots.contains(where: { $0.billingUsageMode == .overLimitPayAsYouGo }) {
            return .depleted
        }

        let risk = activeSnapshots
            .flatMap(\.primaryLimitWindows)
            .map { min($0.riskLevel, UsageThresholds.standard.riskLevel(usedPercent: $0.usedPercent)) }
            .min() ?? .unknown
        if risk == .healthy || risk == .unknown,
           !activeSnapshots.isEmpty,
           activeSnapshots.allSatisfy({ $0.isStale(asOf: now) }) {
            return .stale
        }
        return risk
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

            let session = snapshot.window(ofKind: .session)
                .map { "session \(Int($0.usedPercent.rounded())) percent used" }
                ?? "session limit unavailable"
            let weekly = snapshot.window(ofKind: .weekly)
                .map { "weekly \(Int($0.usedPercent.rounded())) percent used" }
                ?? "weekly limit unavailable"
            var entry = "\(provider.displayName) active account \(profile.label): \(session), \(weekly), \(mode)"
            if snapshot.isStale(asOf: now) {
                entry += ", last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))"
            }
            return entry
        }.joined(separator: ". ")
    }
}
