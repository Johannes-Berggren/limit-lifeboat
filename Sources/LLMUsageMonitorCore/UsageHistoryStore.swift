import Foundation

/// One window's numbers as they stood at a refresh. Deliberately omits the
/// cosmetic fields (`label`, `resetDescription`, `riskLevel`): a relabel or a
/// risk re-rank is not a new observation and must not defeat dedupe and grow
/// the history file.
public struct UsageWindowReading: Codable, Equatable, Sendable {
    public var id: String
    public var kind: UsageWindowKind
    public var usedPercent: Double
    public var resetDate: Date?
    public var windowMinutes: Int?

    public init(
        id: String,
        kind: UsageWindowKind,
        usedPercent: Double,
        resetDate: Date? = nil,
        windowMinutes: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetDate = resetDate
        self.windowMinutes = windowMinutes
    }

    public init(window: UsageWindow) {
        self.init(
            id: window.id,
            kind: window.kind,
            usedPercent: window.usedPercent,
            resetDate: window.resetDate,
            windowMinutes: window.windowMinutes
        )
    }
}

/// Everything one refresh learned about one account: a timestamped reading of
/// every reported window. One JSONL line per record.
public struct UsageHistoryRecord: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var accountID: UUID
    public var windows: [UsageWindowReading]

    public init(timestamp: Date, accountID: UUID, windows: [UsageWindowReading]) {
        self.timestamp = timestamp
        self.accountID = accountID
        self.windows = windows
    }
}

/// Append-only usage history persisted as one JSON object per line in
/// "usage-history.jsonl", so recording a refresh costs a single appended line
/// instead of rewriting the whole file.
///
/// Not thread-safe by design: the app has a single writer (the @MainActor
/// AppState refresh loop), so every call is expected to come from that actor.
/// Call `load()` once at startup; the mutating methods load lazily as a
/// safety net so an unloaded store can never clobber the file on disk.
public final class UsageHistoryStore {
    /// How often `append` re-runs `prune(now:)` on its own.
    private static let autoPruneInterval: TimeInterval = 24 * 60 * 60

    private let fileManager: FileManager
    public let applicationSupportDirectory: URL
    private let historyURL: URL
    private let retention: TimeInterval
    private let maxRecordsPerAccount: Int

    /// Chronological records per account, mirrored from disk.
    private var cache: [UUID: [UsageHistoryRecord]] = [:]
    private var lastPruned: Date?
    private var hasLoaded = false

