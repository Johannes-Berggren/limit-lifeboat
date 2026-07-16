import Foundation

public struct CodexLocalUsageReader {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let maxFiles: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        maxFiles: Int = 80
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.maxFiles = maxFiles
    }

    /// Reads the latest local rate-limit event for the active Codex account.
    ///
    /// `producedAfter` is a freshness gate: the session logs carry no account
    /// identity, so the newest event belongs to whoever last ran `codex`.
    /// Passing the time the current account became active discards any event
    /// older than that, so a just-switched-to account is never shown the
    /// previous account's numbers. `nil` (the default, e.g. first launch where
    /// the active account has been active since before the app started) accepts
    /// the newest event.
    public func readUsage(for profile: AccountProfile, producedAfter: Date? = nil, now: Date = Date()) -> UsageSnapshot? {
        guard profile.provider == .codex,
              let event = latestRateLimitEvent(),
              producedAfter.map({ event.timestamp > $0 }) ?? true else {
            return nil
        }

        let windows = event.limits.map { makeWindow(from: $0, now: now) }
        guard let selectedLimit = event.limits.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return nil
        }
        return UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .codex,
            windows: windows,
            creditStatus: creditStatus(from: event),
            source: "local Codex CLI logs",
            lastRefreshed: now,
            message: message(for: selectedLimit, event: event)
        )
    }

    private func makeWindow(from limit: CodexRateLimit, now: Date) -> UsageWindow {
        return UsageSnapshotFactory.window(
            descriptor: CodexUsageWindowCatalog.descriptor(
                name: limit.name,
                windowMinutes: limit.windowMinutes
            ),
            usedPercent: limit.usedPercent,
            resetDate: limit.resetsAt,
            resetDescription: resetDescription(for: limit.resetsAt, now: now)
        )
    }

    private func latestRateLimitEvent() -> RateLimitEvent? {
        var latest: RateLimitEvent?

        for fileURL in sessionFiles().prefix(maxFiles) {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            for line in data.split(separator: 10).reversed() {
                let text = String(decoding: line, as: UTF8.self)
                guard text.contains(#""rate_limits""#),
                      let event = parseRateLimitEvent(from: text) else {
                    continue
                }

                if latest == nil || event.timestamp > latest!.timestamp {
                    latest = event
                }
                break
            }
        }

        return latest
    }

    private func sessionFiles() -> [URL] {
        let sessionsURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let files = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }
            return url
        }

        return files.sorted { left, right in
            modificationDate(left) > modificationDate(right)
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func parseRateLimitEvent(from line: String) -> RateLimitEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        var limits: [CodexRateLimit] = []
        for name in ["primary", "secondary"] {
            guard let value = rateLimits[name] as? [String: Any],
                  let usedPercent = number(value["used_percent"]) else {
                continue
            }

            limits.append(
                CodexRateLimit(
                    name: name,
                    usedPercent: usedPercent,
                    windowMinutes: number(value["window_minutes"]).map(Int.init),
                    resetsAt: number(value["resets_at"]).map(Date.init(timeIntervalSince1970:))
                )
            )
        }

        guard !limits.isEmpty else {
            return nil
        }

        return RateLimitEvent(
            timestamp: parseTimestamp(object["timestamp"] as? String) ?? .distantPast,
            limits: limits,
            planType: rateLimits["plan_type"] as? String,
            creditsAvailable: rateLimits["credits"] != nil && !(rateLimits["credits"] is NSNull),
            reachedType: rateLimits["rate_limit_reached_type"] as? String
        )
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        value.flatMap(FlexibleISO8601.date(from:))
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private func resetDescription(for date: Date?, now: Date) -> String? {
        guard let date else {
            return nil
        }
        return "in \(DurationPhrase.short(date.timeIntervalSince(now)))"
    }

    private func creditStatus(from event: RateLimitEvent) -> String? {
        if let reachedType = event.reachedType, !reachedType.isEmpty {
            return "Rate limit reached: \(reachedType)."
        }
        return event.creditsAvailable ? "Credits are available." : nil
    }

    private func message(for limit: CodexRateLimit, event: RateLimitEvent) -> String {
        var parts = ["Codex CLI reports \(Int(limit.usedPercent.rounded()))% used"]
        if let windowMinutes = limit.windowMinutes {
            parts.append("on \(windowLabel(minutes: windowMinutes))")
        }
        if let planType = event.planType, !planType.isEmpty {
            parts.append("plan: \(planType)")
        }
        return parts.joined(separator: " - ")
    }

    private func windowLabel(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m window"
        }
        if minutes < 60 * 24 {
            return "\(minutes / 60)h window"
        }
        return "\(minutes / (60 * 24))d window"
    }
}

private struct RateLimitEvent {
    var timestamp: Date
    var limits: [CodexRateLimit]
    var planType: String?
    var creditsAvailable: Bool
    var reachedType: String?
}

private struct CodexRateLimit {
    var name: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}
