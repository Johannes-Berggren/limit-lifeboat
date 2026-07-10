import LLMUsageMonitorCore
import SwiftUI

struct MenuRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    providerSection(.claude)
                    providerSection(.codex)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, DS.Spacing.sm)
            }
            .background(AmbientUsageBackground())

            Divider()

            footer
        }
        .frame(minWidth: 430, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Text("LLM Usage")
                    .font(.headline)

                Text(lastRefreshText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            if let stage = state.refreshStage {
                Text(stage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .padding(10)
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
        .padding(10)
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
        let advisedID = activeAtRisk ? state.switchAdvice[provider]?.bestCandidateID : nil

        return VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            HStack {
                ProviderLabel(text: provider.displayName, provider: provider)
                    .font(.caption.weight(.semibold))

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
                        refreshState: state.refreshStates[profile.id] ?? .idle,
                        estimates: state.burnRateEstimates[profile.id] ?? [:],
                        adviceReason: advisedID == profile.id ? state.switchAdvice[provider]?.reason : nil,
                        historyRecords: { state.historyRecords(for: profile) },
                        switchCLI: { state.switchCLI(to: profile) },
                        openDashboard: { state.openDashboard(for: profile) },
                        beginCLILogin: { state.beginCLILogin(for: profile) },
                        captureCLI: { state.captureCLISnapshot(for: profile) },
                        rename: { state.renameProfile(profile.id, to: $0) },
                        remove: { state.removeProfile(profile.id) },
                        retry: { state.retryRefresh(for: profile) }
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
        .cardSurface(tint: DS.providerAccent(provider))
    }
}

private struct AmbientUsageBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            ZStack {
                RadialGradient(
                    colors: [.purple.opacity(0.12), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 260
                )
                RadialGradient(
                    colors: [.blue.opacity(0.10), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 280
                )
            }
            .allowsHitTesting(false)
        }
    }
}

struct AccountRowView: View {
    let profile: AccountProfile
    let snapshot: UsageSnapshot?
    let hasStoredSnapshot: Bool
    var refreshState: AccountRefreshState = .idle
    let estimates: [String: BurnRateEstimate]
    /// Non-nil exactly when this account is the advised switch target.
    var adviceReason: String? = nil
    let historyRecords: () -> [UsageHistoryRecord]
    let switchCLI: () -> Void
    let openDashboard: () -> Void
    let beginCLILogin: () -> Void
    let captureCLI: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    var retry: () -> Void = {}

    @State private var showsRenameAlert = false
    @State private var renameText = ""
    @State private var showsScopedWindows = false
    @State private var showsBillingDetails = false
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            header
            gauges
            statusStrip
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, DS.Spacing.tight)
        .cardSurface(tint: DS.providerAccent(profile.provider))
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
                .layoutPriority(1)

            Text(identityText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(identityText)

            if profile.isActiveCLI {
                Badge(text: "Active", systemImage: "terminal.fill", color: .green)
                    .help("This account is the current terminal login")
            }

            Spacer(minLength: 0)

            if let billingBadge {
                Button {
                    showsBillingDetails = true
                } label: {
                    Badge(text: billingBadge.text, color: billingBadge.color)
                }
                .buttonStyle(.plain)
                .help(billingBadge.help)
            }

            if !profile.isActiveCLI {
                switchButton
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

    // MARK: Row 2 — compact window gauges

    @ViewBuilder
    private var gauges: some View {
        let ordered = snapshot?.orderedDisplayWindows ?? []
        let primary = ordered.filter { $0.kind != .weeklyScoped }
        let scoped = ordered.filter { $0.kind == .weeklyScoped }
        let atRiskScoped = scoped.filter { $0.riskLevel == .warning || $0.riskLevel == .depleted }
        let collapsibleScoped = scoped.filter { $0.riskLevel != .warning && $0.riskLevel != .depleted }

        let visible = primary + atRiskScoped + (showsScopedWindows ? collapsibleScoped : [])

        if !visible.isEmpty {
            LazyVGrid(columns: gaugeColumns, alignment: .leading, spacing: DS.Spacing.tight) {
                ForEach(visible) { window in
                    UsageGauge(window: window, estimate: estimates[window.id])
                }
            }
        }

        if needsSessionCaptureNote || !collapsibleScoped.isEmpty {
            HStack(spacing: DS.Spacing.sm) {
                if needsSessionCaptureNote {
                    Label("Session not captured", systemImage: "clock.badge.questionmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("The last reading predates session-limit support; the next refresh adds it.")
                }

                Spacer(minLength: 0)

                if !collapsibleScoped.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showsScopedWindows.toggle()
                        }
                    } label: {
                        Label(
                            showsScopedWindows ? "Show less" : "+\(collapsibleScoped.count) limits",
                            systemImage: showsScopedWindows ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(showsScopedWindows ? "Hide healthy model-specific weekly limits" : "Show healthy model-specific weekly limits")
                }
            }
        }
    }

    private var gaugeColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: DS.Spacing.sm, alignment: .top),
            count: 3
        )
    }

    private var needsSessionCaptureNote: Bool {
        let ordered = snapshot?.orderedDisplayWindows ?? []
        return profile.isActiveCLI
            && profile.provider == .claude
            && !ordered.isEmpty
            && !ordered.contains(where: { $0.kind == .session })
    }

    // MARK: Actionable status strip (omitted for ordinary accounts)

    @ViewBuilder
    private var statusStrip: some View {
        // A failed refresh takes precedence over the quiet note: the account is
        // showing stale or absent numbers for a reason the user can act on.
        let problem = refreshProblem
        let note = problem == nil ? footerNote : nil
        if problem != nil || note != nil {
            HStack(spacing: DS.Spacing.sm) {
                if let problem {
                    Label(problem.text, systemImage: problem.icon)
                        .font(.caption)
                        .foregroundStyle(problem.color)
                        .lineLimit(2)
                        .help(problem.help)
                    if problem.showsRetry {
                        Spacer(minLength: 0)
                        Button("Retry") { retry() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                } else if let note {
                    Label(note.text, systemImage: note.icon)
                        .font(.caption)
                        .foregroundStyle(note.color)
                        .lineLimit(2)
                        .help(note.text)
                }

            }
            .lineLimit(1)
        }
    }

    /// A visible, actionable failure from the last refresh, or nil when the
    /// account refreshed fine (or hasn't been tried).
    private var refreshProblem: (text: String, icon: String, color: Color, help: String, showsRetry: Bool)? {
        switch refreshState {
        case .idle, .refreshing, .ok:
            return nil
        case .readFailed(let reason):
            return ("Couldn't refresh", "exclamationmark.triangle", .orange, reason, true)
        case .needsLogin:
            // Only worth surfacing here for the active account or one that
            // otherwise looks linked; the empty-state note already covers a
            // brand-new account with no snapshot.
            guard snapshot != nil || profile.isActiveCLI else {
                return nil
            }
            return (
                "Not linked — log in to track usage",
                "person.crop.circle.badge.questionmark",
                .secondary,
                "Use the … menu → Log In via Terminal to link this account.",
                false
            )
        case .keychainLocked:
            return (
                "Keychain access needed",
                "lock",
                DS.staleAmber,
                "macOS denied access to this account's saved credentials. Tap Retry to grant access.",
                true
            )
        }
    }

    @ViewBuilder
    private var switchButton: some View {
        let resetElapsed = snapshot?.resetHasElapsed() == true
        let isAdvised = adviceReason != nil
        let highlighted = resetElapsed || isAdvised
        Button {
            switchCLI()
        } label: {
            Label(isAdvised ? "Best" : "Switch", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.medium))
        }
        .compactGlassButton(tint: highlighted ? .green : nil)
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
            let text: String
            if !hasStoredSnapshot {
                text = "Log in via the terminal to link this account"
            } else if profile.isActiveCLI {
                // Already the active login, so "switch to it" would be wrong.
                // Codex has no inactive usage source — its numbers come from
                // the CLI's own session logs, so the row stays blank until
                // this account actually runs a turn.
                text = profile.provider == .codex
                    ? "Active — usage appears after you run codex"
                    : "Active — usage appears on the next refresh"
            } else {
                text = "Credentials saved — usage appears after switching to it"
            }
            return (text, "person.crop.circle.badge.questionmark", .secondary)
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

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Spacing.tight) {
                ProviderLabel(text: provider.displayName, provider: provider)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 0)

                Text(snapshot.map(summaryValue) ?? "–")
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(snapshot.map { DS.billingColor($0.billingUsageMode) } ?? .secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: snapshot.map(summaryValue) ?? "–")
            }

            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "terminal.fill")
                Text(active?.label ?? "No active CLI account")
                    .lineLimit(1)

                Spacer(minLength: DS.Spacing.xs)

                if let snapshot, let caption = windowsCaption(for: snapshot) {
                    Text(caption.text)
                        .monospacedDigit()
                        .lineLimit(1)
                        .help(caption.help)
                } else if let snapshot, let billing = noteworthyBillingBadge(for: snapshot.billingUsageMode) {
                    Text(billing.text)
                        .foregroundStyle(billing.color)
                        .lineLimit(1)
                } else if snapshot == nil {
                    Text("No snapshot")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(active.map { "Active terminal account: \($0.label)" } ?? "No active CLI account detected")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, DS.Spacing.tight)
        .cardSurface(tint: DS.providerAccent(provider))
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

