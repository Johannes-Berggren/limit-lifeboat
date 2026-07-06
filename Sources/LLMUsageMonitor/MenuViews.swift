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
                    state.openLoginFlow()
                } label: {
                    Label("Accounts", systemImage: "person.2.badge.gearshape")
                }
                .buttonStyle(.bordered)

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
            ActiveCLIAccountsView(identities: state.activeCLIIdentities, profiles: state.profiles)
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
            }

            ForEach(profiles) { profile in
                AccountRowView(
                    profile: profile,
                    snapshot: state.snapshots[profile.id],
                    openDashboard: {
                        state.openDashboard(for: profile)
                    }
                )
            }
        }
    }
}

struct AccountRowView: View {
    let profile: AccountProfile
    let snapshot: UsageSnapshot?
    let openDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(riskColor)
                    .frame(width: 8, height: 8)

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
            }

            UsageGauge(snapshot: snapshot, compact: true)
            BillingStatusView(snapshot: snapshot, compact: true)

            HStack(spacing: 8) {
                Button {
                    openDashboard()
                } label: {
                    Label(dashboardButtonTitle, systemImage: "safari")
                }
                .help("Open dashboard")

                Spacer()
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var statusText: String {
        guard let snapshot else {
            return "No usage snapshot"
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
            return profile.webDataStoreKind == .appDefault ? "Primary profile, identity not read yet" : "Sign in to identify this account"
        }

        var parts: [String] = []
        if let primary = identity.primaryLabel {
            parts.append(primary)
        }
        if let organization = identity.organization, !organization.isEmpty {
            parts.append(organization)
        } else {
            parts.append("Org not read")
        }
        parts.append(identitySourceText(identity.source))
        return parts.joined(separator: " • ")
    }

    private func identitySourceText(_ source: AccountIdentitySource) -> String {
        switch source {
        case .codexIDToken:
            return "CLI"
        case .claudeCodeUsage:
            return "Claude Code"
        case .dashboard:
            return "Dashboard"
        case .manual:
            return "Manual"
        }
    }

    private var dashboardButtonTitle: String {
        guard let snapshot else {
            return "Connect Dashboard"
        }

        if snapshot.riskLevel == .stale || snapshot.message.lowercased().contains("login") || profile.identity == nil {
            return "Connect Dashboard"
        }

        return "Open Dashboard"
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

struct ActiveCLIAccountsView: View {
    let identities: [Provider: AccountIdentity]
    let profiles: [AccountProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)
                Text("Current Terminal Accounts")
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                accountTile(provider: .claude)
                accountTile(provider: .codex)
            }
        }
    }

    private func accountTile(provider: Provider) -> some View {
        let identity = identities[provider]
        let matchingProfile = identity.flatMap { identity in
            profiles.first { profile in
                profile.provider == provider
                    && (profile.isActiveCLI || identitiesMatch(profile.identity, identity))
            }
        }
        let hasIdentity = identity != nil
        let iconName = provider == .claude ? "sparkles" : "terminal"
        let accentColor: Color = hasIdentity ? .green : .secondary
        let backgroundColor: Color = hasIdentity ? .green.opacity(0.10) : .gray.opacity(0.10)
        let borderColor: Color = hasIdentity ? .green.opacity(0.24) : .gray.opacity(0.24)
        let primaryText = identityPrimaryText(identity)
        let detailText = identityDetailText(identity, matchingProfile: matchingProfile)

        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(primaryText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 0.5)
        )
    }

    private func identityPrimaryText(_ identity: AccountIdentity?) -> String {
        identity?.primaryLabel ?? "Not signed in"
    }

    private func identityDetailText(_ identity: AccountIdentity?, matchingProfile: AccountProfile?) -> String {
        guard let identity else {
            return "No active CLI account detected"
        }

        var parts: [String] = []
        if let organization = identity.organization, !organization.isEmpty {
            parts.append(organization)
        } else {
            parts.append("Organization not read")
        }

        if let matchingProfile {
            parts.append("Matches \(matchingProfile.label)")
        }

        return parts.joined(separator: " - ")
    }

    private func identitiesMatch(_ left: AccountIdentity?, _ right: AccountIdentity) -> Bool {
        guard let left else {
            return false
        }

        if let leftAccountID = left.accountID,
           let rightAccountID = right.accountID,
           leftAccountID == rightAccountID {
            return true
        }

        if let leftEmail = left.email?.lowercased(),
           let rightEmail = right.email?.lowercased(),
           leftEmail == rightEmail {
            return true
        }

        return false
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
        let providerProfiles = profiles.filter { $0.provider == provider }
        let entries = providerProfiles
            .compactMap { profile -> (AccountProfile, UsageSnapshot)? in
                guard let snapshot = snapshots[profile.id] else {
                    return nil
                }
                return (profile, snapshot)
            }
        let worst = entries.first { $0.1.billingUsageMode == .overLimitPayAsYouGo }
            ?? entries.max { left, right in
                (left.1.usedFraction ?? -1) < (right.1.usedFraction ?? -1)
            }

        return VStack(alignment: .leading, spacing: 6) {
            Label(provider.displayName, systemImage: provider == .claude ? "sparkles" : "terminal")
                .font(.caption.weight(.semibold))

            if let worst {
                Text(summaryValue(for: worst.1))
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(color(for: worst.1.billingUsageMode))
                Text(shortBillingLabel(for: worst.1.billingUsageMode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: worst.1.billingUsageMode))
                Text(worst.0.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                Text("No snapshot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
