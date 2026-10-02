import XCTest
@testable import LimitLifeboatCore

final class UsageRunwayTests: XCTestCase {
    private let builder = UsageRunwayBuilder()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testLaysOutHistoryOnTheWindowTimeline() throws {
        // A 5h window resetting in 2h started 3h ago, so "now" sits at 0.6.
        let window = sessionWindow(usedPercent: 60, resetIn: 2 * 3_600)
        let runway = try XCTUnwrap(builder.runway(
            window: window,
            readings: [reading(minutesAgo: 120, 20), reading(minutesAgo: 60, 40)],
            depletesAt: nil,
            now: now
        ))

        XCTAssertEqual(runway.nowX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(runway.history.count, 3)
        XCTAssertEqual(runway.history[0].x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(runway.history[0].y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(runway.history.last?.x ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(runway.history.last?.y ?? 0, 0.6, accuracy: 1e-9)
    }

    func testDepletionBeforeResetMarksTheDryStretch() throws {
        let window = sessionWindow(usedPercent: 80, resetIn: 2 * 3_600)
        let runway = try XCTUnwrap(builder.runway(
            window: window,
            readings: [reading(minutesAgo: 60, 50)],
            depletesAt: now.addingTimeInterval(20 * 60),
            now: now
        ))

        // Empty 20 minutes from now, on a 300-minute timeline that started
        // 180 minutes ago: x = 200/300.
        let dryStart = try XCTUnwrap(runway.dryStart)
        XCTAssertEqual(dryStart, 200.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(runway.projectionEnd, UsageRunway.Point(x: dryStart, y: 1))
        // 20 points left in a third of an hour.
        XCTAssertEqual(runway.ratePerHour ?? 0, 60, accuracy: 1e-9)
    }

    func testSafePaceProjectsToTheResetEdgeWithoutADryStretch() throws {
        let window = sessionWindow(usedPercent: 30, resetIn: 2 * 3_600)
        let runway = try XCTUnwrap(builder.runway(
            window: window,
            readings: [reading(minutesAgo: 60, 20)],
            depletesAt: nil,
            now: now
        ))

        XCTAssertNil(runway.dryStart)
        XCTAssertEqual(runway.ratePerHour ?? 0, 10, accuracy: 1e-9)
        let end = try XCTUnwrap(runway.projectionEnd)
        XCTAssertEqual(end.x, 1)
        XCTAssertEqual(end.y, 0.5, accuracy: 1e-9)
    }

    func testDropsReadingsFromThePreviousLife() throws {
        // The window reset an hour ago without the reset date moving enough to
        // tell; the drop from 90% to 5% is what gives it away.
        let window = sessionWindow(usedPercent: 15, resetIn: 4 * 3_600)
        let runway = try XCTUnwrap(builder.runway(
            window: window,
            readings: [
                reading(minutesAgo: 59, 90),
                reading(minutesAgo: 50, 5),
                reading(minutesAgo: 20, 10),
            ],
            depletesAt: nil,
            now: now
        ))

        XCTAssertEqual(runway.history.map(\.y).first ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(runway.history.count, 3)
    }

    func testDownsamplesLongHistories() throws {
        let window = UsageWindow(
            id: "weekly-all",
            kind: .weekly,
            label: "Weekly",
            usedPercent: 50,
            resetDate: now.addingTimeInterval(24 * 3_600),
            windowMinutes: 10_080
        )
        let readings = (0..<2_000).map { index in
            BurnRateEstimator.Reading(
                timestamp: now.addingTimeInterval(-Double(2_000 - index) * 5 * 60),
                usedPercent: Double(index) / 40
            )
        }

        let runway = try XCTUnwrap(builder.runway(window: window, readings: readings, depletesAt: nil, now: now))

        XCTAssertLessThanOrEqual(runway.history.count, builder.maximumPoints + 1)
        XCTAssertEqual(runway.history.map(\.x), runway.history.map(\.x).sorted())
    }

    func testNoTimelineFallsBackToThePlainBar() {
        let noReset = UsageWindow(id: "other", kind: .other, label: "Other", usedPercent: 10)
        XCTAssertNil(builder.runway(window: noReset, readings: [reading(minutesAgo: 10, 5)], depletesAt: nil, now: now))

        let window = sessionWindow(usedPercent: 10, resetIn: 3_600)
        XCTAssertNil(builder.runway(window: window, readings: [], depletesAt: nil, now: now))

        let elapsed = sessionWindow(usedPercent: 10, resetIn: -60)
        XCTAssertNil(builder.runway(window: elapsed, readings: [reading(minutesAgo: 10, 5)], depletesAt: nil, now: now))
    }

    func testUntrustedReadingsDrawHistoryWithoutPace() throws {
        let window = sessionWindow(usedPercent: 80, resetIn: 2 * 3_600)
        let runway = try XCTUnwrap(builder.runway(
            window: window,
            readings: [reading(minutesAgo: 60, 50)],
            depletesAt: now.addingTimeInterval(20 * 60),
            showsPace: false,
            now: now
        ))
        XCTAssertFalse(runway.history.isEmpty)
        XCTAssertNil(runway.projectionEnd)
        XCTAssertNil(runway.dryStart)
        XCTAssertNil(runway.ratePerHour)
    }

    func testRatePhrase() {
        XCTAssertNil(UsageRatePhrase.text(perHour: 0))
        XCTAssertEqual(UsageRatePhrase.text(perHour: 0.42), "0.4%/h")
        XCTAssertEqual(UsageRatePhrase.text(perHour: 8.6), "9%/h")
    }

    private func sessionWindow(usedPercent: Double, resetIn interval: TimeInterval) -> UsageWindow {
        UsageWindow(
            id: "session",
            kind: .session,
            label: "Session",
            usedPercent: usedPercent,
            resetDate: now.addingTimeInterval(interval)
        )
    }

    private func reading(minutesAgo: Double, _ usedPercent: Double) -> BurnRateEstimator.Reading {
        BurnRateEstimator.Reading(timestamp: now.addingTimeInterval(-minutesAgo * 60), usedPercent: usedPercent)
    }
}
