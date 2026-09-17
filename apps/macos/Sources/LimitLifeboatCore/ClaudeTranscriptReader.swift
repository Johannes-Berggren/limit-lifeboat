import Foundation

/// What the newest assistant turn of a Claude Code transcript says about the
/// session: which model is answering and how large the context has grown.
public struct ClaudeSessionActivity: Equatable, Sendable {
    public let model: String?
    /// Input + cache read + cache creation of the latest turn — the context
    /// the next message re-sends, and re-processes uncached once the cache
    /// has expired.
    public let contextTokens: Int
    public let lastActivityAt: Date

    public init(model: String?, contextTokens: Int, lastActivityAt: Date) {
        self.model = model
        self.contextTokens = contextTokens
        self.lastActivityAt = lastActivityAt
    }
}

public struct ClaudeTranscriptReader {
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let tailBytes: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        tailBytes: Int = 512 * 1024
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.tailBytes = tailBytes
    }

    /// Claude Code stores transcripts under ~/.claude/projects/<cwd with every
    /// character outside [A-Za-z0-9-] replaced by "-">.
    public static func projectDirectoryName(for workingDirectory: String) -> String {
        String(workingDirectory.map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-")
                ? character
                : "-"
        })
    }

    /// Transcripts touched since `startedAt`, newest first. Several sessions
    /// can share one working directory; callers pair them up.
    public func recentTranscripts(workingDirectory: String, since startedAt: Date) -> [URL] {
        let directory = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(Self.projectDirectoryName(for: workingDirectory), isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      modified >= startedAt.addingTimeInterval(-5) else {
                    return nil
                }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Which transcript each session is reading from. Held across scans: the
    /// digest tracks idle time per pid over time, and a session that changed
    /// transcripts between scans would look like a cache-expiry resume that
    /// never happened.
    public struct Bindings: Equatable, Sendable {
        fileprivate struct Entry: Equatable, Sendable {
            var startedAt: Date
            var url: URL
            /// The bound file's modification time at the last scan, so a
            /// transcript that has gone quiet can be told from a live one.
            var modified: Date
        }

        fileprivate var byPID: [Int32: Entry] = [:]

        public init() {}

        public func url(forPID pid: Int32) -> URL? { byPID[pid]?.url }
    }

    /// Pairs Claude sessions with their transcripts, keeping each pairing for
    /// as long as the session lives. A session sharing a directory with others
    /// takes a transcript created after it started; one that resumed an older
    /// conversation falls back to the most recently written unclaimed file.
    public func activities(
        for sessions: [AgentSession],
        bindings: inout Bindings
    ) -> [Int32: ClaudeSessionActivity] {
        let claudeSessions = sessions.filter { $0.provider == .claude && $0.workingDirectory != nil }
        let live = Dictionary(claudeSessions.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        // A pid that exited (or was reused) takes its binding with it.
        bindings.byPID = bindings.byPID.filter { pid, entry in
            guard let session = live[pid] else { return false }
            return abs(session.startedAt.timeIntervalSince(entry.startedAt)) < 1
        }

        for (directory, directorySessions) in Dictionary(grouping: claudeSessions, by: { $0.workingDirectory ?? "" }) {
            var claimed = Set(bindings.byPID.values.map(\.url))
            var available = transcriptFiles(in: directory).filter { !claimed.contains($0.url) }

            // Oldest session first: it had the first chance to create a file.
            for session in directorySessions.filter({ bindings.byPID[$0.pid] == nil })
                .sorted(by: { ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid) }) {
                let ownFile = available
                    .filter { $0.created >= session.startedAt.addingTimeInterval(-5) }
                    .min { $0.created < $1.created }
                let resumedFile = available
                    .filter { $0.modified >= session.startedAt }
                    .max { $0.modified < $1.modified }
                guard let file = ownFile ?? resumedFile else { continue }
                bindings.byPID[session.pid] = Bindings.Entry(
                    startedAt: session.startedAt,
                    url: file.url,
                    modified: file.modified
                )
                claimed.insert(file.url)
                available.removeAll { $0.url == file.url }
            }

            // /clear closes the current transcript and opens a new one. A bound
            // file that stopped changing, beside exactly one new unclaimed file
            // and no other session in the directory that could own it, is that.
            let candidates = available.filter { file in
                bindings.byPID.values.contains { $0.url != file.url && file.created > $0.modified }
            }
            if candidates.count == 1, let replacement = candidates.first {
                let quiet = directorySessions
                    .compactMap { session in bindings.byPID[session.pid].map { (session, $0) } }
                    .filter { replacement.created > $0.1.modified }
                if quiet.count == 1, let (session, entry) = quiet.first {
                    bindings.byPID[session.pid] = Bindings.Entry(
                        startedAt: entry.startedAt,
                        url: replacement.url,
                        modified: replacement.modified
                    )
                }
            }
        }

        var result: [Int32: ClaudeSessionActivity] = [:]
        for (pid, entry) in bindings.byPID {
            guard let activity = activity(transcript: entry.url) else { continue }
            result[pid] = activity
            bindings.byPID[pid]?.modified = activity.lastActivityAt
        }
        return result
    }

    /// Convenience for one-shot callers with no state to keep.
    public func activities(for sessions: [AgentSession]) -> [Int32: ClaudeSessionActivity] {
        var bindings = Bindings()
        return activities(for: sessions, bindings: &bindings)
    }

    private func transcriptFiles(in workingDirectory: String) -> [(url: URL, created: Date, modified: Date)] {
        let directory = homeDirectory
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(Self.projectDirectoryName(for: workingDirectory), isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate else {
                    return nil
                }
                return (url, values.creationDate ?? modified, modified)
            }
            .sorted { ($0.created, $0.url.path) < ($1.created, $1.url.path) }
    }

    public func activity(transcript url: URL) -> ClaudeSessionActivity? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Self.latestActivity(inTail: data, fallbackDate: modified ?? Date())
    }

    /// Scans JSONL lines from the end for the newest assistant turn with usage.
    /// The first line of a mid-file tail is usually truncated and fails to
    /// parse, which is harmless.
    public static func latestActivity(inTail data: Data, fallbackDate: Date) -> ClaudeSessionActivity? {
        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines.reversed() {
            guard line.count > 2,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            let context = [
                "input_tokens",
                "cache_read_input_tokens",
                "cache_creation_input_tokens"
            ].reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
            let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? fallbackDate
            return ClaudeSessionActivity(
                model: message["model"] as? String,
                contextTokens: context,
                lastActivityAt: max(timestamp, fallbackDate)
            )
        }
        return nil
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
