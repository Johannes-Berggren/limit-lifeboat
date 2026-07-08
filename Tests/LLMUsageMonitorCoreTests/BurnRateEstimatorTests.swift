import XCTest
@testable import LLMUsageMonitorCore

final class BurnRateEstimatorTests: XCTestCase {
    private let estimator = BurnRateEstimator()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testRisingUsageProjectsDepletion() {
        let readings = [
            reading(minutesAgo: 60, usedPercent: 20),
            reading(minutesAgo: 30, usedPercent: 40),
            reading(minutesAgo: 0, usedPercent: 60),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: sessionWindow(resetDate: now.addingTimeInterval(3 * 3_600)),
            now: now
        )

        // 40% burned per hour with 40% left: depletion in about an hour,
        // comfortably before the 3-hour reset.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 3_600, accuracy: 60)
    }

    func testDepletionAfterResetIsSafe() {
        let readings = [
            reading(minutesAgo: 60, usedPercent: 20),
            reading(minutesAgo: 30, usedPercent: 21),
            reading(minutesAgo: 0, usedPercent: 22),
        ]

        // 2%/hour depletes in ~39 hours, long after the 3-hour reset.
        XCTAssertEqual(
            estimator.estimate(
                readings: readings,
                window: sessionWindow(resetDate: now.addingTimeInterval(3 * 3_600)),
                now: now
            ),
            .safe
        )
    }

    func testFlatUsageIsSafe() {
        let readings = [
            reading(minutesAgo: 60, usedPercent: 50),
            reading(minutesAgo: 30, usedPercent: 50),
            reading(minutesAgo: 0, usedPercent: 50),
        ]

        XCTAssertEqual(
            estimator.estimate(
                readings: readings,
                window: sessionWindow(resetDate: now.addingTimeInterval(3 * 3_600)),
                now: now
            ),
            .safe
        )
    }

    func testDecreasingUsageIsSafe() {
        // A strict drop between adjacent points reads as a mid-series reset
        // and truncates the run there, so a decaying series surfaces as the
        // drop followed by a flat tail — which extrapolates to .safe.
        let readings = [
            reading(minutesAgo: 60, usedPercent: 50),
            reading(minutesAgo: 30, usedPercent: 49),
            reading(minutesAgo: 0, usedPercent: 49),
        ]

        XCTAssertEqual(
            estimator.estimate(
                readings: readings,
                window: sessionWindow(resetDate: now.addingTimeInterval(3 * 3_600)),
                now: now
            ),
            .safe
        )
    }

    func testSinglePointIsInsufficient() {
        XCTAssertEqual(
            estimator.estimate(
                readings: [reading(minutesAgo: 0, usedPercent: 60)],
                window: sessionWindow(),
                now: now
            ),
            .insufficientData
        )
    }

    func testTwoPointsTooCloseTogetherAreInsufficient() {
        let readings = [
            reading(minutesAgo: 2, usedPercent: 40),
            reading(minutesAgo: 0, usedPercent: 42),
        ]

        XCTAssertEqual(
            estimator.estimate(readings: readings, window: sessionWindow(), now: now),
            .insufficientData
        )
    }

    func testMidSeriesResetUsesOnlyPostResetPoints() {
        let readings = [
            reading(minutesAgo: 80, usedPercent: 90), // previous life of the window
            reading(minutesAgo: 30, usedPercent: 5),
            reading(minutesAgo: 0, usedPercent: 12),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: sessionWindow(resetDate: now.addingTimeInterval(7 * 3_600)),
            now: now
        )

        // 7% over 30 minutes leaves 88% depleting in ~22,629s. Including the
        // pre-reset 90% point would flip the slope negative -> .safe.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 88 * 1_800 / 7, accuracy: 60)
    }

    func testExcludesReadingsWithPriorWindowResetDate() {
        let reset = now.addingTimeInterval(2 * 3_600)
        let readings = [
            reading(minutesAgo: 60, usedPercent: 10, resetDate: reset.addingTimeInterval(-3_600)), // prior window
            reading(minutesAgo: 40, usedPercent: 20, resetDate: reset),
            reading(minutesAgo: 20, usedPercent: 40, resetDate: reset),
            reading(minutesAgo: 0, usedPercent: 60, resetDate: reset),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: sessionWindow(resetDate: reset),
            now: now
        )

        // Same-window points alone: 40% over 40 minutes -> 40% left in
        // 2,400s. Admitting the prior-window point would drag the slope down
        // to a ~2,824s depletion.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 2_400, accuracy: 60)
    }

