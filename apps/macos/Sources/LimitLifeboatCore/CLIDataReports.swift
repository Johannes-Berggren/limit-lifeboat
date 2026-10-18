import Foundation

// Schema v2 documents for `history` and `sessions`. Like `status`, both are
// built from local state only: the store the app writes, the process table
// and Claude Code's transcripts. Neither contacts a provider or writes.

// MARK: - history

public struct CLIHistoryReport: Codable, Equatable, Sendable {
    public static let defaultDays = 7
    /// The app keeps 30 days (`UsageHistoryStore` retention).
    public static let maximumDays = 30

    public var schema: Int
    public var generatedAt: Date
    public var days: Int
    /// The start of the window: `generatedAt` minus `days`.
    public var since: Date
    /// Every saved account in `status` order, with its records oldest first.
    /// An account with no history in the window has an empty `records`.
    public var accounts: [CLIHistoryAccount]

    public init(generatedAt: Date, days: Int, since: Date, accounts: [CLIHistoryAccount]) {
        self.schema = CLIStatusReport.schemaVersion
        self.generatedAt = generatedAt
        self.days = days
        self.since = since
        self.accounts = accounts
    }
}

public struct CLIHistoryAccount: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var label: String
    public var records: [CLIHistoryRecord]

    public init(id: String, provider: String, label: String, records: [CLIHistoryRecord]) {
        self.id = id
        self.provider = provider
        self.label = label
        self.records = records
    }
}

/// One saved reading. The app records one only when a window's numbers
/// change, so the gaps between records are not missing data.
public struct CLIHistoryRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var windows: [CLIHistoryWindow]

    public init(timestamp: Date, windows: [CLIHistoryWindow]) {
        self.timestamp = timestamp
        self.windows = windows
    }
}

