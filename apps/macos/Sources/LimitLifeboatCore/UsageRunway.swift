import Foundation

/// The shape of one window's current life, laid out on the window's own
/// timeline: x runs from the window's start (0) to its reset (1), y from 0%
/// (0) to 100% used (1). Pure geometry in a unit square so the gauge can
/// scale it to any size and tests can pin it down without SwiftUI.
public struct UsageRunway: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Usage so far this life, oldest first, ending at "now".
    public var history: [Point]
    /// Where "now" sits on the timeline.
    public var nowX: Double
    /// Where the current pace lands: on the 100% ceiling when the window runs
    /// dry first, otherwise at the reset edge. Nil without a usable pace.
    public var projectionEnd: UsageRunway.Point?
    /// From the projected empty moment to the reset: the stretch with no
    /// quota left. Nil when the window lasts until its reset.
    public var dryStart: Double?
    /// Recent consumption, in percentage points per hour.
    public var ratePerHour: Double?

    public init(
        history: [Point],
        nowX: Double,
        projectionEnd: Point? = nil,
        dryStart: Double? = nil,
        ratePerHour: Double? = nil
    ) {
        self.history = history
        self.nowX = nowX
        self.projectionEnd = projectionEnd
        self.dryStart = dryStart
        self.ratePerHour = ratePerHour
    }
}

/// Builds a `UsageRunway` from a window and its stored readings.
public struct UsageRunwayBuilder: Sendable {
    /// More points than the gauge has pixels only costs drawing time; a 7-day
    /// window at 5-minute refreshes would otherwise carry ~2000.
    public var maximumPoints: Int
    /// How far back the rate readout looks when no depletion is projected.
    public var rateLookback: TimeInterval

    public init(maximumPoints: Int = 96, rateLookback: TimeInterval = 60 * 60) {
        self.maximumPoints = maximumPoints
        self.rateLookback = rateLookback
    }

    /// Nil when the window has no timeline to draw on (no reset date or
    /// length), the reset already passed, or there is no history this life.
    /// The gauge then falls back to its plain fill bar.
    public func runway(
        window: UsageWindow,
        readings: [BurnRateEstimator.Reading],
        depletesAt: Date?,
        now: Date
    ) -> UsageRunway? {
        guard let resetDate = window.resetDate,
              resetDate > now,
              let minutes = window.windowMinutes ?? Self.defaultMinutes(for: window.kind),
              minutes > 0 else {
            return nil
        }
        let length = Double(minutes) * 60
        let start = resetDate.addingTimeInterval(-length)
        let life = currentLife(readings: readings, start: start, now: now)
        guard !life.isEmpty else {
            return nil
        }

        func x(_ date: Date) -> Double {
            min(1, max(0, date.timeIntervalSince(start) / length))
        }
        func y(_ percent: Double) -> Double {
            min(1, max(0, percent / 100))
        }

        var points = downsample(life).map { UsageRunway.Point(x: x($0.timestamp), y: y($0.usedPercent)) }
        let nowX = x(now)
        // The live reading may be newer than the last stored one; end the
        // line at "now" on the value the gauge is showing.
        points.append(UsageRunway.Point(x: nowX, y: y(window.usedPercent)))
        points = Self.monotoneInX(points)

        var projectionEnd: UsageRunway.Point?
        var dryStart: Double?
        var rate: Double?
        if let depletesAt, depletesAt > now, depletesAt < resetDate {
            let dryX = x(depletesAt)
            projectionEnd = UsageRunway.Point(x: dryX, y: 1)
            dryStart = dryX
            rate = (100 - window.usedPercent) / (depletesAt.timeIntervalSince(now) / 3600)
        } else if let recent = recentRate(life: life, current: window.usedPercent, now: now) {
            rate = recent
            if recent > 0 {
                let hoursLeft = resetDate.timeIntervalSince(now) / 3600
                projectionEnd = UsageRunway.Point(x: 1, y: y(window.usedPercent + recent * hoursLeft))
            }
        }

        return UsageRunway(
            history: points,
            nowX: nowX,
            projectionEnd: projectionEnd,
            dryStart: dryStart,
            ratePerHour: rate
        )
    }

    static func defaultMinutes(for kind: UsageWindowKind) -> Int? {
        switch kind {
        case .session:
            return 300
        case .weekly, .weeklyScoped:
            return 10_080
        case .other:
            return nil
        }
    }

    /// Readings since the window started, cut at the most recent backward
    /// drop: TUI-sourced reset dates jitter, so a drop in usage is the
    /// reliable sign that an older reading belongs to the previous life.
    private func currentLife(
        readings: [BurnRateEstimator.Reading],
        start: Date,
        now: Date
    ) -> [BurnRateEstimator.Reading] {
        let inWindow = readings
            .filter { $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        var backward: [BurnRateEstimator.Reading] = []
        for reading in inWindow.reversed() {
            if let newer = backward.last, reading.usedPercent > newer.usedPercent + 0.5 {
                break
            }
            backward.append(reading)
        }
        return backward.reversed()
    }

    /// Keeps the last reading of each time bucket so the line still ends on
    /// real values and steps stay steps.
    private func downsample(_ readings: [BurnRateEstimator.Reading]) -> [BurnRateEstimator.Reading] {
        guard readings.count > maximumPoints,
              let first = readings.first?.timestamp,
              let last = readings.last?.timestamp else {
            return readings
        }
        let span = max(1, last.timeIntervalSince(first))
        var buckets: [Int: BurnRateEstimator.Reading] = [:]
        for reading in readings {
            let index = min(
                maximumPoints - 1,
                Int(reading.timestamp.timeIntervalSince(first) / span * Double(maximumPoints))
            )
            buckets[index] = reading
        }
        return buckets.keys.sorted().compactMap { buckets[$0] }
    }

    private func recentRate(
        life: [BurnRateEstimator.Reading],
        current: Double,
        now: Date
    ) -> Double? {
        let cutoff = now.addingTimeInterval(-rateLookback)
        guard let anchor = life.first(where: { $0.timestamp >= cutoff }) ?? life.last else {
            return nil
        }
        let hours = now.timeIntervalSince(anchor.timestamp) / 3600
        // Under ten minutes of spread says more about refresh jitter than pace.
        guard hours >= 1.0 / 6 else {
            return nil
        }
        return max(0, (current - anchor.usedPercent) / hours)
    }

    private static func monotoneInX(_ points: [UsageRunway.Point]) -> [UsageRunway.Point] {
        var result: [UsageRunway.Point] = []
        for point in points {
            if let last = result.last, point.x <= last.x {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
        return result
    }
}

public enum UsageRatePhrase {
    /// "9%/h", or "0.4%/h" for slow weekly burn. Nil for no movement, which
    /// would only add noise to a caption.
    public static func text(perHour rate: Double) -> String? {
        guard rate >= 0.05 else {
            return nil
        }
        if rate < 1 {
            return String(format: "%.1f%%/h", rate)
        }
        return "\(Int(rate.rounded()))%/h"
    }
}
