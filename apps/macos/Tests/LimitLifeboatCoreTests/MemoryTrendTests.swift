import XCTest
@testable import LimitLifeboatCore

final class MemoryTrendTests: XCTestCase {
    private func status(used: UInt64, total: UInt64 = 100) -> SystemMemoryStatus {
        SystemMemoryStatus(totalBytes: total, usedBytes: used, swapUsedBytes: 0, pressure: .normal)
    }

    func testKeepsOnlyTheNewestReadingsUpToCapacity() {
        var trend = MemoryTrend(capacity: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for step in 0..<5 {
            trend.append(status(used: UInt64(step * 10)), at: start.addingTimeInterval(Double(step) * 10))
        }

        XCTAssertEqual(trend.samples.map(\.usedFraction), [0.2, 0.3, 0.4])
        XCTAssertEqual(trend.latest?.date, start.addingTimeInterval(40))
        XCTAssertEqual(trend.latestStatus, status(used: 40))
    }

    func testUsedFractionStaysWithinZeroToOne() {
        XCTAssertEqual(status(used: 150).usedFraction, 1)
        XCTAssertEqual(status(used: 10, total: 0).usedFraction, 0)
        XCTAssertEqual(MemoryTrendSample(date: Date(), usedFraction: 1.4).usedFraction, 1)
        XCTAssertEqual(MemoryTrendSample(date: Date(), usedFraction: -0.2).usedFraction, 0)
    }
}
