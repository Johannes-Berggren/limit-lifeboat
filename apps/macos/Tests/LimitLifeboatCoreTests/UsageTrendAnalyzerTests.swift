import XCTest
@testable import LimitLifeboatCore

final class UsageTrendAnalyzerTests: XCTestCase {
    private let analyzer = UsageTrendAnalyzer()
    private let base = Date(timeIntervalSince1970: 1_783_000_000)

    private func reading(_ hours: Double, _ usedPercent: Double, reset: Date? = nil) -> BurnRateEstimator.Reading {
        BurnRateEstimator.Reading(
            timestamp: base.addingTimeInterval(hours * 3600),
            usedPercent: usedPercent,
            resetDate: reset
        )
    }

    // MARK: - Life segmentation

    func testUsageDropSplitsLives() {
        let lives = analyzer.lives(
            readings: [reading(0, 40), reading(1, 60), reading(2, 5), reading(3, 10)],
            kind: .weekly
        )
        XCTAssertEqual(lives.map { $0.map(\.usedPercent) }, [[40, 60], [5, 10]])
    }

    func testTinyDropWithinEpsilonDoesNotSplit() {
        let lives = analyzer.lives(
            readings: [reading(0, 40), reading(1, 39.7)],
            kind: .weekly
        )
        XCTAssertEqual(lives.count, 1)
    }

    func testResetDateJitterWithinToleranceDoesNotSplit() {
        let reset = base.addingTimeInterval(4 * 24 * 3600)
        let lives = analyzer.lives(
            readings: [
                reading(0, 40, reset: reset),
                reading(1, 45, reset: reset.addingTimeInterval(600))
            ],
            kind: .weekly
        )
        XCTAssertEqual(lives.count, 1)
    }

    func testResetDateJumpBeyondToleranceSplitsEvenWithoutADrop() {
        let reset = base.addingTimeInterval(4 * 24 * 3600)
        let lives = analyzer.lives(
            readings: [
                reading(0, 40, reset: reset),
                // Flat usage but a reset a week later — a new period whose
                // usage happens to match.
                reading(1, 40, reset: reset.addingTimeInterval(7 * 24 * 3600))
            ],
            kind: .weekly
        )
        XCTAssertEqual(lives.count, 2)
    }

    func testSessionKindUsesTighterResetTolerance() {
        let reset = base.addingTimeInterval(3600)
        let lives = analyzer.lives(
            readings: [
                reading(0, 40, reset: reset),
                // A 5h-later reset is a new session period despite flat usage.
                reading(1, 40, reset: reset.addingTimeInterval(5 * 3600))
            ],
            kind: .session
        )
        XCTAssertEqual(lives.count, 2)
    }

    func testNonMonotonicTimestampsAreSortedBeforeSegmentation() {
        let lives = analyzer.lives(
            readings: [reading(2, 60), reading(0, 20), reading(1, 40)],
            kind: .weekly
        )
        XCTAssertEqual(lives.map { $0.map(\.usedPercent) }, [[20, 40, 60]])
    }

    // MARK: - Period-over-period trend