    /// TUI-sourced readings re-anchor their reset date to "now" each poll, so
    /// minute-scale skew must still read as the same window life; only skew
    /// past the 5-minute tolerance excludes a point.
    func testResetDateMatchToleratesMinuteScaleSkew() {
        let reset = now.addingTimeInterval(2 * 3_600)
        let readings = [
            reading(minutesAgo: 60, usedPercent: 5, resetDate: reset.addingTimeInterval(600)), // 10min off: excluded
            reading(minutesAgo: 40, usedPercent: 20, resetDate: reset.addingTimeInterval(60)), // 60s off: included
            reading(minutesAgo: 20, usedPercent: 35, resetDate: reset),
            reading(minutesAgo: 0, usedPercent: 60, resetDate: reset),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: sessionWindow(resetDate: reset),
            now: now
        )

        // 20/35/60 over 40 minutes -> least-squares slope 1%/min -> 40% left
        // in ~2,400s. Admitting the 10-minute-skewed point (~2,667s) or
        // dropping the 60-second-skewed one (~1,920s) both land outside the
        // tolerance.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 2_400, accuracy: 60)
    }

    func testSessionLookbackExcludesOldPoints() {
        let readings = [
            reading(minutesAgo: 120, usedPercent: 10), // outside the 90-minute lookback
            reading(minutesAgo: 60, usedPercent: 20),
            reading(minutesAgo: 30, usedPercent: 40),
            reading(minutesAgo: 0, usedPercent: 60),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: sessionWindow(resetDate: now.addingTimeInterval(3 * 3_600)),
            now: now
        )

        // Recent points project depletion in 3,600s; including the two-hour-old
        // point would flatten the slope to a ~5,861s depletion.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 3_600, accuracy: 60)
    }

    func testWeeklyLookbackAdmitsDayOldPoints() {
        let readings = [
            reading(minutesAgo: 36 * 60, usedPercent: 20),
            reading(minutesAgo: 24 * 60, usedPercent: 40),
            reading(minutesAgo: 12 * 60, usedPercent: 60),
        ]

        let estimate = estimator.estimate(
            readings: readings,
            window: weeklyWindow(resetDate: now.addingTimeInterval(5 * 24 * 3_600)),
            now: now
        )

        // 40% over 24 hours from points 12-36 hours old: the remaining 40%
        // depletes 12 hours from now, before the reset in 5 days.
        guard let interval = depletionInterval(estimate) else { return }
        XCTAssertEqual(interval, 12 * 3_600, accuracy: 60)
    }

    func testWeeklyWindowNeedsHoursOfSpan() {
        let readings = [
            reading(minutesAgo: 20, usedPercent: 40),
            reading(minutesAgo: 0, usedPercent: 41),
        ]

        // Two points 20 minutes apart satisfy a session but not the 3-hour
        // weekly minimum span.
        XCTAssertEqual(
            estimator.estimate(
                readings: readings,
                window: weeklyWindow(resetDate: now.addingTimeInterval(5 * 24 * 3_600)),
                now: now
            ),
            .insufficientData
        )
    }

    private func reading(minutesAgo: Double, usedPercent: Double, resetDate: Date? = nil) -> BurnRateEstimator.Reading {
        BurnRateEstimator.Reading(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            usedPercent: usedPercent,
            resetDate: resetDate
        )
    }

    private func sessionWindow(resetDate: Date? = nil) -> UsageWindow {
        UsageWindow(
            id: "session",
            kind: .session,
            label: "Session",
            usedPercent: 0,
            resetDate: resetDate,
            windowMinutes: 300
        )
    }

    private func weeklyWindow(resetDate: Date? = nil) -> UsageWindow {
        UsageWindow(
            id: "weekly-all",
            kind: .weekly,
            label: "Weekly (all models)",
            usedPercent: 0,
            resetDate: resetDate,
            windowMinutes: 10_080
        )
    }

    private func depletionInterval(
        _ estimate: BurnRateEstimate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TimeInterval? {
        guard case .depletesAt(let date) = estimate else {
            XCTFail("Expected depletesAt, got \(estimate)", file: file, line: line)
            return nil
        }
        return date.timeIntervalSince(now)
    }
}
