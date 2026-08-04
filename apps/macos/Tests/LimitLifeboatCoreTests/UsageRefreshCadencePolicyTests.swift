import XCTest
@testable import LimitLifeboatCore

final class UsageRefreshCadencePolicyTests: XCTestCase {
    private let policy = UsageRefreshCadencePolicy()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)
    private let configuredInterval: TimeInterval = 5 * 60

    func testUsesConfiguredIntervalWithoutSuccessfulActiveSnapshot() {
        XCTAssertEqual(
            policy.interval(
                configuredInterval: configuredInterval,
                successfulActiveSnapshots: [],
                now: now
            ),
            configuredInterval
        )
    }

    func testAcceleratesSessionAtNinetyPercentUsed() {
        XCTAssertEqual(interval(kind: .session, usedPercent: 90), 60)
    }

    func testDoesNotAccelerateSessionBelowNinetyPercentUsed() {
        XCTAssertEqual(interval(kind: .session, usedPercent: 89.9), configuredInterval)
    }

    func testAcceleratesWeeklyAtNinetyFourPercentUsed() {
        XCTAssertEqual(interval(kind: .weekly, usedPercent: 94), 60)
    }

    func testDoesNotAccelerateWeeklyBelowNinetyFourPercentUsed() {
        XCTAssertEqual(interval(kind: .weekly, usedPercent: 93.9), configuredInterval)
    }

    func testWeeklyScopedUsesWeeklyNearLimitThreshold() {
        XCTAssertEqual(interval(kind: .weeklyScoped, usedPercent: 94), 60)
    }

    func testOtherWindowUsesSessionCompatibleNearLimitThreshold() {
        XCTAssertEqual(interval(kind: .other, usedPercent: 90), 60)
    }

    func testElapsedNearLimitWindowDoesNotAccelerate() {
        let snapshot = makeSnapshot(
            kind: .session,
            usedPercent: 99,
            resetDate: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            policy.interval(
                configuredInterval: configuredInterval,
                successfulActiveSnapshots: [snapshot],
                now: now
            ),
            configuredInterval
        )
    }

    func testUnknownUsageDoesNotAccelerate() {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            riskLevel: .unknown,
            source: "test",
            lastRefreshed: now,
            parseConfidence: .none
        )

        XCTAssertEqual(
            policy.interval(
                configuredInterval: configuredInterval,
                successfulActiveSnapshots: [snapshot],
                now: now
            ),
            configuredInterval
        )
    }

    func testNeverLengthensShorterConfiguredInterval() {
        XCTAssertEqual(
            policy.interval(
                configuredInterval: 30,
                successfulActiveSnapshots: [makeSnapshot(kind: .session, usedPercent: 90)],
                now: now
            ),
            30
        )
    }

    private func interval(kind: UsageWindowKind, usedPercent: Double) -> TimeInterval {
        policy.interval(
            configuredInterval: configuredInterval,
            successfulActiveSnapshots: [makeSnapshot(kind: kind, usedPercent: usedPercent)],
            now: now
        )
    }

    private func makeSnapshot(
        kind: UsageWindowKind,
        usedPercent: Double,
        resetDate: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [
                UsageWindow(
                    id: "window",
                    kind: kind,
                    label: "Window",
                    usedPercent: usedPercent,
                    resetDate: resetDate,
                    riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent)
                )
            ],
            source: "test",
            lastRefreshed: now,
            parseConfidence: .high
        )
    }
}
