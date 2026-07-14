import Foundation

/// Where a window's quota is heading if usage keeps its recent pace.
public enum BurnRateEstimate: Equatable, Sendable {
    /// Too little same-window history to say anything trustworthy.
    case insufficientData
    /// Usage is flat, falling, or will not hit 100% before the window resets.
    case safe
    /// At the recent pace the window hits 100% at this time, before it resets.
    case depletesAt(Date)
}

/// Extrapolates recent usage readings for one window to "when does this hit
/// 100%". Pure logic: the readings, the window, and the clock are all passed
/// in, so estimates are fully deterministic under test.
public struct BurnRateEstimator: Sendable {
    /// One historical observation of the window being estimated.
    public struct Reading: Equatable, Sendable {
        public var timestamp: Date
        public var usedPercent: Double
        public var resetDate: Date?

        public init(timestamp: Date, usedPercent: Double, resetDate: Date? = nil) {
            self.timestamp = timestamp
            self.usedPercent = usedPercent
            self.resetDate = resetDate
        }

        public init(timestamp: Date, reading: UsageWindowReading) {
            self.init(timestamp: timestamp, usedPercent: reading.usedPercent, resetDate: reading.resetDate)
        }
    }

    public struct Configuration: Equatable, Sendable {
        /// How far back to look for session-shaped windows.
        public var sessionLookback: TimeInterval
        /// How far back to look for weekly-shaped windows.
        public var weeklyLookback: TimeInterval
        /// Minimum first-to-last spread before a session slope is trusted.
        public var sessionMinimumSpan: TimeInterval
        /// Minimum first-to-last spread before a weekly slope is trusted.
        public var weeklyMinimumSpan: TimeInterval
        /// Minimum number of surviving points before any slope is trusted.
        public var minimumPoints: Int
        /// How far apart two reset dates may sit and still count as the same
        /// window life. TUI-sourced readings re-anchor their reset date to
        /// "now" on every poll, jittering it by up to minutes, so this must
        /// be generous; the backward-usage-increase truncation in
        /// `estimate` is the real reset detector.
        public var resetDateTolerance: TimeInterval

        public static let standard = Configuration()

        public init(
            sessionLookback: TimeInterval = 90 * 60,
            weeklyLookback: TimeInterval = 48 * 3600,
            sessionMinimumSpan: TimeInterval = 10 * 60,
            weeklyMinimumSpan: TimeInterval = 3 * 3600,
            minimumPoints: Int = 2,
            resetDateTolerance: TimeInterval = 300
        ) {
            self.sessionLookback = sessionLookback
            self.weeklyLookback = weeklyLookback
            self.sessionMinimumSpan = sessionMinimumSpan
            self.weeklyMinimumSpan = weeklyMinimumSpan
            self.minimumPoints = minimumPoints
            self.resetDateTolerance = resetDateTolerance
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public func estimate(readings: [Reading], window: UsageWindow, now: Date = Date()) -> BurnRateEstimate {
        let cutoff = now.addingTimeInterval(-lookback(for: window))
        let sameWindow = readings
            .filter { $0.timestamp >= cutoff }
            .filter { matchesWindow($0, window: window, now: now) }
            .sorted { $0.timestamp < $1.timestamp }

        // Walk newest -> oldest and truncate at the first increase going
        // backward: an older reading with HIGHER usedPercent than a newer one
        // means the window reset mid-series, and points from the previous
        // life of the window would poison the slope.
        var backward: [Reading] = []
        for reading in sameWindow.reversed() {
            if let newer = backward.last, reading.usedPercent > newer.usedPercent {
                break
            }
            backward.append(reading)
        }
        let points = Array(backward.reversed())

        guard points.count >= configuration.minimumPoints,
              let first = points.first,
              let last = points.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan(for: window.kind) else {
            return .insufficientData
        }

        guard let slope = leastSquaresSlope(points) else {
            return .insufficientData
        }
        guard slope > 1e-9 else {
            return .safe
        }

        let depletion = last.timestamp.addingTimeInterval((100 - last.usedPercent) / slope)
        if let resetDate = window.resetDate, depletion >= resetDate {
            return .safe
        }
        return .depletesAt(max(now, depletion))
    }

    /// How much history is relevant. Sessions move fast, so only the last
    /// stretch matters; weekly windows need day-scale context. Unknown kinds
    /// scale with their reported length when they have one.
    private func lookback(for window: UsageWindow) -> TimeInterval {
        switch window.kind {
        case .session:
            return configuration.sessionLookback
        case .weekly, .weeklyScoped:
            return configuration.weeklyLookback
        case .other:
            guard let windowMinutes = window.windowMinutes else {
                return configuration.sessionLookback
            }
            return min(Double(windowMinutes) * 60 * 0.3, configuration.weeklyLookback)
        }
    }

    private func minimumSpan(for kind: UsageWindowKind) -> TimeInterval {
        switch kind {
        case .weekly, .weeklyScoped:
            return configuration.weeklyMinimumSpan
        case .session, .other:
            return configuration.sessionMinimumSpan
        }
    }

    /// A reading belongs to the window's current life when its reset date
    /// matches the window's within `resetDateTolerance` (TUI-sourced reset
    /// dates are re-anchored to "now" each poll, so minute-scale jitter is
    /// normal), or when it carries no reset date and is recent enough that
    /// the window cannot have rolled over since.
    private func matchesWindow(_ reading: Reading, window: UsageWindow, now: Date) -> Bool {
        if let readingReset = reading.resetDate {
            guard let windowReset = window.resetDate else {
                return false
            }
            return abs(readingReset.timeIntervalSince(windowReset)) < configuration.resetDateTolerance
        }
        guard let windowMinutes = window.windowMinutes else {
            return true
        }
        return now.timeIntervalSince(reading.timestamp) < Double(windowMinutes) * 60
    }

    /// Least-squares slope of usedPercent over seconds, nil when the points
    /// carry no time spread at all (guarded earlier by the span check).
    private func leastSquaresSlope(_ points: [Reading]) -> Double? {
        guard let base = points.first?.timestamp else {
            return nil
        }
        let xs = points.map { $0.timestamp.timeIntervalSince(base) }
        let ys = points.map(\.usedPercent)
        let n = Double(points.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else {
            return nil
        }
        return (n * sumXY - sumX * sumY) / denominator
    }
}
