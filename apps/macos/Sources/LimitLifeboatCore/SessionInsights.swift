import Foundation

/// A periodic snapshot of what the agent sessions were doing, sampled far
/// less often than the census itself so a week of history stays small.
public struct SessionSample: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var provider: Provider
        public var project: String
        public var model: String?
        public var contextTokens: Int
        /// Seconds since this session's last transcript activity; nil when
        /// there is no transcript to read (Codex today).
        public var idleSeconds: Int?

        public init(pid: Int32, provider: Provider, project: String, model: String?, contextTokens: Int, idleSeconds: Int?) {
            self.pid = pid
            self.provider = provider
            self.project = project
            self.model = model
            self.contextTokens = contextTokens
            self.idleSeconds = idleSeconds
        }

        public var isActive: Bool {
            (idleSeconds ?? Int.max) < 300
        }
    }

    public var timestamp: Date
    public var entries: [Entry]

    public init(timestamp: Date, entries: [Entry]) {
        self.timestamp = timestamp
        self.entries = entries
    }
}

/// What a week of samples says about where the quota went.
public struct SessionInsightSummary: Equatable, Sendable {
    /// Every session counts here, readable or not.
    public var peakParallelSessions: Int
    /// Project name → minutes of sampled active work, largest first. Only
    /// sessions with a readable transcript (Claude today) can be counted as
    /// working, so Codex time is missing from this and from `modelShares`.
    public var topProjects: [(project: String, minutes: Int)]
    /// Model name → share of the samples that named a model, largest first.
    public var modelShares: [(model: String, share: Double)]
    public var coldResumeCount: Int
    /// Context re-read uncached by those resumes, summed.
    public var coldResumeTokens: Int

    public static func == (lhs: SessionInsightSummary, rhs: SessionInsightSummary) -> Bool {
        lhs.peakParallelSessions == rhs.peakParallelSessions
            && lhs.coldResumeCount == rhs.coldResumeCount
            && lhs.coldResumeTokens == rhs.coldResumeTokens
            && lhs.topProjects.map(\.project) == rhs.topProjects.map(\.project)
            && lhs.topProjects.map(\.minutes) == rhs.topProjects.map(\.minutes)
            && lhs.modelShares.map(\.model) == rhs.modelShares.map(\.model)
    }
}

public struct SessionInsightAggregator: Sendable {
    /// How long one sample stands for. Samples are taken on this cadence, so
    /// each active entry counts as this much work.
    public let sampleMinutes: Int
    /// Idle time after which the main conversation's 1h prompt cache has
    /// expired, so the next message re-reads the whole context uncached.
    public let coldCacheSeconds: Int

    public init(sampleMinutes: Int = 5, coldCacheSeconds: Int = 3_600) {
        self.sampleMinutes = sampleMinutes
        self.coldCacheSeconds = coldCacheSeconds
    }

    public func summary(samples: [SessionSample], in period: DateInterval) -> SessionInsightSummary? {
        let samples = samples
            .filter { period.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !samples.isEmpty else { return nil }

        var peak = 0
        var projectMinutes: [String: Int] = [:]
        var modelSamples: [String: Int] = [:]
        // Only entries that named a model can be a share *of* anything —
        // counting model-less ones in the denominator understates every share.
        var modeledSamples = 0
        for sample in samples {
            peak = max(peak, sample.entries.count)
            for entry in sample.entries where entry.isActive {
                projectMinutes[entry.project, default: 0] += sampleMinutes
                if let model = entry.model {
                    modeledSamples += 1
                    modelSamples[model, default: 0] += 1
                }
            }
        }

        var coldResumes = 0
        var coldTokens = 0
        var previousIdle: [Int32: Int] = [:]
        for sample in samples {
            var currentIdle: [Int32: Int] = [:]
            for entry in sample.entries {
                guard let idle = entry.idleSeconds else { continue }
                currentIdle[entry.pid] = idle
                // Idle time collapsing back to nothing means the session woke
                // up; if it had been idle past the cache TTL, that turn paid
                // for the whole context again.
                if let previous = previousIdle[entry.pid], previous >= coldCacheSeconds, idle < previous {
                    coldResumes += 1
                    coldTokens += entry.contextTokens
                }
            }
            previousIdle = currentIdle
        }

        return SessionInsightSummary(
            peakParallelSessions: peak,
            topProjects: projectMinutes
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(3)
                .map { (project: $0.key, minutes: $0.value) },
            modelShares: modeledSamples == 0 ? [] : modelSamples
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(3)
                .map { (model: $0.key, share: Double($0.value) / Double(modeledSamples)) },
            coldResumeCount: coldResumes,
            coldResumeTokens: coldTokens
        )
    }

    /// The digest sentences, or an empty array when there is nothing to say.
    public func digestLines(for summary: SessionInsightSummary) -> [String] {
        var lines: [String] = []
        if summary.peakParallelSessions > 0 {
            var line = "Agent sessions: \(summary.peakParallelSessions) running at once at the busiest point"
            if let top = summary.topProjects.first, top.minutes > 0 {
                let projects = summary.topProjects
                    .map { "\($0.project) (\(MemoryFormatting.duration(TimeInterval($0.minutes * 60))))" }
                    .joined(separator: ", ")
                // Named as Claude time because Codex sessions have no
                // transcript to measure working time from yet.
                line += "; most Claude work in \(projects)"
            }
            lines.append(line + ".")
        }
        if let top = summary.modelShares.first, top.share >= 0.1 {
            lines.append("\(ModelNaming.short(top.model)) did \(Int((top.share * 100).rounded()))% of the work.")
        }
        if summary.coldResumeCount > 0, summary.coldResumeTokens > 0 {
            lines.append(
                "\(summary.coldResumeCount) session\(summary.coldResumeCount == 1 ? "" : "s") resumed after the prompt cache expired, re-reading about \(MemoryFormatting.tokens(summary.coldResumeTokens)) tokens uncached — /clear or a fresh session is cheaper than resuming a big one."
            )
        }
        return lines
    }
}

public enum ModelNaming {
    /// "claude-opus-5" → "Opus 5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    public static func short(_ model: String) -> String {
        var components = model.split(separator: "-").map(String.init)
        if components.first == "claude" {
            components.removeFirst()
        }
        components.removeAll { $0.count >= 8 && $0.allSatisfy(\.isNumber) }
        guard let family = components.first else { return model }
        let version = components.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

/// Warns once when a session has been idle long enough that its next message
/// will re-read the whole context uncached.
public struct ColdCacheAlertPolicy: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let pid: Int32
        public let project: String
        public let contextTokens: Int

