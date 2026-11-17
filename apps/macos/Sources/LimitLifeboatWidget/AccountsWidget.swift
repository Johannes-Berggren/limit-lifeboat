import LimitLifeboatCore
import SwiftUI
import WidgetKit

/// The desktop widget extension. It only reads the snapshot the app writes
/// (see `WidgetSnapshotStore`); it never touches credentials, profiles or the
/// network, and it cannot switch accounts. Clicking it reopens the app.
@main
struct LimitLifeboatWidgets: WidgetBundle {
    var body: some Widget {
        AccountsWidget()
    }
}

struct AccountsWidget: Widget {
    static let kind = "LimitLifeboatAccounts"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: AccountsTimelineProvider()) { entry in
            AccountsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Accounts")
        .description("Session and weekly limits left on every saved account.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AccountsEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has not written a snapshot yet (or it is unreadable).
    let snapshot: WidgetSnapshot?
}

struct AccountsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> AccountsEntry {
        AccountsEntry(date: Date(), snapshot: .preview(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (AccountsEntry) -> Void) {
        let now = Date()
        // The widget gallery shows sample accounts until the app has data.
        let snapshot = Self.load() ?? (context.isPreview ? .preview(now: now) : nil)
        completion(AccountsEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccountsEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.load()
        // The app asks for a reload whenever the numbers change. These extra
        // entries tick the reset countdowns each minute and move staleness and
        // "reset passed" on while it is quiet (or not running); the reload
        // after them re-reads the file.
        let entries = (0...15).map { minutes in
            AccountsEntry(date: now.addingTimeInterval(TimeInterval(minutes * 60)), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func load() -> WidgetSnapshot? {
        let name = Bundle.main.object(forInfoDictionaryKey: WidgetSnapshot.applicationSupportNameInfoKey) as? String
            ?? ApplicationVariant.distribution.applicationSupportDirectoryName
        guard let directory = WidgetSnapshotStore.realApplicationSupportDirectory(named: name) else {
            return nil
        }
        return WidgetSnapshotStore(applicationSupportDirectory: directory).read()
    }
}

// MARK: - Views

struct AccountsWidgetView: View {
    let entry: AccountsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
            switch family {
            case .systemSmall:
                SmallAccountsView(snapshot: snapshot, now: entry.date)
            case .systemLarge:
                ListAccountsView(snapshot: snapshot, now: entry.date, isLarge: true)
            default:
                ListAccountsView(snapshot: snapshot, now: entry.date, isLarge: false)
            }
        } else {
            EmptyAccountsView()
        }
    }
}

private struct EmptyAccountsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lifepreserver.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Limit Lifeboat to see your accounts")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WidgetHeader: View {
    let title: String
    let snapshot: WidgetSnapshot
    let now: Date
    var trailing: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lifepreserver.fill")
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if trailing {
                Text(Self.ageText(since: snapshot.generatedAt, now: now))
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    static func ageText(since date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        return age < 90 ? "Just now" : "\(DurationPhrase.short(age)) ago"
    }
}

/// The medium and large header: the app name and data age on the left, and
/// the two column titles over the gauges so each row can use its label slot
/// for the reset countdown.
private struct ListHeader: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "lifepreserver.fill")
                    .imageScale(.small)
                Text("Limit Lifeboat")
                    .lineLimit(1)
                Text(WidgetHeader.ageText(since: snapshot.generatedAt, now: now))
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Session left")
                .frame(width: ColumnMetrics.width, alignment: .leading)
            Text("Week left")
                .frame(width: ColumnMetrics.width, alignment: .leading)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: Small

struct SmallAccountsView: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        if let account = snapshot.headlineAccount {
            let window = account.headlineWindow
            let state = window.map { GaugeState(window: $0, account: account, now: now) }
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    WidgetHeader(title: account.isActive ? "Active" : account.provider.displayName, snapshot: snapshot, now: now, trailing: false)
                    if let window, !window.resetHasElapsed(asOf: now),
                       let countdown = WidgetResetCountdown.text(until: window.resetDate, now: now) {
                        Label(countdown, systemImage: "arrow.clockwise")
                            .labelStyle(CountdownLabelStyle())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: state?.fillFraction ?? 0)
                        .stroke(state?.color ?? .gray, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text(state?.valueText ?? "–")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                        Text(window.map { "\($0.label.lowercased()) left" } ?? "no reading")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 78, height: 78)
                VStack(spacing: 1) {
                    Text(account.label)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    subtitle(account: account, window: window)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyAccountsView()
        }
    }

    private func subtitle(account: WidgetAccount, window: WidgetWindow?) -> Text {
        if let next = snapshot.bestNext(for: account.provider) {
            return Text("Next: ") + Text(next.label).foregroundColor(.primary)
        }
        if let note = account.note {
            return Text(note.text)
        }
        return Text(account.provider.displayName)
    }
}

// MARK: Medium and large

struct ListAccountsView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let isLarge: Bool

    private var maxRows: Int { isLarge ? 7 : 4 }

    var body: some View {
        let (shown, hidden) = snapshot.accountsForDisplay(limit: maxRows)
        VStack(alignment: .leading, spacing: 0) {
            ListHeader(snapshot: snapshot, now: now)
                .padding(.bottom, isLarge ? 6 : 5)

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, account in
                if isLarge, index == 0 || shown[index - 1].provider != account.provider {
                    Text(account.provider.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                        .padding(.top, index == 0 ? 0 : 6)
                        .padding(.bottom, 4)
                }
                AccountRow(account: account, now: now, showsRunway: isLarge && snapshot.showsUsageCurves, showsNote: isLarge)
                    .padding(.bottom, isLarge ? 7 : 3)
            }
            Spacer(minLength: 0)
            footer(hidden: hidden)
        }
    }

    @ViewBuilder
    private func footer(hidden: Int) -> some View {
        let advice = Provider.allCases.compactMap { provider in
            snapshot.bestNext(for: provider).map { (provider, $0) }
        }.first
        if isLarge, let (provider, next) = advice {
            Divider().padding(.bottom, 6)
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                Text("Best next for \(provider.displayName): ") + Text(next.label).bold().foregroundColor(.primary)
                Spacer(minLength: 0)
                if hidden > 0 { Text("+\(hidden) more") }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if hidden > 0 {
            Text("+\(hidden) more in the app")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private enum ColumnMetrics {
    static let width: CGFloat = 80
}

private struct AccountRow: View {
    let account: WidgetAccount
    let now: Date
    let showsRunway: Bool
    let showsNote: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderIcon(provider: account.provider)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(account.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if account.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Active")
                    }
                }
                subtitle
                    .font(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WindowGauge(window: account.sessionWindow, account: account, now: now, showsRunway: showsRunway)
            WindowGauge(window: account.weeklyWindow, account: account, now: now, showsRunway: showsRunway)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if account.isStale(asOf: now), let refreshed = account.lastRefreshed, account.note == nil {
            Text("Checked \(WidgetHeader.ageText(since: refreshed, now: now))")
                .foregroundStyle(.secondary)
        } else if let note = account.note, showsNote || note.tone != .secondary {
            Text(note.text)
                .foregroundStyle(note.tone.color)
        } else {
            Text(account.planLabel ?? account.provider.displayName)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderIcon: View {
    let provider: Provider

    var body: some View {
        Image(systemName: provider == .claude ? "sparkles" : "terminal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(provider == .claude ? Color.accentColor : Color.secondary)
            .frame(width: 18, height: 18)
            .background(
                (provider == .claude ? Color.accentColor : Color.secondary).opacity(0.16),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .accessibilityLabel(provider.displayName)
    }
}

private struct WindowGauge: View {
    let window: WidgetWindow?
    let account: WidgetAccount
    let now: Date
    let showsRunway: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let window {
                let state = GaugeState(window: window, account: account, now: now)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if window.kind == .weeklyScoped {
                        // The Week column fell back to a model limit; name it.
                        Text(window.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(state.isMuted ? Color.secondary : state.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let countdown = state.countdown {
                        // Beside a model name there is no room for the reset
                        // arrow; the countdown alone still reads as a reset.
                        Label(countdown, systemImage: "arrow.clockwise")
                            .labelStyle(CountdownLabelStyle(showsIcon: window.kind != .weeklyScoped))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityLabel("Resets in \(countdown)")
                    }
                    Spacer(minLength: 1)
                    Text(state.valueText)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(state.valueColor)
                }
                if showsRunway, let runway = window.runway, !state.isMuted {
                    RunwayShape(runway: runway, color: state.color)
                        .frame(height: 14)
                } else {
                    FillBar(fraction: state.fillFraction, color: state.color)
                        .frame(height: 4)
                        .frame(height: showsRunway ? 14 : 4, alignment: .bottom)
                }
            } else {
                Text("–")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer().frame(height: showsRunway ? 14 : 4)
            }
        }
        .frame(width: ColumnMetrics.width)
    }
}

/// How one window draws at a given moment: live, stale, or past its reset.
private struct GaugeState {
    var valueText: String
    var fillFraction: Double
    var color: Color
    var isMuted: Bool
    /// Time until the window resets ("2h 30m"); nil without a reset date
    /// or once it has passed.
    var countdown: String?

    /// The percentage takes the risk colour once a window is in the warning
    /// band or empty, where the bar alone is too short to carry it.
    var valueColor: Color {
        if isMuted { return .secondary }
        return risk == .warning || risk == .depleted ? color : .primary
    }
    private var risk: RiskLevel = .unknown

    init(window: WidgetWindow, account: WidgetAccount, now: Date) {
        countdown = WidgetResetCountdown.text(until: window.resetDate, now: now)
        if window.resetHasElapsed(asOf: now) {
            // The provider has most likely refilled it; say so instead of
            // showing pre-reset numbers as current.
            valueText = "Reset"
            fillFraction = 1
            color = .green.opacity(0.6)
            isMuted = true
            return
        }
        let remaining = window.remainingPercent
        risk = window.riskLevel
        valueText = "\(Int(remaining.rounded()))%"
        fillFraction = remaining / 100
        if account.isStale(asOf: now) {
            color = .secondary
            isMuted = true
        } else {
            color = window.riskLevel.color
            isMuted = false
        }
    }
}

/// A small reset arrow tight against the countdown text.
private struct CountdownLabelStyle: LabelStyle {
    var showsIcon = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            if showsIcon {
                configuration.icon
                    .imageScale(.small)
                    .font(.system(size: 7, weight: .bold))
            }
            configuration.title
                .monospacedDigit()
        }
    }
}

private struct FillBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
    }
}

/// The large widget's version of the app's runway gauge: usage so far this
/// window, the dashed pace line, and a red stretch when the pace runs the
/// quota dry before the reset.
private struct RunwayShape: View {
    let runway: UsageRunway
    let color: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let track = Path(roundedRect: rect, cornerRadius: 4, style: .continuous)
            context.fill(track, with: .color(.primary.opacity(0.07)))
            context.clip(to: track)
            func point(_ p: UsageRunway.Point) -> CGPoint {
                CGPoint(x: size.width * p.x, y: size.height - (size.height - 2) * p.y - 1)
            }
            if let dryStart = runway.dryStart {
                let x = size.width * dryStart
                context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)), with: .color(.red.opacity(0.18)))
            }
            let points = runway.history.map(point)
            guard let first = points.first, let last = points.last else { return }
            var line = Path()
            line.move(to: first)
            for p in points.dropFirst() { line.addLine(to: p) }
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(color.opacity(0.28)))
            context.stroke(line, with: .color(color), lineWidth: 1.4)
            if let end = runway.projectionEnd {
                var projection = Path()
                projection.move(to: last)
                projection.addLine(to: point(end))
                context.stroke(
                    projection,
                    with: .color((runway.dryStart == nil ? color : .red).opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private extension RiskLevel {
    var color: Color {
        switch self {
        case .healthy: return .blue
        case .warning: return .orange
        case .depleted: return .red
        case .stale: return .yellow
        case .unknown: return .gray
        }
    }
}

private extension PresentationTone {
    var color: Color {
        switch self {
        case .secondary: return .secondary
        case .warning: return .orange
        case .stale: return .yellow
        case .success: return .green
        case .danger: return .red
        }
    }
}
