import AppKit
import XCTest
@testable import LimitLifeboat
@testable import LimitLifeboatCore

final class MenuBarSparklineTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(minutesAgo: Double, used: Double) -> MemoryTrendSample {
        MemoryTrendSample(date: end.addingTimeInterval(-minutesAgo * 60), usedFraction: used)
    }

    func testGraphSitsBesideTheIcon() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))

        let image = MenuBarSparkline.image(icon: icon, samples: [], level: .ok)

        XCTAssertEqual(
            image.size.width,
            16 + MenuBarSparkline.gap + MenuBarSparkline.graphSize.width
        )
        XCTAssertEqual(image.size.height, 16)
        XCTAssertFalse(image.isTemplate)
    }

    func testRendersWithNoneOneAndManySamples() {
        for samples in [[], [sample(minutesAgo: 0, used: 0.5)], (0..<180).map { sample(minutesAgo: Double($0) / 6, used: 0.6) }.reversed()] {
            let image = MenuBarSparkline.image(icon: nil, samples: Array(samples), level: .critical)
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
            in: rect
        )

        // The 45-minute-old reading has scrolled off the 30-minute window.
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, rect.midX, accuracy: 0.01)
        XCTAssertEqual(points[0].y, 0.75, accuracy: 0.01)
        XCTAssertEqual(points[1].x, rect.maxX - 0.75, accuracy: 0.01)
        XCTAssertEqual(points[1].y, rect.maxY - 0.75, accuracy: 0.01)
    }

    func testTintFollowsMemoryGuard() {
        XCTAssertEqual(MenuBarSparkline.color(for: .ok), .secondaryLabelColor)
        XCTAssertEqual(MenuBarSparkline.color(for: .caution), .systemOrange)
        XCTAssertEqual(MenuBarSparkline.color(for: .critical), .systemRed)
    }
}
