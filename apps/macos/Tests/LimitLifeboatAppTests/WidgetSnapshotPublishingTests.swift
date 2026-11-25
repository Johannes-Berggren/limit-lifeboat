import Foundation
@testable import LimitLifeboat
import LimitLifeboatCore
import XCTest

@MainActor
final class WidgetSnapshotPublishingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let accountID = UUID()

    private func snapshot(used: Double, generatedAt: Date, history: [UsageRunway.Point] = [], note: WidgetNote? = nil) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: generatedAt,
            accounts: [WidgetAccount(
                id: accountID, provider: .claude, label: "Work", isActive: true,
                lastRefreshed: generatedAt, note: note,
                windows: [WidgetWindow(
                    id: "session", kind: .session, label: "Session", usedPercent: used,
                    resetDate: now.addingTimeInterval(3600), riskLevel: .healthy,
                    runway: history.isEmpty ? nil : UsageRunway(history: history, nowX: 0.5)
                )]
            )]
        )
    }

    func testOnlyTheGenerationTimeChangingDoesNotRewriteTheFile() {
        XCTAssertTrue(AppState.widgetFileContentMatches(
            snapshot(used: 40, generatedAt: now),
            snapshot(used: 40, generatedAt: now)
        ))
        XCTAssertFalse(AppState.widgetFileContentMatches(
            snapshot(used: 40, generatedAt: now),
            snapshot(used: 40.4, generatedAt: now)
        ))
    }

    func testCurveAndSubPercentChangesDoNotSpendAWidgetReload() {
        let before = snapshot(used: 40.2, generatedAt: now, history: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.4)])
        let after = snapshot(used: 39.9, generatedAt: now.addingTimeInterval(300), history: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4)])
        XCTAssertTrue(AppState.widgetGlanceMatches(before, after))
    }

    func testVisibleChangesReloadTheWidget() {
        let before = snapshot(used: 40, generatedAt: now)
        XCTAssertFalse(AppState.widgetGlanceMatches(before, snapshot(used: 42, generatedAt: now)))
        XCTAssertFalse(AppState.widgetGlanceMatches(
            before,
            snapshot(used: 40, generatedAt: now, note: WidgetNote(text: "Sign in", tone: .stale))
        ))
    }
}