    /// Exact-anchor comparison: current life at elapsed 5d reads 60; the
    /// previous life read 40 at 4d and 50 at 6d — interpolated 45 at 5d.
    func testTrendInterpolatesPreviousLifeAtSameElapsedPosition() {
        let minutes = 10_080
        let weekSeconds = Double(minutes) * 60
        let currentReset = base.addingTimeInterval(2 * 24 * 3600)
        let previousReset = currentReset.addingTimeInterval(-weekSeconds)
        func previousReading(elapsedDays: Double, used: Double) -> BurnRateEstimator.Reading {
            BurnRateEstimator.Reading(
                timestamp: previousReset.addingTimeInterval(-(weekSeconds - elapsedDays * 24 * 3600)),
                usedPercent: used,
                resetDate: previousReset
            )
        }
        let window = UsageWindow(
            id: "weekly-all",
            kind: .weekly,
            label: "Weekly (all models)",
            usedPercent: 60,
            resetDate: currentReset,
            windowMinutes: minutes
        )
        let latest = BurnRateEstimator.Reading(timestamp: base, usedPercent: 60, resetDate: currentReset)

        let trend = analyzer.periodOverPeriodTrend(
            readings: [
                previousReading(elapsedDays: 4, used: 40),
                previousReading(elapsedDays: 6, used: 50),
                latest
            ],
            window: window
        )

        XCTAssertEqual(trend?.currentUsedPercent, 60)
        XCTAssertEqual(trend!.previousUsedPercentAtSamePoint, 45, accuracy: 0.01)
        XCTAssertEqual(trend!.deltaPercentagePoints, 15, accuracy: 0.01)
        XCTAssertEqual(trend!.relativeChange!, 1.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(trend?.confidence, .normal)
    }

    func testTrendNilWithoutACompletePreviousLife() {
        let window = UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly", usedPercent: 60)
        XCTAssertNil(
            analyzer.periodOverPeriodTrend(
                readings: [reading(0, 20), reading(24, 60)],
                window: window
            )
        )
    }

    /// The previous life was only observed in its first day; comparing at day
    /// five would extrapolate far beyond anything observed.
    func testTrendNilWhenPreviousLifeLacksCoverageNearTheOffset() {
        let minutes = 10_080
        let weekSeconds = Double(minutes) * 60
        let currentReset = base.addingTimeInterval(2 * 24 * 3600)
        let previousReset = currentReset.addingTimeInterval(-weekSeconds)
        func previousReading(elapsedDays: Double, used: Double) -> BurnRateEstimator.Reading {
            BurnRateEstimator.Reading(
                timestamp: previousReset.addingTimeInterval(-(weekSeconds - elapsedDays * 24 * 3600)),
                usedPercent: used,
                resetDate: previousReset
            )
        }
        let window = UsageWindow(
            id: "weekly-all",
            kind: .weekly,
            label: "Weekly",
            usedPercent: 60,
            resetDate: currentReset,
            windowMinutes: minutes
        )

        XCTAssertNil(
            analyzer.periodOverPeriodTrend(
                readings: [
                    previousReading(elapsedDays: 0.2, used: 5),
                    previousReading(elapsedDays: 0.8, used: 12),
                    BurnRateEstimator.Reading(timestamp: base, usedPercent: 60, resetDate: currentReset)
                ],
                window: window
            )
        )
    }

    /// Without reset anchors the comparison still works off observation-time
    /// axes, flagged low-confidence.
    func testTrendWithoutResetAnchorsIsLowConfidence() {
        let window = UsageWindow(id: "weekly-all", kind: .weekly, label: "Weekly", usedPercent: 60)
        let trend = analyzer.periodOverPeriodTrend(
            readings: [
                // Previous life: 0h → 10%, 48h → 30%.
                reading(0, 10), reading(48, 30),
                // Reset (drop), then current life: 0h → 5%, 24h → 40%.
                reading(72, 5), reading(96, 40)
            ],
            window: window
        )

        // Current elapsed = 24h into the life; previous life at 24h = 20%.
        XCTAssertEqual(trend!.previousUsedPercentAtSamePoint, 20, accuracy: 0.01)
        XCTAssertEqual(trend!.deltaPercentagePoints, 20, accuracy: 0.01)
        XCTAssertEqual(trend?.confidence, .low)
    }

    // MARK: - Interval statistics

    func testConsumptionSumsPositiveDeltasAndSeedsFromBeforeTheInterval() {
        let interval = DateInterval(
            start: base.addingTimeInterval(3600),
            end: base.addingTimeInterval(10 * 3600)
        )
        let consumption = analyzer.consumption(
            readings: [reading(0, 20), reading(2, 30), reading(4, 55)],
            in: interval
        )
        // 20 → 30 (+10 crosses the boundary via the seed) → 55 (+25).
        XCTAssertEqual(consumption!, 35, accuracy: 0.001)
    }

    func testConsumptionCreditsNewLifeAfterAResetInAGap() {
        let interval = DateInterval(start: base, end: base.addingTimeInterval(10 * 3600))
        let consumption = analyzer.consumption(
            readings: [reading(1, 80), reading(5, 15)],
            in: interval
        )
        // 80 → 15 is a reset in the gap: the new life consumed its observed
        // 15; the old life's unobserved tail (80 → 100?) is dropped.
        XCTAssertEqual(consumption!, 15, accuracy: 0.001)
    }

    func testConsumptionZeroWhenOnlyTheCarriedReadingExists() {
        let interval = DateInterval(
            start: base.addingTimeInterval(3600),
            end: base.addingTimeInterval(2 * 3600)
        )
        XCTAssertEqual(analyzer.consumption(readings: [reading(0, 40)], in: interval), 0)
    }

    func testConsumptionNilWithNoReadingsAtAll() {
        let interval = DateInterval(start: base, end: base.addingTimeInterval(3600))
        XCTAssertNil(analyzer.consumption(readings: [], in: interval))
    }

    /// The dedupe carry-forward: a flat 80% recorded before the interval and
    /// never re-recorded inside it must still count as an 80% peak.
    func testPeakCarriesTheLastPreIntervalReadingForward() {
        let interval = DateInterval(
            start: base.addingTimeInterval(3600),
            end: base.addingTimeInterval(10 * 3600)
        )
        XCTAssertEqual(analyzer.peak(readings: [reading(0, 80)], in: interval), 80)
        XCTAssertEqual(
            analyzer.peak(readings: [reading(0, 80), reading(2, 30)], in: interval),
            80
        )
    }

    func testLimitHitsCountPerLifeNotPerReading() {
        let interval = DateInterval(start: base, end: base.addingTimeInterval(20 * 3600))
        let hits = analyzer.limitHits(
            readings: [
                // Life 1: sits at 100 across two readings — one hit.
                reading(1, 99.8), reading(2, 100),
                // Reset, life 2: never reaches the limit.
                reading(5, 10), reading(6, 50),
                // Reset, life 3: hits again — second hit.
                reading(8, 5), reading(9, 100)
            ],
            kind: .weekly,
            in: interval
        )
        XCTAssertEqual(hits, 2)
    }

    func testLimitHitsOutsideTheIntervalDoNotCount() {
        let interval = DateInterval(start: base.addingTimeInterval(4 * 3600), end: base.addingTimeInterval(20 * 3600))
        let hits = analyzer.limitHits(
            readings: [reading(1, 100), reading(5, 10), reading(6, 40)],
            kind: .weekly,
            in: interval
        )
        XCTAssertEqual(hits, 0)
    }
}
