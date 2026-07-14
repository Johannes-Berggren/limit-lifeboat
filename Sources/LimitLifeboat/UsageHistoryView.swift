import Charts
import LimitLifeboatCore
import SwiftUI

/// Usage-over-time line chart for one account, one series per quota window.
/// Opened from the account card's "…" menu.
struct UsageHistoryChartView: View {
    let profile: AccountProfile
    let records: [UsageHistoryRecord]
    /// The account's current windows, for resolving display labels; readings
    /// deliberately store no label (it would defeat history dedupe).
    var currentWindows: [UsageWindow] = []

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
        let timestamp: Date
        let label: String
        let usedPercent: Double

        /// Stable across renders so Swift Charts can diff instead of
        /// rebuilding the whole chart every body evaluation.
        var id: String { "\(label)|\(timestamp.timeIntervalSince1970)" }
    }

    private struct LatestValue: Identifiable {
        let label: String
        let usedPercent: Double
        var id: String { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage History")
                        .font(.title3.weight(.semibold))
                    ProviderLabel(text: profile.label, provider: profile.provider)
                        .font(.caption)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(latestValues) { value in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(value.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("\(Int(value.usedPercent.rounded()))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, DS.Spacing.tight)
                            .background(
                                Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            )
                        }
                    }
                }

                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used", point.usedPercent)
                    )
                    .foregroundStyle(by: .value("Window", point.label))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Used", point.usedPercent)
                    )
                    .foregroundStyle(by: .value("Window", point.label))
                    .symbolSize(16)
                }
                .chartYScale(domain: 0...100)
                .chartLegend(position: .top, alignment: .leading, spacing: DS.Spacing.sm)
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
                .accessibilityLabel("Usage history for \(profile.label)")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 520)
        .frame(minHeight: 360)
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

    private var latestValues: [LatestValue] {
        Dictionary(grouping: points, by: \.label)
            .compactMap { label, values in
                guard let latest = values.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
                return LatestValue(label: label, usedPercent: latest.usedPercent)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func label(for reading: UsageWindowReading) -> String {
        // Prefer the real label from the account's current windows; fall
        // back to reconstructing one from the id for windows that no longer
        // exist ("weekly-fable" → "Weekly (Fable)").
        if let current = currentWindows.first(where: { $0.id == reading.id }) {
            return current.label
        }
        switch reading.kind {
        case .session:
            return "Session"
        case .weekly:
            return "Weekly"
        case .weeklyScoped:
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
