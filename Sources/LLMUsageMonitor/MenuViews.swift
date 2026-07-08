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
        .frame(minWidth: 430, minHeight: 480)
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

            TopUsageSummaryView(
                profiles: state.profiles,
                snapshots: state.snapshots,
                preferredFraction: { state.preferredUsedFraction(for: $0) }
            )

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
        // Highlight the advised switch target only while the active account
        // is actually constrained — a permanent highlight would be noise.
        let activeSnapshot = profiles.first(where: \.isActiveCLI).flatMap { state.snapshots[$0.id] }
        let activeAtRisk = activeSnapshot.map { $0.riskLevel == .warning || $0.riskLevel == .depleted } ?? false
        let advisedID = (provider == .claude && activeAtRisk) ? state.switchAdvice?.bestCandidateID : nil

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
                        estimates: state.burnRateEstimates[profile.id] ?? [:],
                        isAdvisedSwitchTarget: advisedID == profile.id,
                        adviceReason: advisedID == profile.id ? state.switchAdvice?.reason : nil,
                        historyRecords: { state.historyRecords(for: profile) },
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
    let estimates: [String: BurnRateEstimate]
    var isAdvisedSwitchTarget: Bool = false
    var adviceReason: String? = nil
    let historyRecords: () -> [UsageHistoryRecord]
    let switchCLI: () -> Void
    let openDashboard: () -> Void
    let beginCLILogin: () -> Void
    let captureCLI: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void

    @State private var showsRenameAlert = false
    @State private var renameText = ""
    @State private var showsScopedWindows = false
    @State private var showsBillingDetails = false
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header
            gauges
            footer
        }
        .padding(DS.Spacing.cardPadding)
        .cardSurface()
        .alert("Rename \(profile.label)", isPresented: $showsRenameAlert) {
            TextField("Account name", text: $renameText)
            Button("Rename") { rename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showsHistory) {
            UsageHistoryChartView(
                profile: profile,
                records: historyRecords(),
                currentWindows: snapshot?.orderedDisplayWindows ?? []
            )
        }
    }

    // MARK: Row 1 — header

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(riskColor)
                .frame(width: 8, height: 8)

            Text(profile.label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(identityText)

            if profile.isActiveCLI {
                Badge(text: "Active", systemImage: "terminal.fill", color: .green)
                    .help("This account is the current terminal login")
            }

            Spacer(minLength: DS.Spacing.xs)

            if let billingBadge {
                Button {
                    showsBillingDetails = true
                } label: {
                    Badge(text: billingBadge.text, color: billingBadge.color)
                }
                .buttonStyle(.plain)
                .help(billingBadge.help)
            }

            Menu {
                Button("Open Dashboard…") { openDashboard() }
                Button("Log In via Terminal") { beginCLILogin() }
                Button("Save CLI Snapshot Now") { captureCLI() }
                Divider()
                Button("Usage History…") { showsHistory = true }
                Button("Billing Details…") { showsBillingDetails = true }
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
            // Anchored here (not on the conditional badge) so the menu's
            // "Billing Details…" works for healthy accounts with no badge.
            .popover(isPresented: $showsBillingDetails, arrowEdge: .bottom) {
                BillingStatusView(snapshot: snapshot, planLabel: profile.planLabel)
                    .padding(DS.Spacing.md)
                    .frame(width: 300)
            }
        }
    }

    // MARK: Rows 2–3 — window gauges

    @ViewBuilder
    private var gauges: some View {
        let ordered = snapshot?.orderedDisplayWindows ?? []
        let primary = ordered.filter { $0.kind != .weeklyScoped }
        let scoped = ordered.filter { $0.kind == .weeklyScoped }
        let atRiskScoped = scoped.filter { $0.riskLevel == .warning || $0.riskLevel == .depleted }
        let collapsibleScoped = scoped.filter { $0.riskLevel != .warning && $0.riskLevel != .depleted }

        ForEach(primary) { window in
            UsageGauge(window: window, estimate: estimates[window.id])
        }

        if profile.isActiveCLI,
           profile.provider == .claude,
           !ordered.isEmpty,
           !ordered.contains(where: { $0.kind == .session }) {
            Text("Session — not captured on last refresh")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("The last reading predates session-limit support; the next refresh adds it.")
        }

        // A per-model weekly limit that is actually at risk must not hide.
        ForEach(atRiskScoped) { window in
            UsageGauge(window: window, micro: true, estimate: estimates[window.id])
        }

        if !collapsibleScoped.isEmpty {
            if showsScopedWindows {
                ForEach(collapsibleScoped) { window in
                    UsageGauge(window: window, micro: true, estimate: estimates[window.id])
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showsScopedWindows.toggle()
                }
            } label: {
                Label(
                    showsScopedWindows
                        ? "Show less"
                        : "\(collapsibleScoped.count) more weekly \(collapsibleScoped.count == 1 ? "limit" : "limits")",
                    systemImage: showsScopedWindows ? "chevron.up" : "chevron.down"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Row 4 — quiet footer (omitted when empty)

    @ViewBuilder
    private var footer: some View {
        let note = footerNote
        let showsSwitchButton = !profile.isActiveCLI
        if note != nil || showsSwitchButton {
            HStack(spacing: DS.Spacing.sm) {
                if let note {
                    Label(note.text, systemImage: note.icon)
                        .font(.caption)
                        .foregroundStyle(note.color)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if showsSwitchButton {
                    switchButton
                }
            }
        }
    }

    @ViewBuilder
    private var switchButton: some View {
        let resetElapsed = snapshot?.resetHasElapsed() == true
        let highlighted = resetElapsed || isAdvisedSwitchTarget
        Button {
            switchCLI()
        } label: {
            Label(isAdvisedSwitchTarget ? "Best switch" : "Switch", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(highlighted ? .green : nil)
        .disabled(!hasStoredSnapshot)
        .help(switchHelp(resetElapsed: resetElapsed))
    }

    private func switchHelp(resetElapsed: Bool) -> String {
        guard hasStoredSnapshot else {
            return "Log into this account once in the terminal so its credentials can be captured"
        }
        if let adviceReason {
            return adviceReason
        }
        if resetElapsed {
            return "This account's limit window has rolled over — switch the CLI to it for fresh quota"
        }
        return "Switch the CLI to this account's saved credentials"
    }

    private var footerNote: (text: String, icon: String, color: Color)? {
        guard let snapshot else {
            return (
                hasStoredSnapshot
                    ? "Credentials saved — usage appears after switching to it"
                    : "Log in via the terminal to link this account",
                "person.crop.circle.badge.questionmark",
                .secondary
            )
        }

        // The opportunity label stays inactive-only: for the active account a
        // refresh simply confirms the reset, but stale readings deserve a
        // flag on every row — active accounts drift too (sleep, failures).
        if !profile.isActiveCLI, snapshot.resetHasElapsed() {
            return ("Limit window elapsed — likely full quota again", "arrow.counterclockwise.circle", .green)
        }

        if snapshot.isStale() {
            return (
                "Last checked \(snapshot.lastRefreshed.formatted(.relative(presentation: .named)))",
                "clock",
                .secondary
            )
        }

        if snapshot.orderedDisplayWindows.isEmpty, !snapshot.message.isEmpty {
            return (snapshot.message, "info.circle", .secondary)
        }

        return nil
    }

    /// Only noteworthy billing states earn a badge; a healthy subscription
    /// is the assumed default and stays quiet.
    private var billingBadge: (text: String, color: Color, help: String)? {
        switch snapshot?.billingUsageMode {
        case .overLimitPayAsYouGo:
            return ("PAYG", .red, "Included usage appears depleted — extra usage may be billed. Click for details.")
        case .payAsYouGoVisible:
            return ("Credits", .orange, "Credit/pay-as-you-go data found; included usage unclear. Click for details.")
        case .needsLogin:
            return ("Sign in", DS.staleAmber, "Connect or refresh this account before trusting its numbers. Click for details.")
        case .includedSubscription, .includedSubscriptionNearLimit, .unknown, .none:
            return nil
        }
    }

    private var identityText: String {
        var parts: [String] = []
        if let identity = profile.identity {
            if let primary = identity.primaryLabel {
                parts.append(primary)
            }
            if let organization = identity.organization, !organization.isEmpty {
                parts.append(organization)
            }
        }
        if let plan = profile.planLabel, !plan.isEmpty {
            parts.append(plan)
        }
        return parts.isEmpty ? "Not linked to a login yet" : parts.joined(separator: " • ")
    }

    private var riskColor: Color {
        DS.riskColor(snapshot?.riskLevel ?? .unknown)
    }
}

struct TopUsageSummaryView: View {
    let profiles: [AccountProfile]
    let snapshots: [UUID: UsageSnapshot]
    /// Mirrors the menu-bar number so the tile and the title always agree.
    let preferredFraction: (UsageSnapshot) -> Double?

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
                if let caption = windowsCaption(for: snapshot) {
                    Text(caption.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(caption.help)
                } else if let billing = noteworthyBillingBadge(for: snapshot.billingUsageMode) {
                    Badge(text: billing.text, color: billing.color)
                }
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

        guard let usedFraction = preferredFraction(snapshot) else {
            return "–"
        }

        return "\(Int((usedFraction * 100).rounded()))%"
    }

    /// "S 53% · W 8%" — both windows at a glance under the big number.
    private func windowsCaption(for snapshot: UsageSnapshot) -> (text: String, help: String)? {
        var parts: [String] = []
        var helpParts: [String] = []
        if let session = snapshot.window(ofKind: .session) {
            parts.append("S \(Int(session.usedPercent.rounded()))%")
            helpParts.append("\(session.label): \(Int(session.usedPercent.rounded()))% used")
        }
        if let weekly = snapshot.primaryWeeklyWindow {
            parts.append("W \(Int(weekly.usedPercent.rounded()))%")
            helpParts.append("\(weekly.label): \(Int(weekly.usedPercent.rounded()))% used")
        }
        guard !parts.isEmpty else {
            return nil
        }
        return (parts.joined(separator: " · "), helpParts.joined(separator: "\n"))
    }

    private func noteworthyBillingBadge(for mode: BillingUsageMode) -> (text: String, color: Color)? {
        switch mode {
        case .overLimitPayAsYouGo:
            return ("Pay-as-you-go", .red)
        case .payAsYouGoVisible:
            return ("Credits visible", .orange)
        case .needsLogin:
            return ("Needs login", DS.staleAmber)
        case .includedSubscription, .includedSubscriptionNearLimit, .unknown:
            return nil
        }
    }
}

/// Full billing-mode explanation; lives in the badge/menu popover since the
/// card itself only carries a badge for noteworthy modes.
struct BillingStatusView: View {
    let snapshot: UsageSnapshot?
    var planLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if let planLabel, !planLabel.isEmpty {
                Text("Plan: \(planLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            color.opacity(0.10),
            in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
        )
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
/// of these per window (Session, Weekly, …); `micro` is the slimmer variant
/// for secondary per-model windows.
struct UsageGauge: View {
    let window: UsageWindow
    var micro: Bool = false
    var estimate: BurnRateEstimate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: micro ? 2 : 4) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(micro ? .caption2 : .caption.weight(.medium))
                    .foregroundStyle(micro ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer()
                if case .depletesAt(let date) = estimate {
                    Text("~empty \(Self.shortClock(date))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DS.riskColor(.warning))
                        .lineLimit(1)
                        .help("At the current pace this window runs out around \(Self.longClock(date)), before it resets.")
                }
                if let reset = resetText {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(resetHelp ?? reset)
                }
                Text(usageValue)
                    .font(micro ? .caption2.weight(.semibold) : .caption.weight(.semibold))
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
                .animation(.spring(duration: 0.5, bounce: 0.15), value: window.usedFraction)
            }
            .frame(height: micro ? 3 : 6)
        }
    }

    /// Short relative reset ("resets in 3h") from the parsed date; the raw
    /// provider phrasing ("2:50am (Europe/Oslo)") is too long for the row and
    /// moves to the tooltip.
    private var resetText: String? {
        if let date = window.resetDate {
            let remaining = date.timeIntervalSinceNow
            if remaining > 0 {
                return "resets in \(DurationPhrase.short(remaining))"
            }
            return "reset elapsed"
        }
        return window.resetDescription.map { "Resets \($0)" }
    }

    private var resetHelp: String? {
        if let date = window.resetDate {
            return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return window.resetDescription.map { "Resets \($0)" }
    }

    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        let fraction = window.usedFraction
        guard fraction > 0 else {
            return 0
        }
        return max(4, totalWidth * CGFloat(min(fraction, 1)))
    }

    private var usageValue: String {
        "\(Int(window.usedPercent.rounded()))%\(micro ? "" : " used")"
    }

    private var riskColor: Color {
        DS.riskColor(window.riskLevel)
    }

    static func shortClock(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func longClock(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
