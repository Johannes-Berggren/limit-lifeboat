import LimitLifeboatCore
import SwiftUI

struct MenuRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    providerSection(.claude)
                    providerSection(.codex)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.md)
            }
            .background(AmbientUsageBackground())

            Divider()

            footer
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("LLM Usage")
                        .font(.headline)
                    Text(lastRefreshText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                snapshots: state.snapshots
            )

            if let update = state.availableUpdate {
                Button {
                    state.openAvailableUpdate()
                } label: {
                    Label("Version \(update.version) is available — download", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.link)
            } else if let stage = state.refreshStage {
                Label(stage, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.Spacing.md)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            if !state.statusMessage.isEmpty {
                Label(state.statusMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

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
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
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
        let providerProfiles = state.profiles.filter { $0.provider == provider }
        // The repository order stays stable within each group; only lift the
        // active terminal account above its inactive siblings.
        let profiles = AccountProfileOrdering.activeFirst(providerProfiles)
        // Highlight the advised switch target only while the active account
        // is actually constrained — a permanent highlight would be noise.
        let activeSnapshot = profiles.first(where: \.isActiveCLI).flatMap { state.snapshots[$0.id] }
        let activeAtRisk = activeSnapshot.map { $0.riskLevel == .warning || $0.riskLevel == .depleted } ?? false
        let advisedID = activeAtRisk ? state.switchAdvice[provider]?.bestCandidateID : nil

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                ProviderLabel(text: provider.displayName, provider: provider)
                    .font(.subheadline.weight(.semibold))

                Text("\(profiles.count) \(profiles.count == 1 ? "account" : "accounts")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    state.addProfile(provider: provider)
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Add a \(provider.displayName) account")
            }

            if profiles.isEmpty {
                emptyProviderCard(provider)
            } else {
                ForEach(profiles) { profile in
                    let storedStatus = state.storedSnapshotStatus(for: profile)
                    AccountRowView(
                        profile: profile,
                        snapshot: state.snapshots[profile.id],
                        hasStoredSnapshot: storedStatus == .present,
                        refreshState: storedStatus == .locked
                            ? .keychainLocked
                            : (state.refreshStates[profile.id] ?? .idle),
                        estimates: state.burnRateEstimates[profile.id] ?? [:],
                        adviceReason: advisedID == profile.id ? state.switchAdvice[provider]?.reason : nil,
                        showOrganizationName: settings.showOrganizationNames,
                        historyRecords: { state.historyRecords(for: profile) },
                        switchCLI: {
                            Task { await state.switchCLI(to: profile) }
                        },
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
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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
            .compactGlassButton(tint: DS.providerAccent(provider))
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
                    colors: [.purple.opacity(0.055), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 260
                )
                RadialGradient(
                    colors: [.blue.opacity(0.045), .clear],
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
    var showOrganizationName: Bool = true
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
    @State private var showsBillingDetails = false
    @State private var showsHistory = false

    private var presentation: AccountRowPresentation {
        AccountRowPresentation(
            profile: profile,
            snapshot: snapshot,
            hasStoredSnapshot: hasStoredSnapshot,
            refreshState: refreshState,
            adviceReason: adviceReason,
            showOrganizationName: showOrganizationName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            header
            gauges
            statusStrip
        }
        .padding(DS.Spacing.cardPadding)
        .cardSurface(
            tint: DS.providerAccent(profile.provider),
            isEmphasized: profile.isActiveCLI
        )
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
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.tight) {
                Circle()
                    .fill(DS.riskColor(presentation.riskLevel))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)

                Text(profile.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)

                if profile.isActiveCLI {
                    Badge(text: "Active", systemImage: "terminal.fill", color: .green)
                        .help("This account is the current terminal login")
                }

                if let billingBadge = presentation.billingBadge {
                    Button {
                        showsBillingDetails = true
                    } label: {
                        Badge(text: billingBadge.text, color: DS.presentationColor(billingBadge.tone))
                    }
                    .buttonStyle(.plain)
                    .help(billingBadge.help)
                }

                Spacer(minLength: 0)

                if !profile.isActiveCLI && presentation.highlightsSwitch && hasStoredSnapshot {
                    switchButton
                }

                actionsMenu
            }

            Text(presentation.identityText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(presentation.identityText)
                .padding(.leading, 15)
        }
    }

    private var actionsMenu: some View {
        Menu {
            if !profile.isActiveCLI && (!presentation.highlightsSwitch || !hasStoredSnapshot) {
                Button("Switch CLI to This Account", systemImage: "arrow.triangle.2.circlepath") {
                    switchCLI()
                }
                .disabled(!hasStoredSnapshot)
                Divider()
            }
            Button("Open Dashboard…") { openDashboard() }
            Button("Log In via Terminal") { beginCLILogin() }
            if profile.isActiveCLI {
                Button("Save CLI Snapshot Now") { captureCLI() }
            }
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

    // MARK: Row 2 — compact window gauges

    @ViewBuilder
    private var gauges: some View {
        let groups = presentation.gauges

        if !groups.visible.isEmpty {
            LazyVGrid(columns: gaugeColumns, alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(groups.visible) { window in
                    UsageGauge(window: window, estimate: estimates[window.id])
                }
            }
        }

        // When an inactive account's windows have all rolled over, the gauges
        // above are the last reading from *before* the reset — flag them so the
        // stale bars don't contradict the green "quota restored" note below.
        if groups.showsPreResetNote, let last = snapshot?.lastRefreshed {
            Label(
                "Last reading before reset — checked \(last.formatted(.relative(presentation: .named)))",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if groups.needsSessionCaptureNote {
            HStack(spacing: DS.Spacing.sm) {
                Label("Session not captured", systemImage: "clock.badge.questionmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("The last reading predates session-limit support; the next refresh adds it.")
            }
        }
    }

    private var gaugeColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 118), spacing: DS.Spacing.md, alignment: .top)]
    }

    // MARK: Actionable status strip (omitted for ordinary accounts)

    @ViewBuilder
    private var statusStrip: some View {
        // A failed refresh takes precedence over the quiet note: the account is
        // showing stale or absent numbers for a reason the user can act on.
        let problem = presentation.refreshProblem
        let note = problem == nil ? presentation.footerNote : nil
        if problem != nil || note != nil {
            HStack(spacing: DS.Spacing.sm) {
                if let problem {
                    Label(problem.text, systemImage: problem.icon)
                        .font(.caption)
                        .foregroundStyle(DS.presentationColor(problem.tone))
                        .lineLimit(2)
                        .help(problem.help)
                    if let actionTitle = problem.action.title {
                        Spacer(minLength: 0)
                        Button(actionTitle) {
                            switch problem.action {
                            case .none:
                                break
                            case .retry:
                                retry()
                            case .login:
                                beginCLILogin()
                            }
                        }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                } else if let note {
                    Label(note.text, systemImage: note.icon)
                        .font(.caption)
                        .foregroundStyle(DS.presentationColor(note.tone))
                        .lineLimit(2)
                        .help(note.help)
                }

            }
            .lineLimit(2)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.tight)
            .background(
                (problem.map { DS.presentationColor($0.tone) }
                    ?? note.map { DS.presentationColor($0.tone) }
                    ?? Color.secondary).opacity(0.08),
                in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            )
        }
    }

    @ViewBuilder
    private var switchButton: some View {
        Button {
            switchCLI()
        } label: {
            Label(presentation.switchTitle == "Best" ? "Best switch" : presentation.switchTitle,
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.medium))
        }
        .compactGlassButton(tint: presentation.highlightsSwitch ? .green : nil)
        .disabled(!hasStoredSnapshot)
        .help(presentation.switchHelp)
    }
}

struct TopUsageSummaryView: View {
    let profiles: [AccountProfile]
    let snapshots: [UUID: UsageSnapshot]

    var body: some View {
        HStack(spacing: 0) {
            summarySegment(provider: .claude)

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1, height: 34)
                .padding(.horizontal, DS.Spacing.xs)

            summarySegment(provider: .codex)
        }
        .padding(.vertical, DS.Spacing.xs)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    private func summarySegment(provider: Provider) -> some View {
        let active = profiles.first { $0.provider == provider && $0.isActiveCLI }
        let snapshot = active.flatMap { snapshots[$0.id] }

        return HStack(spacing: DS.Spacing.sm) {
            Image(systemName: DS.providerSymbol(provider))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.providerAccent(provider))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(provider.displayName)
                        .font(.caption.weight(.semibold))
                    Text(snapshot.map(summaryValue) ?? "–")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(snapshot.map { DS.billingColor($0.billingUsageMode) } ?? .secondary)
                        .contentTransition(.numericText())
                        .animation(.default, value: snapshot.map(summaryValue) ?? "–")
                }

                Text(summaryDetail(active: active, snapshot: snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(summaryHelp(active: active, snapshot: snapshot))
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.sm)
    }

    private func summaryDetail(active: AccountProfile?, snapshot: UsageSnapshot?) -> String {
        guard let active else { return "No active CLI account" }
        if let snapshot, let caption = windowsCaption(for: snapshot) {
            return "\(active.label)  ·  \(caption.text)"
        }
        if let snapshot, let billing = noteworthyBillingBadge(for: snapshot.billingUsageMode) {
            return "\(active.label)  ·  \(billing.text)"
        }
        return "\(active.label)  ·  No snapshot"
    }

    private func summaryHelp(active: AccountProfile?, snapshot: UsageSnapshot?) -> String {
        guard let active else { return "No active CLI account detected" }
        var lines = ["Active terminal account: \(active.label)"]
        if let snapshot, let caption = windowsCaption(for: snapshot) {
            lines.append(caption.help)
        }
        return lines.joined(separator: "\n")
    }

    private func summaryValue(for snapshot: UsageSnapshot) -> String {
        guard let usedFraction = snapshot.primaryConstrainedWindow?.usedFraction else {
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
        if let weekly = snapshot.window(ofKind: .weekly) {
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
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
                .frame(height: 6)

                if let resetText = UsageResetTiming.compactText(
                    resetDate: window.resetDate,
                    resetDescription: window.resetDescription,
                    now: context.date
                ) {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(window.resetHasElapsed(asOf: context.date) ? .secondary : .tertiary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .help(gaugeHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.label)
            .accessibilityValue(accessibilityValue(now: context.date))
        }
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

    private func accessibilityValue(now: Date) -> String {
        var parts = ["\(usageValue) used"]
        if let resetText = UsageResetTiming.compactText(
            resetDate: window.resetDate,
            resetDescription: window.resetDescription,
            now: now
        ) {
            parts.append(resetText)
        }
        return parts.joined(separator: ", ")
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
        .frame(width: 480, height: 620)
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

private struct AccountCardPreviewGalleryPreviews: PreviewProvider {
    static var previews: some View {
        AccountCardPreviewGallery()
            .previewDisplayName("Compact account card states")
    }
}
#endif
