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
                            Text("CLI")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18))
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

        if let creditStatus = snapshot.creditStatus {
            parts.append(creditStatus)
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
        let worst = providerProfiles
            .compactMap { profile -> (AccountProfile, UsageSnapshot)? in
                guard let snapshot = snapshots[profile.id] else {
                    return nil
                }
                return (profile, snapshot)
            }
            .max { left, right in
                (left.1.usedFraction ?? -1) < (right.1.usedFraction ?? -1)
            }

        return VStack(alignment: .leading, spacing: 6) {
            Label(provider.displayName, systemImage: provider == .claude ? "sparkles" : "terminal")
                .font(.caption.weight(.semibold))

            if let worst {
                Text("\(Int(((worst.1.usedFraction ?? 0) * 100).rounded()))% used")
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(color(for: worst.1.riskLevel))
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
}
