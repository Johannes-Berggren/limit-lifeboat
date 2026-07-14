import Foundation

/// Converts Claude Code's textual reset descriptions ("8pm", "Jul 10 at 6am",
/// "Friday", "in 2h 15m", optionally suffixed with a zone like
/// "(Europe/Oslo)") into an absolute date so
/// `UsageSnapshot.resetHasElapsed()` works for Claude accounts.
///
/// Descriptions without an explicit time resolve to the end of the named day —
/// late rather than early, so "quota is likely back" never fires before the
/// reset actually happened. Unrecognized text resolves to nil.
public struct ClaudeResetDateParser: Sendable {
    public init() {}

    public func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (zone, remainder) = extractTimeZone(from: working) {
            calendar.timeZone = zone
            working = remainder
        }
        working = working
            .lowercased()
            .replacingOccurrences(of: " at ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if working.hasPrefix("at ") {
            working.removeFirst(3)
        }
        guard !working.isEmpty else {
            return nil
        }

        if let relative = parseRelative(working, now: now) {
            return sanityChecked(relative, now: now)
        }

        let time = parseTime(in: working)

        if working.contains("tomorrow") {
            guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return sanityChecked(resolved(time, dayStart: tomorrowStart, calendar: calendar), now: now)
        }

        if let monthDay = parseMonthDay(in: working) {
            return sanityChecked(
                resolveMonthDay(month: monthDay.month, day: monthDay.day, time: time, now: now, calendar: calendar),
                now: now
            )
        }

        if let weekday = parseWeekday(in: working) {
            return sanityChecked(resolveWeekday(weekday, time: time, now: now, calendar: calendar), now: now)
        }

        if let time {
            return sanityChecked(nextOccurrence(of: time, after: now, calendar: calendar), now: now)
        }

        return nil
    }

    // MARK: - Components

    private struct TimeOfDay {
        var hour: Int
        var minute: Int
    }

    private func extractTimeZone(from text: String) -> (TimeZone, String)? {
        guard let open = text.range(of: "(", options: .backwards),
              let close = text.range(of: ")", options: .backwards),
              open.upperBound <= close.lowerBound else {
            return nil
        }
        let identifier = String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard let zone = TimeZone(identifier: identifier) else {
            return nil
        }
        var remainder = text
        remainder.removeSubrange(open.lowerBound..<close.upperBound)
        return (zone, remainder)
    }

    private func parseRelative(_ text: String, now: Date) -> Date? {
        guard text.range(of: #"\bin\b"#, options: .regularExpression) != nil else {
            return nil
        }
        let days = firstNumber(#"(\d+)\s*(?:d|day|days)\b"#, in: text) ?? 0
        let hours = firstNumber(#"(\d+)\s*(?:h|hr|hrs|hour|hours)\b"#, in: text) ?? 0
        let minutes = firstNumber(#"(\d+)\s*(?:m|min|mins|minute|minutes)\b"#, in: text) ?? 0
        let total = days * 86_400 + hours * 3_600 + minutes * 60
        guard total > 0 else {
            return nil
        }
        return now.addingTimeInterval(TimeInterval(total))
    }

    private func parseTime(in text: String) -> TimeOfDay? {
        guard let groups = firstMatchGroups(#"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, in: text),
              var hour = groups[1].flatMap(Int.init),
              (1...12).contains(hour) else {
            return nil
        }
        let minute = groups[2].flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else {
            return nil
        }
        if hour == 12 {
            hour = 0
        }
        if groups[3] == "pm" {
            hour += 12
        }
        return TimeOfDay(hour: hour, minute: minute)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private func parseMonthDay(in text: String) -> (month: Int, day: Int)? {
        let pattern = #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b"#
        guard let groups = firstMatchGroups(pattern, in: text),
              let monthName = groups[1],
              let month = Self.months.firstIndex(of: monthName).map({ $0 + 1 }),
              let day = groups[2].flatMap(Int.init),
              (1...31).contains(day) else {
            return nil
        }
        return (month, day)
    }

    private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private func parseWeekday(in text: String) -> Int? {
        // Only accept real weekday words; a bare stem pattern like "mon[a-z]*"
        // would also swallow words such as "monthly".
        let pattern = #"\b(sun|mon|tue|wed|thu|fri|sat)(?:day|sday|nesday|rsday|urday|s|r|rs)?\b"#
        guard let groups = firstMatchGroups(pattern, in: text),
              let name = groups[1],
              let index = Self.weekdays.firstIndex(of: name) else {
            return nil
        }
        // Gregorian calendars number weekdays with Sunday == 1.
        return index + 1
    }

    // MARK: - Resolution

    /// No explicit time means "some time that day" — resolve to the end of the
    /// day so the reset is never reported as elapsed before it happened.
    private func resolved(_ time: TimeOfDay?, dayStart: Date, calendar: Calendar) -> Date? {
        guard let time else {
            return calendar.date(byAdding: .day, value: 1, to: dayStart)
        }
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: dayStart)
    }

    private func resolveMonthDay(month: Int, day: Int, time: TimeOfDay?, now: Date, calendar: Calendar) -> Date? {
        var year = calendar.component(.year, from: now)
        for _ in 0..<2 {
            guard let dayStart = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  let candidate = resolved(time, dayStart: dayStart, calendar: calendar) else {
                return nil
            }
            // A reset that "just happened" stays as-is; a date months in the
            // past means the CLI was talking about next year.
            if candidate >= now.addingTimeInterval(-2 * 86_400) {
                return candidate
            }
            year += 1
        }
        return nil
    }

    private func resolveWeekday(_ weekday: Int, time: TimeOfDay?, now: Date, calendar: Calendar) -> Date? {
        let todayStart = calendar.startOfDay(for: now)
        for offset in 0..<8 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart),
                  calendar.component(.weekday, from: dayStart) == weekday else {
                continue
            }
            guard let candidate = resolved(time, dayStart: dayStart, calendar: calendar) else {
                return nil
            }
            if candidate > now {
                return candidate
            }
            // Today matches but the time already passed — the CLI means next week.
        }
        return nil
    }

    private func nextOccurrence(of time: TimeOfDay, after now: Date, calendar: Calendar) -> Date? {
        let todayStart = calendar.startOfDay(for: now)
        guard let candidate = resolved(time, dayStart: todayStart, calendar: calendar) else {
            return nil
        }
        if candidate > now {
            return candidate
        }
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return nil
        }
        return resolved(time, dayStart: tomorrowStart, calendar: calendar)
    }

    private func sanityChecked(_ date: Date?, now: Date) -> Date? {
        guard let date, date < now.addingTimeInterval(400 * 86_400) else {
            return nil
        }
        return date
    }

    // MARK: - Regex helpers

    private func firstMatchGroups(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let groupRange = match.range(at: index)
            guard groupRange.location != NSNotFound,
                  let stringRange = Range(groupRange, in: text) else {
                return nil
            }
            return String(text[stringRange])
        }
    }

    private func firstNumber(_ pattern: String, in text: String) -> Int? {
        guard let groups = firstMatchGroups(pattern, in: text) else {
            return nil
        }
        return groups[1].flatMap(Int.init)
    }
}
