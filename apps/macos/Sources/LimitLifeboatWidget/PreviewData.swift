import Foundation
import LimitLifeboatCore

extension WidgetSnapshot {
    /// Sample accounts for the widget gallery and placeholder before the app
    /// has written a snapshot. Never shown as real data.
    static func preview(now: Date) -> WidgetSnapshot {
        func runway(_ used: [Double], nowX: Double, dryStart: Double? = nil) -> UsageRunway {
            let step = nowX / Double(max(1, used.count - 1))
            let history = used.enumerated().map { UsageRunway.Point(x: Double($0.offset) * step, y: $0.element / 100) }
            let last = history.last ?? UsageRunway.Point(x: nowX, y: 0)
            let end: UsageRunway.Point = dryStart.map { UsageRunway.Point(x: $0, y: 1) }
                ?? UsageRunway.Point(x: 1, y: min(1, last.y + (last.y / max(nowX, 0.01)) * (1 - nowX)))
            return UsageRunway(history: history, nowX: nowX, projectionEnd: end, dryStart: dryStart)
        }
        let hour: TimeInterval = 3600
        return WidgetSnapshot(
            generatedAt: now.addingTimeInterval(-4 * 60),
            accounts: [
                WidgetAccount(
                    id: UUID(), provider: .claude, label: "Work", planLabel: "Max 20x", isActive: true,
                    lastRefreshed: now.addingTimeInterval(-4 * 60),
                    windows: [
                        WidgetWindow(id: "session", kind: .session, label: "Session", usedPercent: 39, resetDate: now.addingTimeInterval(2.5 * hour), riskLevel: .healthy, runway: runway([0, 8, 15, 27, 39], nowX: 0.5)),
                        WidgetWindow(id: "weekly-all", kind: .weekly, label: "Week", usedPercent: 52, resetDate: now.addingTimeInterval(60 * hour), riskLevel: .healthy, runway: runway([0, 10, 22, 35, 52], nowX: 0.65))
                    ]
                ),
                WidgetAccount(
                    id: UUID(), provider: .claude, label: "Personal", planLabel: "Max 5x", isActive: false, isBestNext: true,
                    lastRefreshed: now.addingTimeInterval(-6 * 60),
                    windows: [
                        WidgetWindow(id: "session", kind: .session, label: "Session", usedPercent: 0, resetDate: nil, riskLevel: .healthy),
                        WidgetWindow(id: "weekly-all", kind: .weekly, label: "Week", usedPercent: 18, resetDate: now.addingTimeInterval(120 * hour), riskLevel: .healthy, runway: runway([0, 6, 12, 18], nowX: 0.3))
                    ]
                ),
                WidgetAccount(
                    id: UUID(), provider: .claude, label: "Side project", planLabel: "Pro", isActive: false,
                    lastRefreshed: now.addingTimeInterval(-6 * 60),
                    note: WidgetNote(text: "Week empty in 1d", tone: .warning),
                    windows: [
                        WidgetWindow(id: "session", kind: .session, label: "Session", usedPercent: 92, resetDate: now.addingTimeInterval(1 * hour), riskLevel: .warning, runway: runway([0, 40, 70, 92], nowX: 0.8)),
                        WidgetWindow(id: "weekly-all", kind: .weekly, label: "Week", usedPercent: 88, resetDate: now.addingTimeInterval(70 * hour), riskLevel: .warning, runway: runway([0, 30, 60, 88], nowX: 0.6, dryStart: 0.72))
                    ]
                ),
                WidgetAccount(
                    id: UUID(), provider: .codex, label: "Codex", planLabel: "Pro", isActive: true,
                    lastRefreshed: now.addingTimeInterval(-4 * 60),
                    windows: [
                        WidgetWindow(id: "codex-300", kind: .session, label: "Session", usedPercent: 12, resetDate: now.addingTimeInterval(3 * hour), riskLevel: .healthy, runway: runway([0, 5, 12], nowX: 0.4)),
                        WidgetWindow(id: "codex-10080", kind: .weekly, label: "Week", usedPercent: 27, resetDate: now.addingTimeInterval(96 * hour), riskLevel: .healthy, runway: runway([0, 9, 18, 27], nowX: 0.45))
                    ]
                )
            ]
        )
    }
}
