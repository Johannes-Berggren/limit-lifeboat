import Foundation

/// Shared window-id slugging. Window ids are a contract between the local
/// Claude Code TUI parser and the Anthropic usage API client: per-window alert
/// dedupe keys must survive flipping between the two sources, so both must
/// slug scope names identically.
public enum UsageWindowID {
    /// Lowercase alphanumerics joined by dashes; "window" when nothing
    /// survives.
    public static func slug(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "window" : collapsed
    }
}

/// ISO8601 parsing that tolerates both timestamp shapes providers emit:
/// with fractional seconds ("2026-07-08T00:49:59.940321+00:00") and without
/// ("2026-07-13T06:00:00Z").
public enum FlexibleISO8601 {
    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Shared "how long until" phrasing so every surface rounds the same way.
public enum DurationPhrase {
    /// A compact single-unit duration ("3m", "5h", "2d") rounded up so a
    /// reset is never promised earlier than it happens: minutes under an
    /// hour, hours under two days, whole days beyond. Never less than "1m",
    /// and negative intervals clamp to it. Call sites add their own prefix
    /// ("in 3h", "resets in 3h").
    public static func short(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "\(max(1, minutes))m"
        }

        let hours = Int((Double(minutes) / 60).rounded(.up))
        if hours < 48 {
            return "\(hours)h"
        }

        let days = Int((Double(hours) / 24).rounded(.up))
        return "\(days)d"
    }
}
