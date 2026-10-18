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
/// against, so field names change only with the schema version. The full
/// schema is documented in docs/cli.md.
public struct CLIStatusReport: Codable, Equatable, Sendable {
    /// The schema this build writes by default.
    ///
    /// - 1: `status`, `list`, `active`.
    /// - 2: adds `issues` and `app` (with `--detail`), and the `history`,
    ///   `sessions`, `refresh` and `switch` documents. Purely additive: every
    ///   v1 field keeps its name and meaning, so a v1 reader that ignores
    ///   unknown keys keeps working. A reader that insists on `schema == 1`
    ///   can pass `--schema 1` and gets the exact v1 document.
    public static let schemaVersion = 2
    /// Every schema `--schema` accepts.
    public static let supportedSchemaVersions = [1, 2]

    public var schema: Int
    public var generatedAt: Date
    public var accounts: [CLIAccountStatus]
    /// v2, `--detail` only: what the CLI knows about the app itself.
    public var app: CLIAppState?

    public init(generatedAt: Date, accounts: [CLIAccountStatus], app: CLIAppState? = nil) {
        self.schema = Self.schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.app = app
    }

    /// The same report in an older schema: v1 drops every v2 field.
    public func pinned(to version: Int) -> CLIStatusReport {
        guard version < 2 else { return self }
        var copy = self
        copy.schema = version
        copy.app = nil
        copy.accounts = accounts.map { var account = $0; account.issues = nil; return account }
        return copy
    }
}

/// v2: whether the app is running, and how fresh its saved issue states are.
public struct CLIAppState: Codable, Equatable, Sendable {
    /// Whether the app's control socket accepted a connection just now.
    public var running: Bool
    /// When the app last wrote `account-issues.json`; nil when it never has
    /// (an app build that predates schema 2, or one never launched).
    /// App-sourced issues are as of this instant.
    public var issuesUpdatedAt: Date?

    public init(running: Bool, issuesUpdatedAt: Date?) {
        self.running = running
        self.issuesUpdatedAt = issuesUpdatedAt
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
    /// v2, `--detail` only: everything currently wrong with the account,
    /// most severe first. Empty when nothing is. Absent without `--detail`.
    public var issues: [AccountIssue]?

    public init(
        id: String,
        provider: String,
        label: String,
        email: String? = nil,
        organization: String? = nil,
        plan: String? = nil,
        isActive: Bool,
        priority: Int,
        reading: CLIUsageReading? = nil,
        issues: [AccountIssue]? = nil
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
        self.issues = issues
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

/// One line, for a shell prompt, a Claude Code status line, tmux, or a bar
/// widget.
///
/// Shows the active account per provider and the window that will block it
/// first, because that is the only number a one-line surface has room for.
/// Staleness is marked rather than hidden: a status line that silently keeps
/// showing 34% while the app has been asleep for six hours is worse than no
/// status line.
public enum CLIStatusLine {
    /// Readings older than this are marked with `?`. Matched to the app's own
    /// stale threshold so both surfaces call the same reading stale.
    public static let staleAfter: TimeInterval = 30 * 60
    /// Claude Code's own numbers carry no risk level; mark them from here,
    /// the app's default warning threshold.
    static let liveWarningPercent = 80

    /// - Parameter claude: what Claude Code piped in, when the status line
    ///   runs inside it. It fills in for a stale or missing stored Claude
    ///   reading (it only knows the 5h and 7d windows of the session's own
    ///   login, so a fresh cross-device reading still wins) and adds the
    ///   session's prompt-cache state. The payload names no account: right
    ///   after a switch, a session still running on the previous login can
    ///   report that login's numbers, which is why a fresh stored reading
    ///   always takes precedence.
    public static func text(
        for report: CLIStatusReport,
        claude: ClaudeStatusLineInput? = nil,
        now: Date = Date()
    ) -> String {
        var segments = report.accounts
            .filter(\.isActive)
            .compactMap { segment(for: $0, claude: claude) }
        if let cache = claude?.promptCache.flatMap({ cacheSegment($0, now: now) }) {
            segments.append(cache)
        }

        return segments.isEmpty ? "no active account" : segments.joined(separator: " · ")
    }

    private static func segment(for account: CLIAccountStatus, claude: ClaudeStatusLineInput?) -> String? {
        let live = account.provider == Provider.claude.rawValue ? claude?.rateLimitPercent : nil
        guard let reading = account.reading, let percent = reading.mostConstrainedPercent else {
            return live.map { "\(account.provider) \($0)%\($0 >= liveWarningPercent ? "!" : "")" }
                ?? "\(account.provider) —"
        }

        let isStale = TimeInterval(reading.ageSeconds) > staleAfter
        if isStale, let live {
            return "\(account.provider) \(live)%\(live >= liveWarningPercent ? "!" : "")"
        }
        let stale = isStale ? "?" : ""
        let alert = (reading.risk == "depleted" || reading.risk == "warning") ? "!" : ""
        return "\(account.provider) \(percent)%\(alert)\(stale)"
    }

    /// "cache 42m" while warm (time left before it expires), "cache cold
    /// 350K" once it has expired (what the next message re-reads uncached).
    private static func cacheSegment(_ cache: ClaudeStatusLineInput.PromptCache, now: Date) -> String? {
        if cache.warm {
            guard let expiresAt = cache.expiresAt else { return cache.ttl.map { "cache \($0)" } }
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining >= 60 { return "cache \(Int(remaining / 60))m" }
            if remaining > 0 { return "cache <1m" }
            // Already past expiry (an older payload, or clock skew): cold.
        }
        guard let tokens = cache.recacheTokensIfCold, tokens > 0 else { return "cache cold" }
        return "cache cold \(MemoryFormatting.tokens(tokens))"
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

    /// `--detail`: attaches every account's issues — the app's saved refresh
    /// state plus what the store alone shows — and the app's own state.
    public static func detailed(
        _ report: CLIStatusReport,
        issueSnapshot: AccountIssueSnapshot?,
        appRunning: Bool
    ) -> CLIStatusReport {
        var copy = report
        copy.app = CLIAppState(running: appRunning, issuesUpdatedAt: issueSnapshot?.updatedAt)
        copy.accounts = report.accounts.map { account in
            var account = account
            let fromApp = issueSnapshot?.accounts[account.id] ?? []
            let fromStore = AccountIssue.derived(from: account.reading)
            account.issues = (fromApp + fromStore).sorted { rank($0.severity) > rank($1.severity) }
            return account
        }
        return copy
    }

    private static func rank(_ severity: AccountIssue.Severity) -> Int {
        switch severity {
        case .error: return 2
        case .warning: return 1
        case .info: return 0
        }
    }

    private static func reading(from snapshot: UsageSnapshot, now: Date) -> CLIUsageReading {
        let windows = snapshot.orderedDisplayWindows.map {
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
