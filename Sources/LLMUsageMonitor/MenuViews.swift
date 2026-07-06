import LLMUsageMonitorCore
import SwiftUI

struct MenuRootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    providerSection(.claude)
                    providerSection(.codex)
                }
                .padding(14)
            }

            Divider()

            footer
        }
        .frame(minWidth: 430, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LLM Usage")
                        .font(.headline)
                    Text(lastRefreshText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await state.refreshAll() }
                } label: {
                    if state.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh Usage", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .help("Refresh usage")
                .disabled(state.isRefreshing)
            }

            TopUsageSummaryView(profiles: state.profiles, snapshots: state.snapshots)
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(state.statusMessage.isEmpty ? "Ready" : state.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button("Quit") {
                state.quit()
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
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
                Label(provider.displayName, systemImage: provider == .claude ? "sparkles" : "terminal")
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
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
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
                            Label("Active terminal", systemImage: "terminal.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(identityText)
                        .font(.caption)
                        .foregroundStyle(profile.identity == nil ? .tertiary : .secondary)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            UsageGauge(snapshot: snapshot, compact: true)
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
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .alert("Rename \(profile.label)", isPresented: $showsRenameAlert) {
            TextField("Account name", text: $renameText)
            Button("Rename") { rename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var staleness: (text: String, isOpportunity: Bool)? {
        guard let snapshot, !profile.isActiveCLI else {
            return nil
        }

        if snapshot.resetHasElapsed() {
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
        switch snapshot?.riskLevel ?? .unknown {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .depleted:
            return .red
        case .stale:
            return .yellow
        case .unknown:
            return .gray
        }
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
        HStack(spacing: 10) {
            summaryTile(provider: .claude)
            summaryTile(provider: .codex)
        }
    }

    private func summaryTile(provider: Provider) -> some View {
        let active = profiles.first { $0.provider == provider && $0.isActiveCLI }
        let snapshot = active.flatMap { snapshots[$0.id] }

        return VStack(alignment: .leading, spacing: 6) {
            Label(provider.displayName, systemImage: provider == .claude ? "sparkles" : "terminal")
                .font(.caption.weight(.semibold))

            if let active, let snapshot {
                Text(summaryValue(for: snapshot))
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(color(for: snapshot.billingUsageMode))
                Text(shortBillingLabel(for: snapshot.billingUsageMode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: snapshot.billingUsageMode))
                Text(active.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                Text(active?.label ?? "No active CLI account")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func summaryValue(for snapshot: UsageSnapshot) -> String {
        if snapshot.billingUsageMode == .overLimitPayAsYouGo {
            return "PAYG"
        }

        guard let usedFraction = snapshot.usedFraction else {
            return "--"
        }

        return "\(Int((usedFraction * 100).rounded()))% used"
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

    private func color(for riskLevel: RiskLevel) -> Color {
        switch riskLevel {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .depleted:
            return .red
        case .stale:
            return .yellow
        case .unknown:
            return .secondary
        }
    }

    private func color(for mode: BillingUsageMode) -> Color {
        switch mode {
        case .includedSubscription:
            return .green
        case .includedSubscriptionNearLimit:
            return .orange
        case .overLimitPayAsYouGo:
            return .red
        case .payAsYouGoVisible:
            return .orange
        case .needsLogin:
            return .yellow
        case .unknown:
            return .secondary
        }
    }
}

struct BillingStatusView: View {
    let snapshot: UsageSnapshot?
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var mode: BillingUsageMode {
        snapshot?.billingUsageMode ?? .unknown
    }

    private var title: String {
        switch mode {
        case .includedSubscription:
            return "Using included subscription usage"
        case .includedSubscriptionNearLimit:
            return "Using subscription usage - near limit"
        case .overLimitPayAsYouGo:
            return "PAY-AS-YOU-GO / credits likely in use"
        case .payAsYouGoVisible:
            return "Pay-as-you-go status visible"
        case .needsLogin:
            return "Usage mode needs login"
        case .unknown:
            return "Usage mode unknown"
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
        switch mode {
        case .includedSubscription:
            return .green
        case .includedSubscriptionNearLimit:
            return .orange
        case .overLimitPayAsYouGo:
            return .red
        case .payAsYouGoVisible:
            return .orange
        case .needsLogin:
            return .yellow
        case .unknown:
            return .gray
        }
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

struct UsageGauge: View {
    let snapshot: UsageSnapshot?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 8) {
                Text(usageTitle)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                Spacer()
                Text(usageDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(riskColor)
                        .frame(width: max(8, proxy.size.width * CGFloat(usedFraction)))
                }
            }
            .frame(height: compact ? 8 : 12)

            if !compact {
                HStack {
                    Text(snapshot?.message ?? "No usage snapshot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if let reset = snapshot?.resetDescription {
                        Text("Reset \(reset)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var usedFraction: Double {
        snapshot?.usedFraction ?? 0
    }

    private var usageTitle: String {
        guard let snapshot, let used = snapshot.usedFraction else {
            return "Usage unknown"
        }
        return "\(Int((used * 100).rounded()))% used"
    }

    private var usageDetail: String {
        guard let snapshot else {
            return "--"
        }

        if let remaining = snapshot.includedRemaining, let limit = snapshot.includedLimit {
            return "\(format(remaining)) left of \(format(limit))"
        }

        if snapshot.riskLevel == .stale {
            return "Needs login"
        }

        return snapshot.parseConfidence == .none ? "Unrecognized" : snapshot.riskLevel.rawValue.capitalized
    }

    private var riskColor: Color {
        switch snapshot?.riskLevel ?? .unknown {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .depleted:
            return .red
        case .stale:
            return .yellow
        case .unknown:
            return .gray
        }
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