public struct CLIHistoryWindow: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var label: String
    public var usedPercent: Int
    public var resetsAt: Date?
    public var windowMinutes: Int?

    public init(id: String, kind: String, label: String, usedPercent: Int, resetsAt: Date?, windowMinutes: Int?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public enum CLIHistoryReportBuilder {
    /// Reads `usage-history.jsonl` without the write side of
    /// `UsageHistoryStore` (whose `load` prunes and may rewrite the file):
    /// the CLI must never race the app's writes.
    public static func readRecords(applicationSupportDirectory: URL, since: Date) throws -> [UUID: [UsageHistoryRecord]] {
        let url = applicationSupportDirectory.appendingPathComponent("usage-history.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.appDecoder
        var records: [UUID: [UsageHistoryRecord]] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // A torn last line (the app mid-append) is skipped, as the app does.
            guard let record = try? decoder.decode(UsageHistoryRecord.self, from: Data(line)),
                  record.timestamp >= since else { continue }
            records[record.accountID, default: []].append(record)
        }
        return records.mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
    }

    public static func report(
        accounts: [CLIAccountStatus],
        records: [UUID: [UsageHistoryRecord]],
        days: Int,
        now: Date = Date()
    ) -> CLIHistoryReport {
        let since = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return CLIHistoryReport(
            generatedAt: now,
            days: days,
            since: since,
            accounts: accounts.map { account in
                let history = UUID(uuidString: account.id).flatMap { records[$0] } ?? []
                return CLIHistoryAccount(
                    id: account.id,
                    provider: account.provider,
                    label: account.label,
                    records: history.filter { $0.timestamp >= since }.map { record in
                        CLIHistoryRecord(
                            timestamp: record.timestamp,
                            windows: record.windows.map {
                                CLIHistoryWindow(
                                    id: $0.id,
                                    kind: $0.kind.rawValue,
                                    label: $0.fallbackLabel,
                                    usedPercent: UsagePercent.rounded($0.usedPercent),
                                    resetsAt: $0.resetDate,
                                    windowMinutes: $0.windowMinutes
                                )
                            }
                        )
                    }
                )
            }
        )
    }
}

// MARK: - sessions

public struct CLISessionsReport: Codable, Equatable, Sendable {
    public var schema: Int
    public var generatedAt: Date
    /// Always one entry per provider (Claude, then Codex), even with no
    /// sessions, so `.providers[] | select(.provider == "codex") | .count`
    /// never needs a null check.
    public var providers: [CLIProviderSessions]

    public init(generatedAt: Date, providers: [CLIProviderSessions]) {
        self.schema = CLIStatusReport.schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct CLIProviderSessions: Codable, Equatable, Sendable {
    public var provider: String
    public var count: Int
    /// Physical memory of every session of this provider, including the
    /// tools and servers each one started.
    public var memoryBytes: UInt64
    public var sessions: [CLIAgentSession]

    public init(provider: String, count: Int, memoryBytes: UInt64, sessions: [CLIAgentSession]) {
        self.provider = provider
        self.count = count
        self.memoryBytes = memoryBytes
        self.sessions = sessions
    }
}

public struct CLIAgentSession: Codable, Equatable, Sendable {
    public var pid: Int32
    public var provider: String
    /// The working directory's last path component.
    public var project: String
    public var workingDirectory: String?
    public var startedAt: Date
    public var memoryBytes: UInt64
    /// The session process plus every descendant counted in `memoryBytes`.
    public var processCount: Int
    /// Claude only, from the session's transcript: the model answering.
    public var model: String?
    /// Claude only: the context the next message re-sends.
    public var contextTokens: Int?
    /// Claude only: the newest transcript turn.
    public var lastActivityAt: Date?
    public var idleSeconds: Int?
    /// Claude only: the prompt cache lifetime (3600 or 300), when known.
    public var cacheTTLSeconds: Int?
    /// Present while the app has this session parked.
    public var parked: CLIParkedState?

    public init(
        pid: Int32, provider: String, project: String, workingDirectory: String?, startedAt: Date,
        memoryBytes: UInt64, processCount: Int, model: String? = nil, contextTokens: Int? = nil,
        lastActivityAt: Date? = nil, idleSeconds: Int? = nil, cacheTTLSeconds: Int? = nil,
        parked: CLIParkedState? = nil
    ) {
        self.pid = pid
        self.provider = provider
        self.project = project
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.memoryBytes = memoryBytes
        self.processCount = processCount
        self.model = model
        self.contextTokens = contextTokens
        self.lastActivityAt = lastActivityAt
        self.idleSeconds = idleSeconds
        self.cacheTTLSeconds = cacheTTLSeconds
        self.parked = parked
    }
}

public struct CLIParkedState: Codable, Equatable, Sendable {
    /// `manual` or `shortfall`.
    public var reason: String
    public var parkedAt: Date
    public var releaseAt: Date?

    public init(reason: String, parkedAt: Date, releaseAt: Date?) {
        self.reason = reason
        self.parkedAt = parkedAt
        self.releaseAt = releaseAt
    }
}

public enum CLISessionsReportBuilder {
    /// The app's parked sessions, from `session-park.json`. A heartbeat older
    /// than the hook's own stale limit means the app has stopped, and the
    /// hook already lets those sessions run, so they are not reported parked.
    public static func readParked(applicationSupportDirectory: URL, now: Date = Date()) -> [SessionParkState.Entry] {
        let url = applicationSupportDirectory.appendingPathComponent(SessionParkState.fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(SessionParkState.self, from: data),
              now.timeIntervalSince1970 - TimeInterval(state.updatedAt) <= TimeInterval(SessionParkHookScript.staleAfterSeconds) else {
            return []
        }
        return state.parked
    }

    public static func report(
        sessions: [AgentSession],
        activities: [Int32: ClaudeSessionActivity],
        parked: [SessionParkState.Entry],
        now: Date = Date()
    ) -> CLISessionsReport {
        let providers = Provider.allCases.map { provider -> CLIProviderSessions in
            let mine = sessions.filter { $0.provider == provider }.sorted { $0.startedAt < $1.startedAt }
            let rows = mine.map { session -> CLIAgentSession in
                let activity = activities[session.pid]
                // A pid can be reused; only a park recorded for this process
                // start counts (the same rule the park hook applies).
                let park = parked.first {
                    $0.pid == session.pid && abs($0.startedAt.timeIntervalSince(session.startedAt)) < 1
                }
                return CLIAgentSession(
                    pid: session.pid,
                    provider: provider.rawValue,
                    project: session.projectName,
                    workingDirectory: session.workingDirectory,
                    startedAt: session.startedAt,
                    memoryBytes: session.footprintBytes,
                    processCount: session.processCount,
                    model: activity?.model,
                    contextTokens: activity?.contextTokens,
                    lastActivityAt: activity?.lastActivityAt,
                    idleSeconds: activity.map { max(0, Int(now.timeIntervalSince($0.lastActivityAt))) },
                    cacheTTLSeconds: activity?.cacheTTLSeconds,
                    parked: park.map { CLIParkedState(reason: $0.reason.rawValue, parkedAt: $0.parkedAt, releaseAt: $0.releaseAt) }
                )
            }
            return CLIProviderSessions(
                provider: provider.rawValue,
                count: rows.count,
                memoryBytes: mine.reduce(0) { $0 + $1.footprintBytes },
                sessions: rows
            )
        }
        return CLISessionsReport(generatedAt: now, providers: providers)
    }
}

// MARK: - refresh / switch

/// What `refresh --json` and `switch --json` print: the app's response, or
/// the CLI's own error (`app_not_running`, `timeout`, …), in one shape.
public struct CLIControlOutput: Codable, Equatable, Sendable {
    public var schema: Int
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlError?

    public init(response: ControlResponse) {
        self.schema = CLIStatusReport.schemaVersion
        self.ok = response.ok
        self.result = response.result
        self.error = response.error
    }

    public static func text(for result: ControlResult) -> String {
        var lines: [String] = []
        if result.command == ControlCommand.switch.rawValue, let target = result.accounts.first {
            lines.append(result.alreadyActive == true
                ? "\(target.label) is already the active \(target.provider) account."
                : "Switched \(target.provider) to \(target.label).")
        } else if result.coalesced == true {
            lines.append("A refresh was already running; these are its results.")
        }
        for account in result.accounts {
            let age = account.ageSeconds.map { "updated \(DurationPhrase.short(TimeInterval($0))) ago" } ?? "no reading yet"
            lines.append("\(account.isActive ? "*" : " ") [\(account.provider)] \(account.label): \(age)")
            for issue in account.issues {
                lines.append("    \(issue.code): \(issue.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
