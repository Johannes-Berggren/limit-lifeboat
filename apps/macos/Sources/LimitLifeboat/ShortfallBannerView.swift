import LimitLifeboatCore
import SwiftUI

/// Leads the popover when the active account will run a limit dry well before
/// it resets: when, how long the gap is, and the one action that helps most.
struct ShortfallBannerView: View {
    let shortfall: QuotaShortfall
    /// The account a switch would move to, when there is one with room.
    var switchTargetLabel: String?
    var park: () -> Void
    var switchAccount: () -> Void
    var resumeAll: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tint: Color {
        shortfall.stage == .warning ? DS.danger : DS.warning
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(alignment: .top, spacing: DS.Spacing.md) {
                    ZStack {
                        Circle().fill(tint.opacity(0.13))
                        Image(systemName: shortfall.stage == .warning ? "exclamationmark.triangle.fill" : "hourglass.bottomhalf.filled")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(QuotaShortfallText.headline(shortfall, now: context.date))
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(QuotaShortfallText.detail(shortfall))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                RunwaySummary(shortfall: shortfall, tint: tint, now: context.date)

                actions
            }
            .padding(DS.Spacing.cardPadding)
            .background(
                reduceTransparency ? Color(nsColor: .controlBackgroundColor) : tint.opacity(0.06),
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        let suggestion = shortfall.suggestion
        if suggestion != nil || switchTargetLabel != nil || shortfall.parkedCount > 0 {
            HStack(spacing: DS.Spacing.sm) {
                if let switchTargetLabel {
                    Button("Switch to \(switchTargetLabel)", action: switchAccount)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.accent)
                }
                if let suggestion {
                    let title = QuotaShortfallText.parkButtonTitle(suggestion)
                    if switchTargetLabel == nil {
                        Button(title, action: park)
                            .buttonStyle(.borderedProminent)
                            .tint(tint)
                    } else {
                        Button(title, action: park)
                            .buttonStyle(.bordered)
                    }
                }
                if shortfall.parkedCount > 0 {
                    Button("Resume all", action: resumeAll)
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if suggestion != nil {
                    Text("Starred sessions are never parked")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .controlSize(.small)
        }
    }
}

/// ━━━━━━━ ░░░░░░░░░░░░ — time until empty, then the dry stretch: the same story as the gauge's dry
/// stretch, scaled to the time that is left.
private struct RunwaySummary: View {
    let shortfall: QuotaShortfall
    let tint: Color
    let now: Date

    var body: some View {
        let toEmpty = max(0, shortfall.emptyAt.timeIntervalSince(now))
        let toReset = max(1, shortfall.resetAt.timeIntervalSince(now))
        let fraction = CGFloat(min(1, toEmpty / toReset))

        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let split = max(3, proxy.size.width * fraction)
                HStack(spacing: 2) {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: split)
                    Capsule()
                        .fill(DS.danger.opacity(0.16))
                }
            }
            .frame(height: 4)

            HStack {
                Text("empty in \(DurationPhrase.precise(max(60, toEmpty)))")
                    .foregroundStyle(tint)
                Spacer()
                Text("resets in \(DurationPhrase.precise(toReset))")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2.weight(.medium).monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Empty in \(DurationPhrase.precise(max(60, toEmpty))), resets in \(DurationPhrase.precise(toReset))")
    }
}
