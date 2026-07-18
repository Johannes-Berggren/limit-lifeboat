import Foundation

/// The formatted weekly summary, presentation included (like `MenuBarSummary`,
/// the strings are built in Core so they are testable).
public struct WeeklyDigest: Equatable, Sendable {
    public var title: String
    public var body: String
    public var periodEnd: Date
}

/// Decides when a weekly usage digest is due and what it says. Pure logic:
/// persistence of the last-sent date and the actual posting live in the app
/// layer, which checks due-ness at the end of each refresh — content is then
/// at most one refresh interval old, unlike a calendar-triggered notification
/// frozen at scheduling time.
public struct WeeklyDigestPlanner: Sendable {
    /// One account's inputs: profile facts plus its window readings.
    public struct AccountInput: Sendable {
        public var profileID: UUID
        public var label: String
        public var provider: Provider
        /// Per window: id, kind, display label, and the full reading series.
        public var windows: [WindowInput]

        public init(profileID: UUID, label: String, provider: Provider, windows: [WindowInput]) {
            self.profileID = profileID
            self.label = label
            self.provider = provider
            self.windows = windows
        }
    }

    public struct WindowInput: Sendable {
        public var id: String
        public var kind: UsageWindowKind
        public var label: String
        public var readings: [BurnRateEstimator.Reading]

        public init(id: String, kind: UsageWindowKind, label: String, readings: [BurnRateEstimator.Reading]) {
            self.id = id
            self.kind = kind
            self.label = label
            self.readings = readings
        }
    }

    private let analyzer: UsageTrendAnalyzer

    public init(analyzer: UsageTrendAnalyzer = UsageTrendAnalyzer()) {
        self.analyzer = analyzer
    }

    /// Due once 7 calendar days have passed since the last send. First run
    /// arms without firing (a digest over history that predates the feature
    /// would be near-empty); missed weeks collapse into one digest covering
    /// the trailing 7 days. Calendar arithmetic, not 604800-second math, so
    /// DST transitions do not drift the send time.
    public func isDue(lastSent: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSent else {
            return false
        }
        guard let next = calendar.date(byAdding: .day, value: 7, to: lastSent) else {
            return false
        }
        return now >= next
    }

    public func period(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 24 * 3600)
        return DateInterval(start: start, end: now)
    }

    /// Builds the digest, or nil when there is nothing to say (no account had
    /// any reading in or before the period). Leads with the most-constrained
    /// account; the limit-hit count is worded as a floor ("at least") because
    /// a window can roll over between polls without a 100% reading.
    public func build(
        accounts: [AccountInput],
        events: [AppEvent],
        period: DateInterval
    ) -> WeeklyDigest? {
        struct AccountSummary {
            var label: String
            var provider: Provider
            var peak: Double
            var peakWindowLabel: String
            var limitHits: Int
        }

        var summaries: [AccountSummary] = []
        for account in accounts {
            var bestPeak: (value: Double, label: String)?
            var limitHits = 0
            for window in account.windows {
                if let peak = analyzer.peak(readings: window.readings, in: period),
                   peak > (bestPeak?.value ?? -1) {
                    bestPeak = (peak, window.label)
                }
                limitHits += analyzer.limitHits(readings: window.readings, kind: window.kind, in: period)
            }
            guard let bestPeak else {
                continue
            }
            summaries.append(
                AccountSummary(
                    label: account.label,
                    provider: account.provider,
                    peak: bestPeak.value,
                    peakWindowLabel: bestPeak.label,
                    limitHits: limitHits
                )
            )
        }

        guard !summaries.isEmpty else {
            return nil
        }
        summaries.sort { $0.peak > $1.peak }

        var lines: [String] = []
        for summary in summaries {
            var line = "\(summary.label) (\(summary.provider.displayName)): peaked at \(Int(summary.peak.rounded()))% \(summary.peakWindowLabel.lowercased())"
            if summary.limitHits > 0 {
                line += ", hit its limit at least \(summary.limitHits)×"
            }
            lines.append(line + ".")
        }

        let switches = events.filter { $0.kind == .cliSwitch }
        if !switches.isEmpty {
            let auto = switches.filter { !$0.interactive }.count
            var line = "Limit Lifeboat switched the CLI \(switches.count)×"
            if auto > 0 {
                line += " (\(auto) automatic)"
            }
            lines.append(line + ".")
        }

        return WeeklyDigest(
            title: "Your week across \(summaries.count) account\(summaries.count == 1 ? "" : "s")",
            body: lines.joined(separator: " "),
            periodEnd: period.end
        )
    }
}
