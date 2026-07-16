import LimitLifeboatCore
import SwiftUI

struct MenuRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: AppUpdater
    @State private var expandedAccounts: [Provider: UUID] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CalmWindowBackground()

            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                        providerSection(.claude)
                        providerSection(.codex)
                    }
                    .padding(.horizontal, DS.Spacing.xl)
                    .padding(.vertical, DS.Spacing.md)
                }

                footer
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .tint(DS.accent)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DS.accent.opacity(0.11))
                Image(systemName: "lifepreserver.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 1) {
                    Text("Limit Lifeboat")
                        .font(.system(size: 17, weight: .semibold))
                    Text("LLM usage · \(headerDetail(now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let version = updater.availableVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DS.accent)
                .help("Install Limit Lifeboat \(version)")
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

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
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Refresh usage (⌘R)")
            .accessibilityLabel("Refresh usage")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.isRefreshing)
        }
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.top, DS.Spacing.lg)
        .padding(.bottom, DS.Spacing.sm)
        .animation(reduceMotion ? nil : DS.Motion.quick, value: state.isRefreshing)
        .animation(reduceMotion ? nil : DS.Motion.quick, value: updater.availableVersion)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Group {
                if state.statusMessage.isEmpty {
                    Text("Usage data updates automatically.")
                } else {
                    Label(state.statusMessage, systemImage: "info.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .contentTransition(.opacity)

            Spacer(minLength: DS.Spacing.md)

            Button {
                state.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 20, height: 20)
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
        .padding(.horizontal, DS.Spacing.xl)
        .padding(.vertical, DS.Spacing.md)
        .background(.bar)
        .animation(reduceMotion ? nil : DS.Motion.quick, value: state.statusMessage)
    }

    private func headerDetail(now: Date) -> String {
        if let stage = state.refreshStage {
            return stage
        }
        let latest = state.snapshots.values.map(\.lastRefreshed).max()
        guard let latest else {
            return "Not refreshed yet"
        }
        if abs(now.timeIntervalSince(latest)) < 30 {
            return "Updated just now"
        }
        return "Updated \(latest.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }

    private func expansionBinding(for profile: AccountProfile) -> Binding<Bool> {
        Binding(
            get: { expandedAccounts[profile.provider] == profile.id },
            set: { isExpanded in
                if isExpanded {
                    expandedAccounts[profile.provider] = profile.id
                } else if expandedAccounts[profile.provider] == profile.id {
                    expandedAccounts[profile.provider] = nil
                }
            }
        )
    }

    private func providerSection(_ provider: Provider) -> some View {
        let providerProfiles = state.profiles.filter { $0.provider == provider }
        let activeSnapshot = providerProfiles.first(where: \.isActiveCLI).flatMap { state.snapshots[$0.id] }
        let activeAtRisk = activeSnapshot.map { $0.riskLevel == .warning || $0.riskLevel == .depleted } ?? false
        let advisedID = activeAtRisk ? state.switchAdvice[provider]?.bestCandidateID : nil
        let profiles = AccountProfileOrdering.activeThenRecommended(
            providerProfiles,
            recommendedID: advisedID
        )
        let activeProfile = profiles.first(where: \.isActiveCLI)

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                ProviderLabel(text: provider.displayName, provider: provider)
                    .font(.system(size: 14, weight: .semibold))

                Text("\(profiles.count) \(profiles.count == 1 ? "account" : "accounts")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                if !profiles.isEmpty {
                    Button {
                        state.addProfile(provider: provider)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a \(provider.displayName) account")
                }
            }

            if profiles.isEmpty {
                emptyProviderCard(provider)
            } else {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    let storedStatus = state.storedSnapshotStatus(for: profile)

                    if index == 1,
                       profile.id == advisedID,
                       let activeProfile {
                        SwitchHandoffButton(
                            from: activeProfile,
                            to: profile,
                            reason: state.switchAdvice[provider]?.reason,
                            action: { await state.switchCLI(to: profile) }
                        )
                    }

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
                        isExpanded: expansionBinding(for: profile),
                        historyRecords: { state.historyRecords(for: profile) },
                        switchCLI: {
                            Task { await state.switchCLI(to: profile) }
                        },
                        openDashboard: { state.openDashboard(for: profile) },
                        beginCLILogin: { state.beginCLILogin(for: profile, activateAfterLogin: true) },
                        beginCLILoginWithoutSwitching: { state.beginCLILogin(for: profile, activateAfterLogin: false) },
                        captureCLI: { state.captureCLISnapshot(for: profile) },
                        rename: { state.renameProfile(profile.id, to: $0) },
                        remove: { state.removeProfile(profile.id) },
                        retry: { state.retryRefresh(for: profile) }
                    )
                }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: profiles.map(\.id))
    }

    private func emptyProviderCard(_ provider: Provider) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("No accounts connected")
                    .font(.system(size: 13, weight: .medium))
                Text("Connect through Terminal to start tracking usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                state.copyLoginCommand(for: provider)
            } label: {
                Text("Connect")
            }
            .compactGlassButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.cardPadding)
        .cardSurface()
        .help("Runs \(provider.loginCommand) in Terminal")
    }
}

private struct SwitchHandoffButton: View {
    let from: AccountProfile
    let to: AccountProfile
    let reason: String?
    let action: () async -> Bool

