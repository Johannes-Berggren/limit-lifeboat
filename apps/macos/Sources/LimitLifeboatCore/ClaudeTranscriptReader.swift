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
