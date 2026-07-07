import LLMUsageMonitorCore
import SwiftUI

struct MenuRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    providerSection(.claude)
                    providerSection(.codex)
                }
                .padding(DS.Spacing.md)
            }

            Divider()

            footer
        }
        .frame(minWidth: 430, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM Usage")
                        .font(.headline)
                    Text(lastRefreshText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let stage = state.refreshStage {
                        Text(stage)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Group {
                        if state.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Refresh usage (⌘R)")
                .accessibilityLabel("Refresh usage")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isRefreshing)
            }

            TopUsageSummaryView(profiles: state.profiles, snapshots: state.snapshots)

            if let update = state.availableUpdate {
                Button {
                    state.openAvailableUpdate()
                } label: {
                    Label("Version \(update.version) is available — download", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.link)
            }
        }
        .padding(DS.Spacing.md)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(state.statusMessage.isEmpty ? "Ready" : state.statusMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Spacer()

            Text("v\(AppInfo.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                state.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit") {
                state.quit()
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .padding(DS.Spacing.md)
        .background(.bar)
    }

    private var lastRefreshText: String {
        let latest = state.snapshots.values.map(\.lastRefreshed).max()
        guard let latest else {
            return "Not refreshed yet"
        }
        return "Updated \(latest.formatted(date: .omitted, time: .shortened))"
    }

    private func providerSection(_ provider: Provider) -> some View {
        let profiles = state.profiles.filter { $0.provider == provider }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderLabel(text: provider.displayName, provider: provider)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    state.addProfile(provider: provider)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a \(provider.displayName) account")
            }

            if profiles.isEmpty {
                emptyProviderCard(provider)
            } else {
                ForEach(profiles) { profile in
                    AccountRowView(
                        profile: profile,
                        snapshot: state.snapshots[profile.id],
                        hasStoredSnapshot: state.hasStoredSnapshot(for: profile),
                        switchCLI: { state.switchCLI(to: profile) },
                        openDashboard: { state.openDashboard(for: profile) },
                        beginCLILogin: { state.beginCLILogin(for: profile) },
                        captureCLI: { state.captureCLISnapshot(for: profile) },
                        rename: { state.renameProfile(profile.id, to: $0) },
                        remove: { state.removeProfile(profile.id) }
                    )
                }
            }
        }
    }

    private func emptyProviderCard(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Run \(provider.loginCommand) in your terminal — the account is registered here automatically on the next refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                state.copyLoginCommand(for: provider)
            } label: {
                Label("Copy login command & open Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .cardSurface()
    }
}

struct AccountRowView: View {
    let profile: AccountProfile
    let snapshot: UsageSnapshot?
    let hasStoredSnapshot: Bool
    let switchCLI: () -> Void
    let openDashboard: () -> Void
    let beginCLILogin: () -> Void
    let captureCLI: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var showsRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(riskColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(profile.label)
                            .font(.system(size: 13, weight: .semibold))
                        if profile.isActiveCLI {
                            Badge(text: "Active terminal", systemImage: "terminal.fill", color: .green)
                        }
                    }

                    Text(identityText)
                        .font(.caption)
                        .foregroundStyle(profile.identity == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                        .help(identityText)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Spacer()

                Menu {
                    Button("Open Dashboard…") { openDashboard() }
                    Button("Log In via Terminal") { beginCLILogin() }
                    Button("Save CLI Snapshot Now") { captureCLI() }
                    Divider()
                    Button("Rename…") {
                        renameText = profile.label
                        showsRenameAlert = true
                    }
                    Button("Remove…", role: .destructive) { remove() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
            }

            if let snapshot, !snapshot.displayWindows.isEmpty {
                ForEach(snapshot.displayWindows) { window in
                    UsageGauge(window: window, compact: true)
                }
            } else {
                UsageGauge(window: nil, compact: true)
            }
            BillingStatusView(snapshot: snapshot, compact: true)

            if let staleness {
                Label(staleness.text, systemImage: staleness.isOpportunity ? "arrow.counterclockwise.circle" : "clock")
                    .font(.caption)
                    .foregroundStyle(staleness.isOpportunity ? Color.green : Color.secondary)
            }

            if !profile.isActiveCLI {
                HStack(spacing: 8) {
                    Button {
                        switchCLI()
                    } label: {
                        Label("Switch CLI to this account", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasStoredSnapshot)
                    .help(
                        hasStoredSnapshot
                            ? "Restore this account's saved CLI credentials"
                            : "Log into this account once in the terminal so its credentials can be captured"
                    )

                    Spacer()
                }
            }
        }
        .padding(DS.Spacing.cardPadding)
        .cardSurface()
        .alert("Rename \(profile.label)", isPresented: $showsRenameAlert) {
            TextField("Account name", text: $renameText)
            Button("Rename") { rename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var staleness: (text: String, isOpportunity: Bool)? {
        guard let snapshot else {
            return nil
        }

        // The opportunity label stays inactive-only: for the active account a
        // refresh simply confirms the reset, but stale readings deserve a
        // flag on every row — active accounts drift too (sleep, failures).
        if !profile.isActiveCLI, snapshot.resetHasElapsed() {
            return ("Limit window elapsed — likely full quota again", true)
        }

        guard snapshot.isStale() else {
            return nil
        }
        return ("Last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))", false)
    }

    private var statusText: String {
        guard let snapshot else {
            return hasStoredSnapshot
                ? "Credentials saved — usage appears after switching to it"
                : "Log in via the terminal to link this account"
        }

        var parts: [String] = []
        if let remaining = snapshot.includedRemaining, let limit = snapshot.includedLimit {
            parts.append("\(format(remaining)) / \(format(limit)) remaining")
        } else if let remaining = snapshot.includedRemaining {
            parts.append("\(format(remaining)) remaining")
        } else {
            parts.append(snapshot.message)
        }

        if let resetDescription = snapshot.resetDescription {
            parts.append("Reset \(resetDescription)")
        }

        return parts.joined(separator: " • ")
    }

    private var identityText: String {
        guard let identity = profile.identity else {
            return "Not linked to a login yet"
        }

        var parts: [String] = []
        if let primary = identity.primaryLabel {
            parts.append(primary)
        }
        if let organization = identity.organization, !organization.isEmpty {
            parts.append(organization)
        }
        return parts.isEmpty ? "Not linked to a login yet" : parts.joined(separator: " • ")
    }

    private var riskColor: Color {
        DS.riskColor(snapshot?.riskLevel ?? .unknown)
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

struct TopUsageSummaryView: View {
    let profiles: [AccountProfile]
    let snapshots: [UUID: UsageSnapshot]

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            summaryTile(provider: .claude)
            summaryTile(provider: .codex)
        }
    }

    private func summaryTile(provider: Provider) -> some View {
        let active = profiles.first { $0.provider == provider && $0.isActiveCLI }
        let snapshot = active.flatMap { snapshots[$0.id] }

        return VStack(alignment: .leading, spacing: 6) {
            ProviderLabel(text: provider.displayName, provider: provider)
                .font(.caption.weight(.semibold))

            if let snapshot {
                Text(summaryValue(for: snapshot))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DS.billingColor(snapshot.billingUsageMode))
                    .contentTransition(.numericText())
                    .animation(.default, value: summaryValue(for: snapshot))
                Badge(
                    text: shortBillingLabel(for: snapshot.billingUsageMode),
                    color: DS.billingColor(snapshot.billingUsageMode)
                )
            } else {
                Text("–")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Badge(text: "No snapshot", color: .gray)
            }

            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "terminal.fill")
                Text(active?.label ?? "No active CLI account")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(active.map { "Active terminal account: \($0.label)" } ?? "No active CLI account detected")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.cardPadding)
        .cardSurface()
    }

    private func summaryValue(for snapshot: UsageSnapshot) -> String {
        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            return "PAYG"
        }

        guard let usedFraction = snapshot.usedFraction else {
            return "–"
        }

        return "\(Int((usedFraction * 100).rounded()))%"
    }

    private func shortBillingLabel(for mode: BillingUsageMode) -> String {
        switch mode {
        case .includedSubscription:
            return "Included subscription"
        case .includedSubscriptionNearLimit:
            return "Included, near limit"
        case .overLimitPayAsYouGo:
            return "Pay-as-you-go"
        case .payAsYouGoVisible:
            return "Credits visible"
        case .needsLogin:
            return "Needs login"
        case .unknown:
            return "Mode unknown"
        }
    }

}

struct BillingStatusView: View {
    let snapshot: UsageSnapshot?
    let compact: Bool

    var body: some View {
        if compact {
            content
        } else {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    color.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(compact ? .tertiary : .secondary)
                .lineLimit(compact ? 2 : 3)
        }
    }

    private var mode: BillingUsageMode {
        snapshot?.billingUsageMode ?? .unknown
    }

    private var title: String {
        switch mode {
        case .includedSubscription:
            return "Within included subscription usage"
        case .includedSubscriptionNearLimit:
            return "Included usage — near limit"
        case .overLimitPayAsYouGo:
            return "Pay-as-you-go — credits likely in use"
        case .payAsYouGoVisible:
            return "Credits visible — included usage unclear"
        case .needsLogin:
            return "Sign in to read billing mode"
        case .unknown:
            return "Billing mode unknown"
        }
    }

    private var detail: String {
        guard let snapshot else {
            return "No usage snapshot yet."
        }

        var parts: [String] = []
        switch mode {
        case .includedSubscription:
            parts.append(includedUsageText(snapshot, prefix: "Included subscription"))
            parts.append("Not over the included limit.")
        case .includedSubscriptionNearLimit:
            parts.append(includedUsageText(snapshot, prefix: "Included subscription"))
            parts.append("Extra credits may apply after the included limit.")
        case .overLimitPayAsYouGo:
            parts.append("Included usage appears depleted or unavailable.")
            parts.append("Extra usage may be billed through credits/pay-as-you-go.")
        case .payAsYouGoVisible:
            parts.append("Credit/pay-as-you-go data was found, but included usage is unclear.")
        case .needsLogin:
            parts.append("Connect or refresh this account before trusting billing mode.")
        case .unknown:
            parts.append(snapshot.message.isEmpty ? "No billing mode signal was recognized." : snapshot.message)
        }

        if let creditStatus = snapshot.creditStatus, !creditStatus.isEmpty {
            parts.append(creditStatus)
        }

        return parts.joined(separator: " ")
    }

    private var icon: String {
        switch mode {
        case .includedSubscription:
            return "checkmark.circle.fill"
        case .includedSubscriptionNearLimit:
            return "exclamationmark.triangle.fill"
        case .overLimitPayAsYouGo:
            return "creditcard.fill"
        case .payAsYouGoVisible:
            return "creditcard"
        case .needsLogin:
            return "person.crop.circle.badge.exclamationmark"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var color: Color {
        DS.billingColor(mode)
    }

    private func includedUsageText(_ snapshot: UsageSnapshot, prefix: String) -> String {
        if let used = snapshot.usedFraction {
            return "\(prefix): \(Int((used * 100).rounded()))% used."
        }
        if let remaining = snapshot.includedRemaining, let limit = snapshot.includedLimit {
            return "\(prefix): \(format(remaining)) / \(format(limit)) remaining."
        }
        return "\(prefix): usage amount recognized."
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

/// Renders one quota window as a labelled progress bar. An account shows one
/// of these per window (Session, Weekly, …); `window == nil` is the empty state.
struct UsageGauge: View {
    let window: UsageWindow?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 8) {
                Text(window?.label ?? "Usage unknown")
                    .font(compact ? .caption.weight(.medium) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let reset = window?.resetDescription {
                    Text("Resets \(reset)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(usageValue)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: usageValue)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(riskColor.gradient)
                        .frame(width: fillWidth(in: proxy.size.width))
                }
                .animation(.spring(duration: 0.5, bounce: 0.15), value: window?.usedFraction)
            }
            .frame(height: compact ? 6 : 10)
        }
    }

    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        guard let fraction = window?.usedFraction, fraction > 0 else {
            return 0
        }
        return max(4, totalWidth * CGFloat(min(fraction, 1)))
    }

    private var usageValue: String {
        guard let window else {
            return "–"
        }
        return "\(Int(window.usedPercent.rounded()))% used"
    }

    private var riskColor: Color {
        DS.riskColor(window?.riskLevel ?? .unknown)
    }
}
