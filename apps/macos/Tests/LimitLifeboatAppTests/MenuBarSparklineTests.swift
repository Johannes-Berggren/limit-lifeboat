import AppKit
import XCTest
@testable import LimitLifeboat
@testable import LimitLifeboatCore

final class MenuBarSparklineTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(minutesAgo: Double, used: Double) -> MemoryTrendSample {
        MemoryTrendSample(date: end.addingTimeInterval(-minutesAgo * 60), usedFraction: used)
    }

    /// A trend holding exactly these readings, oldest first.
    private func trend(_ samples: [MemoryTrendSample]) -> MemoryTrend {
        var trend = MemoryTrend()
        for sample in samples {
            trend.append(
                SystemMemoryStatus(
                    totalBytes: 100,
                    usedBytes: UInt64((sample.usedFraction * 100).rounded()),
                    swapUsedBytes: 0,
                    pressure: .normal
                ),
                at: sample.date
            )
        }
        return trend
    }

    func testGraphSitsBesideTheIcon() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))

        let image = MenuBarSparkline.image(icon: icon, trend: MemoryTrend(), level: .ok)

        XCTAssertEqual(
            image.size.width,
            16 + MenuBarSparkline.gap + MenuBarSparkline.graphSize.width
        )
        XCTAssertEqual(image.size.height, 16)
        XCTAssertFalse(image.isTemplate)
    }

    func testRendersWithNoneOneAndManySamples() {
        for samples in [[], [sample(minutesAgo: 0, used: 0.5)], (0..<180).map { sample(minutesAgo: Double($0) / 6, used: 0.6) }.reversed()] {
            let image = MenuBarSparkline.image(icon: nil, trend: trend(Array(samples)), level: .critical)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    func testPointsScrollInFromTheRightOnAFixedScale() {
        let rect = NSRect(x: 0, y: 0, width: 26, height: 12)

        let points = MenuBarSparkline.points(
            for: [
                sample(minutesAgo: 45, used: 0.9),
                sample(minutesAgo: 15, used: 0),
                sample(minutesAgo: 0, used: 1)
            ],
            span: MemoryTrend.defaultWindow,
            in: rect
        )

        // The 45-minute-old reading has scrolled off the 30-minute window.
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, rect.midX, accuracy: 0.01)
        XCTAssertEqual(points[0].y, 0.75, accuracy: 0.01)
        XCTAssertEqual(points[1].x, rect.maxX - 0.75, accuracy: 0.01)
        XCTAssertEqual(points[1].y, rect.maxY - 0.75, accuracy: 0.01)
    }

    /// Freshly enabled, the graph plots what it has across the full width
    /// rather than crowding a few readings against the right edge.
    func testYoungTrendStillFillsTheWidth() {
        let young = trend((0...12).map { sample(minutesAgo: Double(12 - $0) / 6, used: 0.5) })
        XCTAssertEqual(young.displaySpan, 120, accuracy: 0.01)

        let rect = NSRect(x: 0, y: 0, width: 26, height: 12)
        let points = MenuBarSparkline.points(for: young.samples, span: young.displaySpan, in: rect)

        XCTAssertEqual(points.count, 13)
        XCTAssertEqual(points.first?.x ?? 0, rect.minX + 0.75, accuracy: 0.01)
        XCTAssertEqual(points.last?.x ?? 0, rect.maxX - 0.75, accuracy: 0.01)
    }

    /// The very first readings are not stretched across the whole width.
    func testFirstReadingsHoldAMinimumSpan() {
        let fresh = trend((0...2).map { sample(minutesAgo: Double(2 - $0) / 6, used: 0.5) })

        XCTAssertEqual(fresh.displaySpan, MemoryTrend.minimumDisplaySpan, accuracy: 0.01)
    }

    /// Once past the window the span stops growing, so the graph scrolls.
    func testMatureTrendPinsToTheFullWindow() {
        let mature = trend(stride(from: 45.0, through: 0, by: -0.5).map { sample(minutesAgo: $0, used: 0.5) })
        XCTAssertEqual(mature.displaySpan, MemoryTrend.defaultWindow, accuracy: 0.01)
    }

    func testTintFollowsMemoryGuard() {
        XCTAssertEqual(MenuBarSparkline.color(for: .ok), .secondaryLabelColor)
        XCTAssertEqual(MenuBarSparkline.color(for: .caution), .systemOrange)
        XCTAssertEqual(MenuBarSparkline.color(for: .critical), .systemRed)
    }
}
