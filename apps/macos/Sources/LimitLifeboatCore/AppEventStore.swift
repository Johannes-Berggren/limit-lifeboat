import Foundation

/// One app-performed action worth counting later (currently just CLI
/// switches, for the weekly digest). External logins detected by
/// reconciliation are deliberately NOT events — they are not app actions.
public struct AppEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case cliSwitch
    }

    public var timestamp: Date
    public var kind: Kind
    public var provider: Provider
    public var toProfileID: UUID
    public var fromProfileID: UUID?
    /// True for user-initiated switches (in-app or notification click),
    /// false for auto-switch.
    public var interactive: Bool

    public init(
        timestamp: Date,
        kind: Kind,
        provider: Provider,
        toProfileID: UUID,
        fromProfileID: UUID? = nil,
        interactive: Bool
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.provider = provider
        self.toProfileID = toProfileID
        self.fromProfileID = fromProfileID
        self.interactive = interactive
    }
}

/// Append-only event log, a deliberately tiny sibling of `UsageHistoryStore`:
/// one JSON object per line in "app-events.jsonl", single @MainActor writer,
/// malformed lines skipped on load, and a throwing load leaves the store
/// unloaded so a later rewrite cannot truncate the real file.
public final class AppEventStore {
    private let fileManager: FileManager
    private let eventsURL: URL
    private let retention: TimeInterval
    private let maxRecords: Int

    private var cache: [AppEvent] = []
    private var hasLoaded = false

    public init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        retention: TimeInterval = 90 * 24 * 3600,
        maxRecords: Int = 1000
    ) {
        self.fileManager = fileManager
        self.eventsURL = applicationSupportDirectory.appendingPathComponent("app-events.jsonl")
        self.retention = retention
        self.maxRecords = maxRecords
    }

    public func load() throws {
        hasLoaded = false
        cache = []
        guard fileManager.fileExists(atPath: eventsURL.path) else {
            hasLoaded = true
            return
        }
        let data = try Data(contentsOf: eventsURL)
        let decoder = JSONDecoder.appDecoder
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = try? decoder.decode(AppEvent.self, from: Data(line)) else {
                continue
            }
            cache.append(event)
        }
        cache.sort { $0.timestamp < $1.timestamp }
        hasLoaded = true
    }

    public func append(_ event: AppEvent) throws {
        try loadIfNeeded()
        try appendLine(event)
        cache.append(event)
        cache.sort { $0.timestamp < $1.timestamp }
        if cache.count > maxRecords || cache.first.map({ event.timestamp.timeIntervalSince($0.timestamp) > retention }) == true {
            try prune(now: event.timestamp)
        }
    }

    public func events(in interval: DateInterval) -> [AppEvent] {
        cache.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
    }

    public func prune(now: Date = Date()) throws {
        try loadIfNeeded()
        let cutoff = now.addingTimeInterval(-retention)
        var kept = cache.filter { $0.timestamp >= cutoff }
        if kept.count > maxRecords {
            kept.removeFirst(kept.count - maxRecords)
        }
        guard kept.count != cache.count else {
            return
        }
        cache = kept
        try rewrite()
    }

    /// Profile-deletion hygiene: a digest must never count switches for an
    /// account that no longer exists.
    public func removeAccount(_ accountID: UUID) throws {
        try loadIfNeeded()
        let kept = cache.filter { $0.toProfileID != accountID && $0.fromProfileID != accountID }
        guard kept.count != cache.count else {
            return
        }
        cache = kept
        try rewrite()
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else {
            return
        }
        try load()
    }

    private func appendLine(_ event: AppEvent) throws {
        try ensureDirectory()
        if !fileManager.fileExists(atPath: eventsURL.path) {
            fileManager.createFile(atPath: eventsURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.encodeLine(event))
    }

    private func rewrite() throws {
        try ensureDirectory()
        var data = Data()
        for event in cache {
            data.append(try Self.encodeLine(event))
        }
        try data.write(to: eventsURL, options: [.atomic])
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: eventsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private static func encodeLine(_ event: AppEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
