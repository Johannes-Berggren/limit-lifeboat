import Foundation

/// One problem with a saved account, as the CLI reports it in
/// `status --json --detail`.
///
/// Built from the app's in-memory `AccountRefreshState` (which the app
/// persists to `account-issues.json`) plus a few the CLI can tell from the
/// store on its own (no reading, stale reading). Messages are user-facing
/// reason strings and never contain credential material.
public struct AccountIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable {
        /// Heals on its own; nothing to do.
        case info
        /// Worth a look; the account may stop refreshing.
        case warning
        /// The user has to act (log in, authorize Keychain access, …).
        case error
    }

    /// Where the issue came from: `app` (the app's last refresh state) or
    /// `store` (derived by the CLI from the saved reading).
    public enum Source: String, Codable, Sendable {
        case app
        case store
    }

    /// Stable, machine-readable identifier, snake_case. See docs/cli.md.
    public var code: String
    public var severity: Severity
    public var message: String
    public var source: Source
    /// When the app first saw this code for the account, when known.
    public var since: Date?
    /// When the app will try again on its own, when known.
    public var retryAt: Date?

    public init(
        code: String,
        severity: Severity,
        message: String,
        source: Source,
        since: Date? = nil,
        retryAt: Date? = nil
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.source = source
        self.since = since
        self.retryAt = retryAt
    }

    /// The issue an app refresh state represents, or nil when nothing needs
    /// saying (`idle`, `refreshing`, `ok`).
    public static func from(_ state: AccountRefreshState, since: Date? = nil) -> AccountIssue? {
        func issue(_ code: String, _ severity: Severity, _ message: String, retryAt: Date? = nil) -> AccountIssue {
            AccountIssue(code: code, severity: severity, message: message, source: .app, since: since, retryAt: retryAt)
        }
        switch state {
        case .idle, .refreshing, .ok:
            return nil
        case .readFailed(let reason):
            return issue("read_failed", .warning, reason)
        case .rateLimited(let retryAt):
            return issue(
                "rate_limited", .info,
                "The provider is rate limiting usage requests. The last reading is kept; it updates on its own.",
                retryAt: retryAt
            )
        case .providerAccessForbidden(let reason):
            return issue("provider_access_forbidden", .error, reason)
        case .rotationDeferred(let reason):
            return issue("rotation_deferred", .warning, reason)
        case .switchRequired(let reason):
            return issue("switch_required", .warning, reason)
        case .credentialRepairRequired(let reason):
            return issue("credential_repair_required", .error, reason)
        case .authorizationRequired(_, let reason):
            return issue("authorization_required", .error, reason)
        case .credentialAccessBlocked(_, _, let reason):
            return issue("credential_access_blocked", .error, reason)
        case .usagePaused:
            return issue(
                "usage_paused", .info,
                "The login's access token expired while the CLI was idle. Refresh to renew it."
            )
        case .needsLogin(let reason):
            return issue("needs_login", .error, reason)
        case .keychainLocked:
            return issue("keychain_locked", .error, "The Keychain is locked or access was denied.")
        }
    }

    /// Issues the CLI can tell from the store alone.
    public static func derived(from reading: CLIUsageReading?, staleAfter: TimeInterval = CLIStatusLine.staleAfter) -> [AccountIssue] {
        guard let reading else {
            return [AccountIssue(code: "no_reading", severity: .info, message: "No usage reading has been recorded yet.", source: .store)]
        }
        guard TimeInterval(reading.ageSeconds) > staleAfter else { return [] }
        return [AccountIssue(
            code: "stale_reading",
            severity: .warning,
            message: "The last reading is \(DurationPhrase.short(TimeInterval(reading.ageSeconds))) old.",
            source: .store,
            since: reading.lastRefreshed
        )]
    }
}

/// What the app last knew about each account's problems, persisted beside
/// `profiles.json` so the read-only CLI can report it.
public struct AccountIssueSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "account-issues.json"

    public var updatedAt: Date
    /// Keyed by account id (UUID string). Accounts with no issue are absent.
    public var accounts: [String: [AccountIssue]]

    public init(updatedAt: Date, accounts: [String: [AccountIssue]]) {
        self.updatedAt = updatedAt
        self.accounts = accounts
    }
}

/// Writes and reads `account-issues.json`. The app is the only writer.
public struct AccountIssueStore: Sendable {
    public let url: URL

    public init(applicationSupportDirectory: URL) {
        self.url = applicationSupportDirectory.appendingPathComponent(AccountIssueSnapshot.fileName)
    }

    public func read() -> AccountIssueSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.appDecoder.decode(AccountIssueSnapshot.self, from: data)
    }

    public func write(_ snapshot: AccountIssueSnapshot) throws {
        let data = try JSONEncoder.appEncoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Turns the app's refresh states into the persisted snapshot, keeping each
/// issue's `since` stable while its code stays the same.
public struct AccountIssueTracker: Sendable {
    private var firstSeen: [UUID: (code: String, at: Date)] = [:]

    public init() {}

    public mutating func snapshot(
        states: [UUID: AccountRefreshState],
        knownAccounts: Set<UUID>,
        now: Date = Date()
    ) -> AccountIssueSnapshot {
        var accounts: [String: [AccountIssue]] = [:]
        var seen: [UUID: (code: String, at: Date)] = [:]
        for (id, state) in states where knownAccounts.contains(id) {
            guard let bare = AccountIssue.from(state) else { continue }
            let since = firstSeen[id].flatMap { $0.code == bare.code ? $0.at : nil } ?? now
            seen[id] = (bare.code, since)
            var issue = bare
            issue.since = since
            accounts[id.uuidString] = [issue]
        }
        firstSeen = seen
        return AccountIssueSnapshot(updatedAt: now, accounts: accounts)
    }
}
