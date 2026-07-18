import Foundation

public enum TrendConfidence: Equatable, Sendable {
    case normal
    /// Elapsed positions had to be inferred from observation times instead of
    /// reset anchors — directionally right, numerically rough.
    case low
}

/// "You are at X% used where last week you were at Y% at this same point in
/// the window."
public struct UsageTrend: Equatable, Sendable {
    public var windowID: String
    public var currentUsedPercent: Double
    public var previousUsedPercentAtSamePoint: Double
    /// current − previous, in percentage points.
    public var deltaPercentagePoints: Double
    /// delta relative to the previous value; nil when the previous value is
    /// too close to zero to divide meaningfully.
    public var relativeChange: Double?
    public var confidence: TrendConfidence
}

/// Trend math over one window's usage history. All of it is built on
/// window-life segmentation because utilization resets to zero each period:
/// naive deltas across a reset boundary are wrong. Following the doctrine
/// established by `BurnRateEstimator`, a usage DROP is the primary boundary
/// signal; reset-date movement is secondary with a generous, kind-aware
/// tolerance (TUI-sourced reset dates re-anchor with minutes of jitter).
///
/// Pure and deterministic: readings and the clock are passed in.
public struct UsageTrendAnalyzer: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Ignore usage drops smaller than this (float jitter between
        /// sources), in percentage points.
        public var dropEpsilon: Double
        /// A forward reset-date jump beyond this splits lives for
        /// weekly-shaped windows (mirrors `PaceAlertPlanner`).
        public var weeklyResetTolerance: TimeInterval
        /// The session counterpart — a ~5h period needs a far smaller bar.
        public var sessionResetTolerance: TimeInterval
        /// How far (in elapsed-time terms) the previous life's nearest sample
        /// may sit from the comparison offset before the comparison is
        /// declared insufficient, per window shape.
        public var weeklyCoverageTolerance: TimeInterval
        public var sessionCoverageTolerance: TimeInterval
        /// Minimum readings a previous life needs before it can anchor a
        /// comparison.
        public var minimumPreviousLifeSamples: Int

        public static let standard = Configuration()

        public init(
            dropEpsilon: Double = 0.5,
            weeklyResetTolerance: TimeInterval = 24 * 3600,
            sessionResetTolerance: TimeInterval = 30 * 60,
            weeklyCoverageTolerance: TimeInterval = 12 * 3600,
            sessionCoverageTolerance: TimeInterval = 3600,
            minimumPreviousLifeSamples: Int = 2
        ) {
            self.dropEpsilon = dropEpsilon
            self.weeklyResetTolerance = weeklyResetTolerance
            self.sessionResetTolerance = sessionResetTolerance
            self.weeklyCoverageTolerance = weeklyCoverageTolerance
            self.sessionCoverageTolerance = sessionCoverageTolerance
            self.minimumPreviousLifeSamples = minimumPreviousLifeSamples
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    // MARK: - Window lives

    /// Splits a window's chronological readings at reset boundaries. Readings
    /// are sorted first — a backwards clock step must not corrupt the
    /// segmentation.
    public func lives(
        readings: [BurnRateEstimator.Reading],
        kind: UsageWindowKind
    ) -> [[BurnRateEstimator.Reading]] {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var result: [[BurnRateEstimator.Reading]] = []
        var current: [BurnRateEstimator.Reading] = []
        for reading in sorted {
            if let last = current.last, isBoundary(from: last, to: reading, kind: kind) {
                result.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private func isBoundary(
        from last: BurnRateEstimator.Reading,
        to next: BurnRateEstimator.Reading,
        kind: UsageWindowKind
    ) -> Bool {
        if next.usedPercent < last.usedPercent - configuration.dropEpsilon {
            return true
        }
        if let lastReset = last.resetDate, let nextReset = next.resetDate {
            return nextReset.timeIntervalSince(lastReset) > resetTolerance(for: kind)
        }
        return false
    }

    private func resetTolerance(for kind: UsageWindowKind) -> TimeInterval {
        kind == .session ? configuration.sessionResetTolerance : configuration.weeklyResetTolerance
    }

    private func coverageTolerance(for kind: UsageWindowKind) -> TimeInterval {
        kind == .session ? configuration.sessionCoverageTolerance : configuration.weeklyCoverageTolerance
    }

    // MARK: - Period-over-period trend

    /// Compares the latest reading against the PREVIOUS window life at the
    /// same elapsed position into the window — "57% used where last week you
    /// were at 45% by this point". Returns nil whenever the comparison would
    /// be a guess: no complete previous life, too few samples, or the
    /// previous life has no observation near the comparison offset.
    public func periodOverPeriodTrend(
        readings: [BurnRateEstimator.Reading],
        window: UsageWindow
    ) -> UsageTrend? {
        let lives = lives(readings: readings, kind: window.kind)
        guard lives.count >= 2,
              let currentLife = lives.last,
              let latest = currentLife.last else {
            return nil
        }
        let previousLife = lives[lives.count - 2]
        guard previousLife.count >= configuration.minimumPreviousLifeSamples else {
            return nil
        }

        var confidence = TrendConfidence.normal

        // The elapsed position of the latest reading. Exact when the window
        // carries a reset anchor and a duration; otherwise inferred from the
        // life's first observation, which undercounts if the life started
        // before the app saw it.
        let currentElapsed: TimeInterval
        if let resetDate = window.resetDate, let minutes = window.windowMinutes {
            currentElapsed = Double(minutes) * 60 - resetDate.timeIntervalSince(latest.timestamp)
        } else if let first = currentLife.first {
            currentElapsed = latest.timestamp.timeIntervalSince(first.timestamp)
            confidence = .low
        } else {
            return nil
        }
        guard currentElapsed >= 0 else {
            return nil
        }

        // Position the previous life's readings on the same elapsed axis.
        var positioned: [(elapsed: TimeInterval, usedPercent: Double)] = []
        for reading in previousLife {
            if let reset = reading.resetDate, let minutes = window.windowMinutes {
                positioned.append((Double(minutes) * 60 - reset.timeIntervalSince(reading.timestamp), reading.usedPercent))
            } else if let first = previousLife.first {
                positioned.append((reading.timestamp.timeIntervalSince(first.timestamp), reading.usedPercent))
                confidence = .low
            }
        }
        positioned.sort { $0.elapsed < $1.elapsed }
        guard let firstPosition = positioned.first, let lastPosition = positioned.last else {
            return nil
        }

        // Interpolating BETWEEN samples is safe — utilization is monotone
        // within a life, so the value is bounded by the bracketing readings
        // (and the store's dedupe makes sparse flat stretches normal). But
        // extrapolating beyond the previous life's observed range would
        // manufacture a number, so the offset may only overshoot the range by
        // the coverage tolerance (then clamps to the nearest endpoint).
        let tolerance = coverageTolerance(for: window.kind)
        guard currentElapsed >= firstPosition.elapsed - tolerance,
              currentElapsed <= lastPosition.elapsed + tolerance else {
            return nil
        }

        let clamped = min(max(currentElapsed, firstPosition.elapsed), lastPosition.elapsed)
        var previousValue = firstPosition.usedPercent
        for index in 0..<(positioned.count - 1) {
            let a = positioned[index]
            let b = positioned[index + 1]
            guard clamped >= a.elapsed, clamped <= b.elapsed else {
                continue
            }
            let span = b.elapsed - a.elapsed
            let fraction = span > 0 ? (clamped - a.elapsed) / span : 0
            previousValue = a.usedPercent + fraction * (b.usedPercent - a.usedPercent)
            break
        }

        let delta = latest.usedPercent - previousValue
        return UsageTrend(
            windowID: window.id,
            currentUsedPercent: latest.usedPercent,
            previousUsedPercentAtSamePoint: previousValue,
            deltaPercentagePoints: delta,
            relativeChange: previousValue > 1 ? delta / previousValue : nil,
            confidence: confidence
        )
    }

    // MARK: - Interval statistics (digest building blocks)

    /// Total percentage points consumed inside `interval`, summing positive
    /// deltas between consecutive readings. A NEGATIVE delta means the window
    /// reset in the gap: the new life's observed value is what was consumed
    /// since (the old life's unobserved tail is knowingly dropped — this is a
    /// floor, not an exact figure). Returns nil when the window has no
    /// readings at or before the interval at all.
    public func consumption(
        readings: [BurnRateEstimator.Reading],
        in interval: DateInterval
    ) -> Double? {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        // Seed with the last reading before the interval: the store dedupes
        // identical consecutive readings, so absence means "unchanged", and
        // the boundary delta would otherwise be lost.
        var previous = sorted.last { $0.timestamp < interval.start }
        let inInterval = sorted.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
        guard previous != nil || !inInterval.isEmpty else {
            return nil
        }

        var total = 0.0
        for reading in inInterval {
            if let previous {
                let delta = reading.usedPercent - previous.usedPercent
                total += delta >= 0 ? delta : reading.usedPercent
            }
            previous = reading
        }
        return total
    }

    /// The highest utilization level during `interval`. Seeded with the last
    /// pre-interval reading: utilization is a level, not an event, so a flat
    /// 80% spanning the boundary counts as an 80% peak inside the interval.
    public func peak(
        readings: [BurnRateEstimator.Reading],
        in interval: DateInterval
    ) -> Double? {
        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        var candidates = sorted
            .filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
            .map(\.usedPercent)
        if let carried = sorted.last(where: { $0.timestamp < interval.start }) {
            candidates.append(carried.usedPercent)
        }
        return candidates.max()
    }

    /// How many window lives reached (effectively) 100% during `interval`.
    /// Counted per life, not per reading — a window sitting at 100% for two
    /// days is one limit hit. A floor: a window can roll over between polls
    /// without a 100% reading ever being recorded.
    public func limitHits(
        readings: [BurnRateEstimator.Reading],
        kind: UsageWindowKind,
        in interval: DateInterval,
        threshold: Double = 99.5
    ) -> Int {
        lives(readings: readings, kind: kind).reduce(0) { count, life in
            let hit = life.contains {
                $0.usedPercent >= threshold
                    && $0.timestamp >= interval.start
                    && $0.timestamp <= interval.end
            }
            return count + (hit ? 1 : 0)
        }
    }
}