/// A compact quota column. Reset and burn-rate details stay available in the
/// tooltip so three independent windows can remain legible on one card row.
struct UsageGauge: View {
    let window: UsageWindow
    var estimate: BurnRateEstimate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.Spacing.xs) {
                Text(window.label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .help(window.label)

                Spacer(minLength: 0)

                if case .depletesAt = estimate {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(DS.riskColor(.warning))
                }

                Text(usageValue)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: usageValue)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(riskColor.gradient)
                        .frame(width: fillWidth(in: proxy.size.width))
                }
                .animation(.spring(duration: 0.5, bounce: 0.15), value: window.usedFraction)
            }
            .frame(height: 4)
        }
        .help(gaugeHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue("\(usageValue) used")
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
        "\(Int(window.usedPercent.rounded()))%"
    }

    private var gaugeHelp: String {
        var lines = [window.label, "\(usageValue) used"]
        if let resetHelp {
            lines.append(resetHelp)
        }
        if case .depletesAt(let date) = estimate {
            lines.append("At the current pace, this limit runs out around \(Self.longClock(date)) before it resets.")
        }
        return lines.joined(separator: "\n")
    }

    private var riskColor: Color {
        DS.riskColor(window.riskLevel)
    }

    static func longClock(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

#if DEBUG
struct AccountCardPreviewGallery: View {
    private let now = Date()

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.tight) {
                previewRow(
                    id: 1,
                    label: "Work",
                    provider: .claude,
                    active: true,
                    windows: [
                        window("session", .session, "Session", 32, .healthy),
                        window("weekly", .weekly, "Weekly", 57, .healthy)
                    ]
                )

                previewRow(
                    id: 2,
                    label: "Personal Max",
                    provider: .claude,
                    windows: [
                        window("session", .session, "Session", 82, .warning),
                        window("weekly", .weekly, "Weekly", 74, .healthy),
                        window("opus", .weeklyScoped, "Opus", 94, .warning)
                    ],
                    risk: .warning,
                    estimates: ["opus": .depletesAt(now.addingTimeInterval(2 * 3600))]
                )

                previewRow(
                    id: 3,
                    label: "Codex Team",
                    provider: .codex,
                    windows: [
                        window("codex-session", .session, "5 hour", 100, .depleted),
                        window("codex-weekly", .weekly, "Weekly", 91, .warning)
                    ],
                    risk: .depleted,
                    payAsYouGoState: .enabledActive
                )

                previewRow(
                    id: 4,
                    label: "Travel account with a long name",
                    provider: .codex,
                    windows: [window("weekly", .weekly, "Weekly", 41, .stale)],
                    risk: .stale,
                    lastRefreshed: now.addingTimeInterval(-2 * 3600)
                )

                previewRow(
                    id: 5,
                    label: "New account",
                    provider: .claude,
                    hasSnapshot: false,
                    hasStoredSnapshot: false
                )

                previewRow(
                    id: 6,
                    label: "Research",
                    provider: .claude,
                    windows: [
                        window("session", .session, "Session", 28, .healthy),
                        window("weekly", .weekly, "All models", 62, .healthy),
                        window("opus", .weeklyScoped, "Opus", 88, .warning),
                        window("sonnet", .weeklyScoped, "Sonnet", 34, .healthy),
                        window("haiku", .weeklyScoped, "Haiku", 11, .healthy)
                    ],
                    risk: .warning
                )
            }
            .padding(10)
        }
        .background(AmbientUsageBackground())
        .frame(width: 460, height: 560)
    }

    @ViewBuilder
    private func previewRow(
        id: Int,
        label: String,
        provider: Provider,
        active: Bool = false,
        windows: [UsageWindow] = [],
        risk: RiskLevel = .healthy,
        estimates: [String: BurnRateEstimate] = [:],
        payAsYouGoState: PayAsYouGoState? = nil,
        lastRefreshed: Date? = nil,
        hasSnapshot: Bool = true,
        hasStoredSnapshot: Bool = true
    ) -> some View {
        let accountID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
        let profile = AccountProfile(
            id: accountID,
            provider: provider,
            label: label,
            planLabel: provider == .claude ? "Max" : "Team",
            identity: AccountIdentity(
                email: "account\(id)@example.com",
                organization: id.isMultiple(of: 2) ? "Acme" : nil,
                source: .manual
            ),
            isActiveCLI: active
        )
        let snapshot = hasSnapshot ?
            UsageSnapshot(
                accountID: accountID,
                provider: provider,
                windows: windows,
                includedRemaining: max(0, 100 - (windows.map(\.usedPercent).max() ?? 0)),
                includedLimit: 100,
                riskLevel: risk,
                source: "Preview",
                lastRefreshed: lastRefreshed ?? now,
                parseConfidence: .high,
                payAsYouGoState: payAsYouGoState
            )
            : nil

        AccountRowView(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: hasStoredSnapshot,
            estimates: estimates,
            historyRecords: { [] },
            switchCLI: {},
            openDashboard: {},
            beginCLILogin: {},
            captureCLI: {},
            rename: { _ in },
            remove: {}
        )
    }

    private func window(
        _ id: String,
        _ kind: UsageWindowKind,
        _ label: String,
        _ usedPercent: Double,
        _ risk: RiskLevel
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetDate: now.addingTimeInterval(4 * 3600),
            riskLevel: risk
        )
    }
}

#Preview("Compact account card states") {
    AccountCardPreviewGallery()
}
#endif