    public init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        retention: TimeInterval = 30 * 24 * 3600,
        maxRecordsPerAccount: Int = 5000
    ) throws {
        self.fileManager = fileManager
        let directory: URL
        if let applicationSupportDirectory {
            directory = applicationSupportDirectory
        } else if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directory = base.appendingPathComponent("LLMUsageMonitor", isDirectory: true)
        } else {
            throw ProfileRepositoryError.missingApplicationSupportDirectory
        }

        self.applicationSupportDirectory = directory
        self.historyURL = directory.appendingPathComponent("usage-history.jsonl")
        self.retention = retention
        self.maxRecordsPerAccount = maxRecordsPerAccount
    }

    /// Reads the whole log into the in-memory cache, then prunes. Malformed or
    /// truncated lines (e.g. a crash mid-append) are skipped silently rather
    /// than failing the load and losing the rest of the history. A missing
    /// file is a successful empty load, but a read that THROWS leaves the
    /// store unloaded: marking it loaded would let a later `prune()` or
    /// `removeAccount()` rewrite mistake the empty cache for the real history
    /// and truncate the file.
    public func load(now: Date = Date()) throws {
        hasLoaded = false
        cache = [:]
        guard fileManager.fileExists(atPath: historyURL.path) else {
            hasLoaded = true
            lastPruned = now
            return
        }

        let data = try Data(contentsOf: historyURL)
        let decoder = JSONDecoder.appDecoder
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(UsageHistoryRecord.self, from: Data(line)) else {
                continue
            }
            cache[record.accountID, default: []].append(record)
        }
        for accountID in cache.keys {
            cache[accountID]?.sort { $0.timestamp < $1.timestamp }
        }
        hasLoaded = true
        try prune(now: now)
    }

    /// Appends one record for the snapshot's account. Returns false without
    /// touching the file when there is nothing worth recording: a failed parse
    /// (`parseConfidence == .none`), no windows at all, or readings identical
    /// to the account's previous record (timestamp-only churn between polls).
    @discardableResult
    public func append(_ snapshot: UsageSnapshot) throws -> Bool {
        try loadIfNeeded()
        guard snapshot.parseConfidence != .none else {
            return false
        }
        // orderedDisplayWindows rather than the raw windows so the persisted
        // history is deduped and display-ordered at the source.
        let readings = snapshot.orderedDisplayWindows.map(UsageWindowReading.init(window:))
        guard !readings.isEmpty else {
            return false
        }
        if let last = cache[snapshot.accountID]?.last, last.windows == readings {
            return false
        }

        let record = UsageHistoryRecord(
            timestamp: snapshot.lastRefreshed,
            accountID: snapshot.accountID,
            windows: readings
        )
        try appendLine(record)
        cache[snapshot.accountID, default: []].append(record)

        // Data time rather than wall-clock time keeps this deterministic; in
        // the app the two are the same because refreshes stamp lastRefreshed
        // with the current date.
        if let lastPruned, record.timestamp.timeIntervalSince(lastPruned) > Self.autoPruneInterval {
            try prune(now: record.timestamp)
        }
        return true
    }

    public func records(for accountID: UUID) -> [UsageHistoryRecord] {
        cache[accountID] ?? []
    }

    /// The chronological series for one window of one account, ready for the
    /// burn-rate estimator and sparklines.
    public func readings(accountID: UUID, windowID: String) -> [(timestamp: Date, reading: UsageWindowReading)] {
        records(for: accountID).compactMap { record in
            guard let reading = record.windows.first(where: { $0.id == windowID }) else {
                return nil
            }
            return (timestamp: record.timestamp, reading: reading)
        }
    }

    /// Drops records older than `retention`, keeps at most
    /// `maxRecordsPerAccount` of the newest records per account, and rewrites
    /// the file atomically — but only when something was actually removed.
    /// `append` runs this automatically at most once per 24 hours.
    public func prune(now: Date = Date()) throws {
        try loadIfNeeded()
        lastPruned = now

        let cutoff = now.addingTimeInterval(-retention)
        var pruned: [UUID: [UsageHistoryRecord]] = [:]
        var changed = false
        for (accountID, records) in cache {
            var kept = records.filter { $0.timestamp >= cutoff }
            if kept.count > maxRecordsPerAccount {
                kept.removeFirst(kept.count - maxRecordsPerAccount)
            }
            if kept.count != records.count {
                changed = true
            }
            if !kept.isEmpty {
                pruned[accountID] = kept
            }
        }

        guard changed else {
            return
        }
        cache = pruned
        try rewrite()
    }

    /// Forgets an account's history entirely (profile deletion).
    public func removeAccount(_ accountID: UUID) throws {
        try loadIfNeeded()
        guard cache.removeValue(forKey: accountID) != nil else {
            return
        }
        try rewrite()
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else {
            return
        }
        try load()
    }

    /// O(1) in file size: seek to the end and write exactly one line.
    private func appendLine(_ record: UsageHistoryRecord) throws {
        try ensureDirectory()
        if !fileManager.fileExists(atPath: historyURL.path) {
            fileManager.createFile(atPath: historyURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: historyURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.encodeLine(record))
    }

    private func rewrite() throws {
        try ensureDirectory()
        var data = Data()
        let orderedAccountIDs = cache.keys.sorted { $0.uuidString < $1.uuidString }
        for accountID in orderedAccountIDs {
            for record in cache[accountID] ?? [] {
                data.append(try Self.encodeLine(record))
            }
        }
        try data.write(to: historyURL, options: [.atomic])
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
    }

    /// `JSONEncoder.appEncoder` pretty-prints; JSONL needs exactly one line per
    /// record, so this keeps the sorted keys and ISO8601 dates but drops
    /// `.prettyPrinted`, then terminates the line.
    private static func encodeLine(_ record: UsageHistoryRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
