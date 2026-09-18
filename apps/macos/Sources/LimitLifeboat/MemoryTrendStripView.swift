import Charts
import LimitLifeboatCore
import SwiftUI

/// The optional memory graph's popover form: one slim row with the last 30
/// minutes of memory used, shown whether or not agent sessions are running.
struct MemoryTrendStripView: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        let samples = monitor.trend.samples
        let color = levelColor(monitor.assessment.isActionable ? monitor.assessment.level : .ok)

        HStack(spacing: DS.Spacing.md) {
            Label("Memory", systemImage: "memorychip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Chart(samples, id: \.date) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Used", sample.usedFraction * 100)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(color.opacity(0.14))

                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Used", sample.usedFraction * 100)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(color)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: timeDomain(samples))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 28)

            Text(valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, DS.Spacing.sm)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory used, last 30 minutes")
        .accessibilityValue(valueText)
    }

    private var valueText: String {
        guard let memory = monitor.trend.latestStatus else { return "—" }
        let percent = Int((memory.usedFraction * 100).rounded())
        return "\(MemoryFormatting.bytes(memory.usedBytes)) / \(MemoryFormatting.bytes(memory.totalBytes)) · \(percent)%"
    }

    /// A fixed 30-minute span ending now-ish, so readings scroll in from the
    /// right instead of stretching a minute of data across the whole strip.
    private func timeDomain(_ samples: [MemoryTrendSample]) -> ClosedRange<Date> {
        let end = samples.last?.date ?? Date()
        return end.addingTimeInterval(-MenuBarSparkline.window)...end
    }

    private func levelColor(_ level: MemoryGuardLevel) -> Color {
        switch level {
        case .ok:
            return DS.accent
        case .caution:
            return DS.warning
        case .critical:
            return DS.danger
        }
    }
}
