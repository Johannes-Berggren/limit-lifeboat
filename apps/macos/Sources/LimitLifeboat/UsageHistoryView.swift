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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        ZStack {
            CalmWindowBackground()

            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Usage History")
                            .font(.title2.weight(.semibold))
                        ProviderLabel(text: profile.label, provider: profile.provider)
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
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .calmSurface()
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.lg) {
                                ForEach(latestValues) { value in
                                    HStack(spacing: DS.Spacing.tight) {
                                        Circle()
                                            .fill(seriesColor(for: value.label))
                                            .frame(width: 7, height: 7)
                                        Text(value.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text("\(Int(value.usedPercent.rounded()))%")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                    }
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
                            .symbolSize(14)
                        }
                        .chartForegroundStyleScale(domain: seriesLabels, range: seriesColors)
                        .chartYScale(domain: 0...100)
                        .chartLegend(.hidden)
                        .chartYAxis {
                            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                                AxisGridLine()
                                    .foregroundStyle(Color.primary.opacity(0.06))
                                AxisValueLabel {
                                    if let percent = value.as(Int.self) {
                                        Text("\(percent)%")
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 250)
                        .accessibilityLabel("Usage history for \(profile.label)")
                    }
                    .padding(DS.Spacing.lg)
                    .calmSurface()
                    .animation(reduceMotion ? nil : DS.Motion.standard, value: scope)
                }

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(DS.Spacing.xl)
        }
        .frame(width: 600)
        .frame(minHeight: 420)
        .tint(DS.accent)
    }

    private var seriesLabels: [String] {
        latestValues.map(\.label)
    }

    private var seriesColors: [Color] {
        seriesLabels.indices.map { seriesPalette[$0 % seriesPalette.count] }
    }

    private var seriesPalette: [Color] {
        [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
    }

    private func seriesColor(for label: String) -> Color {
        guard let index = seriesLabels.firstIndex(of: label) else { return DS.accent }
        return seriesPalette[index % seriesPalette.count]
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
