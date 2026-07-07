import Charts
import LLMUsageMonitorCore
import SwiftUI

/// Usage-over-time line chart for one account, one series per quota window.
/// Opened from the account card's "…" menu.
struct UsageHistoryChartView: View {
    let profile: AccountProfile
    let records: [UsageHistoryRecord]

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .day

    enum Scope: String, CaseIterable, Identifiable {
        case day = "24 hours"
        case week = "7 days"

        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .day:
                return 24 * 3600
            case .week:
                return 7 * 24 * 3600
            }
        }
    }

    private struct Point: Identifiable {
        let id = UUID()
        let timestamp: Date
        let label: String
        let usedPercent: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage History")
                        .font(.headline)
                    Text(profile.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if points.isEmpty {
                ContentUnavailableView(
                    "No readings yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("History accumulates as usage is refreshed; check back after a few refresh cycles.")
                )
                .frame(minHeight: 220)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used", point.usedPercent)
                    )
                    .foregroundStyle(by: .value("Window", point.label))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text("\(percent)%")
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 460)
    }

    private var points: [Point] {
        let cutoff = Date().addingTimeInterval(-scope.interval)
        return records
            .filter { $0.timestamp >= cutoff }
            .flatMap { record in
                record.windows.map { reading in
                    Point(timestamp: record.timestamp, label: label(for: reading), usedPercent: reading.usedPercent)
                }
            }
    }

    private func label(for reading: UsageWindowReading) -> String {
        switch reading.kind {
        case .session:
            return "Session"
        case .weekly:
            return "Weekly"
        case .weeklyScoped:
            // Readings carry no display label by design; recover a short one
            // from the id ("weekly-fable" → "Weekly (Fable)").
            let scope = reading.id
                .replacingOccurrences(of: "weekly-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            return scope.isEmpty ? "Weekly (scoped)" : "Weekly (\(scope))"
        case .other:
            return reading.id.capitalized
        }
    }
}
