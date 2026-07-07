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

    public func readUsage(for profile: AccountProfile, now: Date = Date()) -> UsageSnapshot? {
        guard profile.provider == .codex,
              let event = latestRateLimitEvent(),
              let selectedLimit = event.limits.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return nil
        }

        let usedPercent = min(100, max(0, selectedLimit.usedPercent))
        let remainingPercent = max(0, 100 - usedPercent)
        let resetDate = selectedLimit.resetsAt

        return UsageSnapshot(
            accountID: profile.id,
            provider: .codex,
            includedRemaining: remainingPercent,
            includedLimit: 100,
            resetDate: resetDate,
            resetDescription: resetDescription(for: resetDate, now: now),
            creditStatus: creditStatus(from: event),
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: "local Codex CLI logs",
            lastRefreshed: now,
            parseConfidence: .high,
            message: message(for: selectedLimit, event: event)
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
        guard let value else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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

        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "in \(max(1, minutes))m"
        }

        let hours = Int((Double(minutes) / 60).rounded(.up))
        if hours < 48 {
            return "in \(hours)h"
        }

        let days = Int((Double(hours) / 24).rounded(.up))
        return "in \(days)d"
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