    @State private var isSwitching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            Button {
                Task {
                    isSwitching = true
                    _ = await action()
                    isSwitching = false
                }
            } label: {
                HStack(spacing: DS.Spacing.tight) {
                    if isSwitching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(isSwitching ? "Switching…" : "Switch to \(to.label)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(DS.accent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.tight)
                .background(DS.accent.opacity(0.08), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(DS.accent.opacity(0.16), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .disabled(isSwitching)
            .help(reason ?? "Switch the CLI from \(from.label) to \(to.label)")
            .accessibilityLabel("Switch \(from.provider.displayName) CLI from \(from.label) to \(to.label)")

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.vertical, -2)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .animation(reduceMotion ? nil : DS.Motion.standard, value: isSwitching)
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
    @Binding var isExpanded: Bool
    let historyRecords: () -> [UsageHistoryRecord]
    let switchCLI: () -> Void
    let openDashboard: () -> Void
    let beginCLILogin: () -> Void
    /// Re-authenticate this account without changing the active account. Only
    /// meaningful for non-active rows; the plain `beginCLILogin` activates.
    var beginCLILoginWithoutSwitching: () -> Void = {}
    let captureCLI: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    var retry: () -> Void = {}

    @State private var showsRenameAlert = false
    @State private var renameText = ""
    @State private var showsBillingDetails = false
    @State private var showsHistory = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            gauges

            if isExpanded && hasExpandableDetails {
                expandedDetails
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            statusStrip
        }
        .padding(DS.Spacing.cardPadding)
        .cardSurface(
            tint: profile.isActiveCLI ? DS.accent : nil,
            isEmphasized: profile.isActiveCLI,
            isHovered: isHovered
        )
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: isExpanded)
        .animation(reduceMotion ? nil : DS.Motion.quick, value: isHovered)
        .accessibilityActions {
            if hasExpandableDetails {
                Button(isExpanded ? "Collapse usage details" : "Expand usage details") {
                    isExpanded.toggle()
                }
            }
        }
        .onChange(of: hasExpandableDetails) { _, hasDetails in
            if !hasDetails {
                isExpanded = false
            }
        }
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
                    Badge(text: "Active", color: DS.accent)
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

                actionsMenu

                if hasExpandableDetails {
                    Button {
                        withAnimation(reduceMotion ? nil : DS.Motion.standard) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide usage details" : "Show usage details")
                    .accessibilityLabel(isExpanded ? "Hide usage details" : "Show usage details")
                }
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
            if !profile.isActiveCLI {
                Button("Switch CLI to This Account", systemImage: "arrow.triangle.2.circlepath") {
                    switchCLI()
                }
                .disabled(!hasStoredSnapshot)
                Divider()
            }
            Button("Open Dashboard…") { openDashboard() }
            if profile.isActiveCLI {
                Button("Log In via Terminal") { beginCLILogin() }
                Button("Save CLI Snapshot Now") { captureCLI() }
            } else {
                Button("Log In via Terminal") { beginCLILoginWithoutSwitching() }
                    .help("Re-authenticate this account in Terminal but keep the current account active.")
                Button("Log In and Switch") { beginCLILogin() }
                    .help("Log in and make this the active account.")
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
            Image(systemName: "ellipsis")
                .frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions")
        // Anchored here (not on the conditional badge) so the menu's
        // "Billing Details…" works for healthy accounts with no badge.
        .popover(isPresented: $showsBillingDetails, arrowEdge: .bottom) {
            BillingStatusView(snapshot: snapshot, planLabel: profile.planLabel)
                .padding(DS.Spacing.md)
                .frame(width: 320)
        }
    }

    @ViewBuilder
    private var gauges: some View {
        let windows = presentation.gauges.visible
        if !windows.isEmpty {
            LazyVGrid(
                columns: gaugeColumns(count: windows.count),
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(windows) { window in
                    UsageGauge(window: window, estimate: estimates[window.id])
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Label("Usage unavailable", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var hasExpandableDetails: Bool {
        presentation.gauges.showsPreResetNote
            || presentation.gauges.needsSessionCaptureNote
    }

    @ViewBuilder
    private var expandedDetails: some View {
        let groups = presentation.gauges

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if groups.showsPreResetNote, let last = snapshot?.lastRefreshed {
                Label(
                    "Last reading before reset — checked \(last.formatted(.relative(presentation: .named)))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            if groups.needsSessionCaptureNote {
                Label("Session not captured", systemImage: "clock.badge.questionmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("The last reading predates session-limit support; the next refresh adds it.")
            }
        }
    }

    private func gaugeColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(minimum: 0),
                spacing: DS.Spacing.md,
                alignment: .top
            ),
            count: count
        )
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
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                (problem.map { DS.presentationColor($0.tone) }
                    ?? note.map { DS.presentationColor($0.tone) }
                    ?? Color.secondary).opacity(0.065),
                in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Full billing-mode explanation; lives in the badge/menu popover since the
/// card itself only carries a badge for noteworthy modes.
struct BillingStatusView: View {
    let snapshot: UsageSnapshot?
    var planLabel: String? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let planLabel, !planLabel.isEmpty {
                Label("\(planLabel) plan", systemImage: "person.text.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            reduceTransparency ? Color(nsColor: .controlBackgroundColor) : color.opacity(0.055),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(color.opacity(0.12), lineWidth: 0.5)
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

/// A compact quota gauge sized to share one row with every limit on the account.
struct UsageGauge: View {
    let window: UsageWindow
    var estimate: BurnRateEstimate? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(window.label)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(window.label)

                    Spacer(minLength: 0)

                    if case .depletesAt = estimate {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(DS.riskColor(.warning))
                    }

                    Text(usageValue)
                        .font(
                            .system(
                                size: 11,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : DS.Motion.quick, value: usageValue)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(riskColor)
                            .frame(width: fillWidth(in: proxy.size.width))
                    }
                    .animation(reduceMotion ? nil : DS.Motion.progress, value: window.usedFraction)
                }
                .frame(height: 5)

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
        .background(CalmWindowBackground())
        .frame(width: DS.Popover.width, height: DS.Popover.height)
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
            isExpanded: .constant(false),
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