        public init(pid: Int32, project: String, contextTokens: Int) {
            self.pid = pid
            self.project = project
            self.contextTokens = contextTokens
        }
    }

    /// Warn shortly before the 1h TTL, while finishing or clearing still helps.
    public let idleSeconds: Int
    public let minimumContextTokens: Int

    public init(idleSeconds: Int = 55 * 60, minimumContextTokens: Int = 100_000) {
        self.idleSeconds = idleSeconds
        self.minimumContextTokens = minimumContextTokens
    }

    /// - Parameter alreadyWarned: pids warned about in the current idle spell;
    ///   the caller drops a pid once it is active again or gone.
    public func candidates(
        entries: [SessionSample.Entry],
        alreadyWarned: Set<Int32>
    ) -> [Candidate] {
        entries
            .filter { entry in
                guard let idle = entry.idleSeconds else { return false }
                return idle >= idleSeconds
                    && entry.contextTokens >= minimumContextTokens
                    && !alreadyWarned.contains(entry.pid)
            }
            .sorted { $0.contextTokens > $1.contextTokens }
            .map { Candidate(pid: $0.pid, project: $0.project, contextTokens: $0.contextTokens) }
    }

    public func notificationBody(for candidates: [Candidate]) -> String {
        let tokens = candidates.reduce(0) { $0 + $1.contextTokens }
        let names = candidates.prefix(3).map(\.project).joined(separator: ", ")
        let subject = candidates.count == 1
            ? "\(names) has been idle for about an hour"
            : "\(candidates.count) sessions have been idle for about an hour (\(names))"
        return "\(subject). Their prompt cache expires at one hour, so the next message re-reads about \(MemoryFormatting.tokens(tokens)) tokens at full price. Finishing now, or starting fresh later, avoids that."
    }
}

/// Append-only sample log, a sibling of `AppEventStore`: one JSON object per
/// line, malformed lines skipped, trimmed to a retention window.
public final class SessionInsightStore {
    private let fileManager: FileManager
    private let url: URL
    private let retention: TimeInterval

    private var cache: [SessionSample] = []
    private var hasLoaded = false

    public init(
        applicationSupportDirectory: URL,
        fileManager: FileManager = .default,
        retention: TimeInterval = 14 * 24 * 3600
    ) {
        self.fileManager = fileManager
        self.url = applicationSupportDirectory.appendingPathComponent("session-samples.jsonl")
        self.retention = retention
    }

    public func load() throws {
        cache = []
        hasLoaded = false
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder.appDecoder
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let sample = try? decoder.decode(SessionSample.self, from: Data(line)) {
                    cache.append(sample)
                }
            }
            cache.sort { $0.timestamp < $1.timestamp }
        }
        hasLoaded = true
    }

    public func append(_ sample: SessionSample) throws {
        try loadIfNeeded()
        try ensureDirectory()
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let line = try Self.encodeLine(sample)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        cache.append(sample)

        if let oldest = cache.first, sample.timestamp.timeIntervalSince(oldest.timestamp) > retention {
            try prune(now: sample.timestamp)
        }
    }

    public func samples(in interval: DateInterval) -> [SessionSample] {
        // Lazily load like every other reader: a load that threw at start
        // would otherwise leave this permanently empty.
        try? loadIfNeeded()
        return cache.filter { interval.contains($0.timestamp) }
    }

    public func prune(now: Date = Date()) throws {
        try loadIfNeeded()
        let cutoff = now.addingTimeInterval(-retention)
        let kept = cache.filter { $0.timestamp >= cutoff }
        guard kept.count != cache.count else { return }
        cache = kept
        var data = Data()
        for sample in kept {
            data.append(try Self.encodeLine(sample))
        }
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        try load()
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// `JSONEncoder.appEncoder` pretty-prints; JSONL needs one line per record.
    private static func encodeLine(_ sample: SessionSample) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(sample)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
