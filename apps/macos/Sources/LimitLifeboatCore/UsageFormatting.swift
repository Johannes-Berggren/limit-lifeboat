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

/// Shared whole-number percent rendering. Quota percentages are 0-100 and
/// every surface — gauges, menu-bar title, notifications, digests — rounds
/// them the same way, so two surfaces can never disagree by a point.
public enum UsagePercent {
    /// A 0-100 percentage rounded to a whole number.
    public static func rounded(_ percent: Double) -> Int {
        Int(percent.rounded())
    }

    /// A 0-100 percentage as "83%".
    public static func text(_ percent: Double) -> String {
        "\(rounded(percent))%"
    }
}

/// A short absolute local timestamp ("Jul 8, 2026 at 1:49 AM"). Every surface
/// that prints an instant goes through this, so reset and depletion times read
/// identically everywhere.
///
/// Deliberately DateFormatter rather than `Date.formatted(date:time:)`: only
/// DateFormatter honours a regional format override, so a user whose language
/// is en_US but whose region is Norway sees "5 Jul 2026 at 02:49" — matching
/// the rest of macOS — where `formatted` would force "Jul 5, 2026 at 2:49".
///
/// The formatter is cached because the menu re-renders often, and rebuilt when
/// the current locale changes so the cache cannot pin a stale region.
public enum AbsoluteTimestamp {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (locale: Locale, formatter: DateFormatter)?

    public static func text(_ date: Date) -> String {
        lock.withLock {
            let locale = Locale.current
            if let cached, cached.locale == locale {
                return cached.formatter.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            cached = (locale, formatter)
            return formatter.string(from: date)
        }
    }
}

/// Money the usage API reports in MINOR units, rendered in its own currency.
///
/// The `extra_usage` block scales its amounts and says so in the same object:
/// `used_credits: 14157` alongside `currency: "BRL"` and `decimal_places: 2`
/// means R$ 141.57. Releases through 1.1.5 read those amounts as major units
/// and prepended "$", so an account paying 141.57 of overage was told "$14157"
/// — wrong by 100x, and the wrong currency for anyone not billed in USD.
///
/// `decimalPlaces` falls back to 2 when a response omits it, because every
/// known response scales by 100. A response that starts reporting major units
/// would have to send `decimal_places: 0`.
///
/// The formatter is cached like `AbsoluteTimestamp`'s, keyed on locale and
/// currency, because the menu re-renders often. Fraction digits are set per
/// call under the same lock so alternating whole and fractional amounts in one
/// line cannot thrash the cache.
public enum CreditAmount {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: (locale: Locale, currencyCode: String, formatter: NumberFormatter)?

    /// Minor units scaled to major units: 14157 at 2 places is 141.57.
    public static func majorUnits(_ minorUnits: Double, decimalPlaces: Int?) -> Double {
        minorUnits / pow(10, Double(max(0, decimalPlaces ?? 2)))
    }

    /// "$141.57", "R$ 141.57", "50 kr". The fraction is dropped for whole
    /// amounts so a 5000-minor-unit cap reads "$50" rather than "$50.00".
    public static func text(
        minorUnits: Double,
        currency: String?,
        decimalPlaces: Int?,
        locale: Locale = .current
    ) -> String {
        let value = majorUnits(minorUnits, decimalPlaces: decimalPlaces)
        let rounded = (value * 100).rounded() / 100
        let trimmed = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let code = (trimmed?.isEmpty == false) ? trimmed! : "USD"

        return lock.withLock {
            let formatter: NumberFormatter
            if let cached, cached.locale == locale, cached.currencyCode == code {
                formatter = cached.formatter
            } else {
                formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.locale = locale
                formatter.currencyCode = code
                cached = (locale, code, formatter)
            }
            let digits = rounded == rounded.rounded() ? 0 : 2
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            return formatter.string(from: rounded as NSNumber) ?? "\(rounded)"
        }
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

/// User-facing reset timing shared by quota gauges. A parsed date wins over
/// provider text so relative copy stays current instead of freezing at the
/// wording captured with the snapshot.
public enum UsageResetTiming {
    public static func compactText(
        resetDate: Date?,
        resetDescription: String?,
        now: Date = Date()
    ) -> String? {
        if let resetDate {
            guard resetDate > now else {
                return "Reset passed"
            }
            return "Resets in \(DurationPhrase.short(resetDate.timeIntervalSince(now)))"
        }

        guard let resetDescription else {
            return nil
        }
        let description = resetDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            return nil
        }
        if description.lowercased().hasPrefix("reset") {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        return "Resets \(description)"
    }
}
