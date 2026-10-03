import Foundation

/// The parts of Claude Code's status-line JSON (piped on stdin) the status
/// line can use. Every field is optional: older Claude Code builds send
/// neither block, `rate_limits` only appears for Pro/Max logins after the
/// first response, and a window drops out once its reset passes.
public struct ClaudeStatusLineInput: Equatable, Sendable {
    public struct PromptCache: Equatable, Sendable {
        public var warm: Bool
        public var ttl: String?
        public var expiresAt: Date?
        public var recacheTokensIfCold: Int?
    }

    public var promptCache: PromptCache?
    /// Highest `used_percentage` across `five_hour` and `seven_day`.
    public var rateLimitPercent: Int?

    public init(promptCache: PromptCache? = nil, rateLimitPercent: Int? = nil) {
        self.promptCache = promptCache
        self.rateLimitPercent = rateLimitPercent
    }

    public static func parse(_ data: Data) -> ClaudeStatusLineInput? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var input = ClaudeStatusLineInput()
        if let cache = object["prompt_cache"] as? [String: Any], let warm = cache["warm"] as? Bool {
            input.promptCache = PromptCache(
                warm: warm,
                ttl: cache["ttl"] as? String,
                expiresAt: date(cache["expires_at"]),
                recacheTokensIfCold: (cache["recache_tokens_if_cold"] as? NSNumber)?.intValue
            )
        }
        if let limits = object["rate_limits"] as? [String: Any] {
            input.rateLimitPercent = ["five_hour", "seven_day"]
                .compactMap { (limits[$0] as? [String: Any])?["used_percentage"] as? NSNumber }
                .map { Int($0.doubleValue.rounded()) }
                .max()
        }
        return input.promptCache == nil && input.rateLimitPercent == nil ? nil : input
    }

    /// Epoch seconds, epoch milliseconds, or ISO 8601.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1_000 : raw)
        }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        return nil
    }
}
