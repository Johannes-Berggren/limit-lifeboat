import Foundation

/// The machine-readable view of what the app last knew, for the `limitlifeboat`
/// command-line tool.
///
/// Deliberately built from the persisted store rather than from the providers:
/// a status line redraws on every prompt, so it must be cheap, offline, and
/// incapable of tripping a rate limit of its own. The app is the only thing
/// that talks to Anthropic and OpenAI; the CLI reports what the app last saw
/// and says how old that is, so a caller can tell "healthy" from "nobody has
/// looked in six hours".
///
/// This is also the contract third-party status lines and bar widgets build
/// against, so field names change only with the schema version.
public struct CLIStatusReport: Codable, Equatable, Sendable {
    /// Bumped when a field is removed or its meaning changes; additive fields
    /// do not bump it.
    public static let schemaVersion = 1

    public var schema: Int
    public var generatedAt: Date
    public var accounts: [CLIAccountStatus]

    public init(generatedAt: Date, accounts: [CLIAccountStatus]) {
        self.schema = Self.schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }
}

/// One saved account and its most recent reading.
public struct CLIAccountStatus: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var label: String
    /// The provider-reported identity, when the app has resolved one.
    public var email: String?
    public var organization: String?
    public var plan: String?
    /// Whether this is the account the provider's CLI is currently logged into.
    public var isActive: Bool
    /// The account's position in its provider's priority order, matching
    /// `SwitchCandidate.priorityRank`: 0 is the app's first choice. Ranks are
    /// per provider, so a Claude and a Codex account can both be 0.
    public var priority: Int
    /// nil when the app has never recorded a reading for this account.
    public var reading: CLIUsageReading?

    public init(
        id: String,
        provider: String,
        label: String,
        email: String? = nil,
        organization: String? = nil,
        plan: String? = nil,
        isActive: Bool,
        priority: Int,
        reading: CLIUsageReading? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.email = email
        self.organization = organization
        self.plan = plan
        self.isActive = isActive
        self.priority = priority
        self.reading = reading
    }
}

public struct CLIUsageReading: Codable, Equatable, Sendable {
    /// `healthy`, `warning`, `depleted`, `stale`, or `unknown`.
    public var risk: String
    /// The highest used percentage across the account's windows — the one that
    /// will block you first.
    public var mostConstrainedPercent: Int?
    public var windows: [CLIUsageWindow]
    public var lastRefreshed: Date
    /// Seconds since the app recorded this reading. A caller deciding whether
    /// to trust the number needs the age more than the timestamp.
    public var ageSeconds: Int
    /// Where the reading came from, e.g. the usage API or the local TUI.
    public var source: String
    /// The month's overage spend, already scaled and localised.
    public var extraUsage: String?

    public init(
        risk: String,
        mostConstrainedPercent: Int?,
        windows: [CLIUsageWindow],
        lastRefreshed: Date,
        ageSeconds: Int,
        source: String,
        extraUsage: String?
    ) {
        self.risk = risk
        self.mostConstrainedPercent = mostConstrainedPercent
        self.windows = windows
        self.lastRefreshed = lastRefreshed
        self.ageSeconds = ageSeconds
        self.source = source
        self.extraUsage = extraUsage
    }
}

public struct CLIUsageWindow: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var usedPercent: Int
    public var risk: String
    public var resetsAt: Date?

    public init(
        id: String,
        kind: String,
        label: String,
        usedPercent: Int,
        risk: String,
        resetsAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.risk = risk
        self.resetsAt = resetsAt
    }
}

public enum CLIStatusReportBuilder {
    /// Projects saved profiles and their stored snapshots into the report.
    ///
    /// Grouped by provider, and within a provider left in repository order,
    /// because that order *is* the user's switch priority — the same rule
    /// `AppState.switchCandidates(for:)` applies. A status line that prints the
    /// first entry for a provider gets the account the app would prefer.
    public static func report(
        profiles: [AccountProfile],
        snapshots: [UUID: UsageSnapshot],
        now: Date = Date()
    ) -> CLIStatusReport {
        let accounts = Provider.allCases.flatMap { provider in
            profiles
                .filter { $0.provider == provider }
                .enumerated()
                .map { rank, profile in
                    CLIAccountStatus(
                        id: profile.id.uuidString,
                        provider: profile.provider.rawValue,
                        label: profile.label,
                        email: profile.identity?.email,
                        organization: profile.identity?.organization,
                        plan: profile.planLabel,
                        isActive: profile.isActiveCLI,
                        priority: rank,
                        reading: snapshots[profile.id].map { reading(from: $0, now: now) }
                    )
                }
        }

        return CLIStatusReport(generatedAt: now, accounts: accounts)
    }

    private static func reading(from snapshot: UsageSnapshot, now: Date) -> CLIUsageReading {
        let windows = snapshot.windows.map {
            CLIUsageWindow(
                id: $0.id,
                kind: $0.kind.rawValue,
                label: $0.label,
                usedPercent: UsagePercent.rounded($0.usedPercent),
                risk: $0.riskLevel.rawValue,
                resetsAt: $0.resetDate
            )
        }

        return CLIUsageReading(
            risk: snapshot.riskLevel.rawValue,
            mostConstrainedPercent: windows.map(\.usedPercent).max(),
            windows: windows,
            lastRefreshed: snapshot.lastRefreshed,
            ageSeconds: max(0, Int(now.timeIntervalSince(snapshot.lastRefreshed))),
            source: snapshot.source,
            extraUsage: snapshot.payAsYouGoSpend?.summaryText
        )
    }
}
