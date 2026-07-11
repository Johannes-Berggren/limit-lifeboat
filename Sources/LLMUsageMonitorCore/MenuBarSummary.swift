import Foundation

/// Which quota window the compact summary should prioritize.
public enum MenuBarWindowPreference: String, CaseIterable, Sendable {
    case mostConstrained
    case session
    case weekly
}

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
        preference: MenuBarWindowPreference,
        now: Date = Date()
    ) -> MenuBarSummary {
        MenuBarSummary(
            claudeValue: providerValue(.claude, profiles: profiles, snapshots: snapshots, preference: preference, now: now),
            codexValue: providerValue(.codex, profiles: profiles, snapshots: snapshots, preference: preference, now: now),
            accessibilityText: accessibilitySummary(profiles: profiles, snapshots: snapshots, now: now),
            riskLevel: highestRisk(profiles: profiles, snapshots: snapshots, now: now)
        )
    }

    public static func preferredUsedFraction(
        for snapshot: UsageSnapshot,
        preference: MenuBarWindowPreference
    ) -> Double? {
        let mostConstrained = snapshot.mostConstrainedWindow?.usedFraction ?? snapshot.usedFraction
        switch preference {
        case .mostConstrained:
            return mostConstrained
        case .session:
            return snapshot.window(ofKind: .session)?.usedFraction ?? mostConstrained
        case .weekly:
            return snapshot.primaryWeeklyWindow?.usedFraction ?? mostConstrained
        }
    }

    private static func activeProfile(_ provider: Provider, profiles: [AccountProfile]) -> AccountProfile? {
        profiles.first { $0.provider == provider && $0.isActiveCLI }
    }

    private static func providerValue(
        _ provider: Provider,
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        preference: MenuBarWindowPreference,
        now: Date
    ) -> String {
        guard let profile = activeProfile(provider, profiles: profiles) else {
            return "–"
        }
        guard let snapshot = snapshots[profile.id] else {
            return "?"
        }
        let staleMark = snapshot.isStale(asOf: now) ? "*" : ""
        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            return "PAYG\(staleMark)"
        }
        guard let used = preferredUsedFraction(for: snapshot, preference: preference) else {
            return "?"
        }
        return "\(Int((used * 100).rounded()))%\(staleMark)"
    }

    private static func highestRisk(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date
    ) -> RiskLevel {
        let activeSnapshots = Provider.allCases
            .compactMap { activeProfile($0, profiles: profiles) }
            .compactMap { snapshots[$0.id] }
        let snapshotRisk = activeSnapshots.map(\.riskLevel).min() ?? .unknown
        let thresholdRisk = activeSnapshots
            .compactMap(\.usedFraction)
            .map(UsageThresholds.standard.riskLevel(usedFraction:))
            .min() ?? .unknown
        let risk = min(snapshotRisk, thresholdRisk)
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

            let windows = snapshot.orderedDisplayWindows
                .map { "\($0.label) \(Int($0.usedPercent.rounded())) percent used" }
                .joined(separator: ", ")
            var entry: String
            if !windows.isEmpty {
                entry = "\(provider.displayName) active account \(profile.label): \(windows), \(mode)"
            } else if let used = snapshot.usedFraction {
                entry = "\(provider.displayName) active account \(profile.label) \(Int((used * 100).rounded())) percent used, \(mode)"
            } else {
                entry = "\(provider.displayName) active account \(profile.label) \(mode)"
            }
            if snapshot.isStale(asOf: now) {
                entry += ", last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))"
            }
            return entry
        }.joined(separator: ". ")
    }
}
