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
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .disabled(state.isRefreshing)
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
                    state.copyLoginCommand(for: provider)
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Copy login command and open Terminal")
            }

            ForEach(profiles) { profile in
                AccountRowView(
                    profile: profile,
                    snapshot: state.snapshots[profile.id],
                    hasSnapshot: state.hasStoredSnapshot(for: profile),
                    activeLoginPresent: state.validateActiveLogin(provider: provider),
                    refresh: {
                        Task { await state.refresh(profile) }
                    },
                    openDashboard: {
                        state.openDashboard(for: profile)
                    },
                    captureCLI: {
                        state.captureCLISnapshot(for: profile)
                    },
                    switchCLI: {
                        state.switchCLI(to: profile)
                    }
                )
            }
        }
    }
}

struct AccountRowView: View {
    let profile: AccountProfile
    let snapshot: UsageSnapshot?
    let hasSnapshot: Bool
    let activeLoginPresent: Bool
    let refresh: () -> Void
    let openDashboard: () -> Void
    let captureCLI: () -> Void
    let switchCLI: () -> Void

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

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            if let fraction = snapshot?.remainingFraction {
                ProgressView(value: fraction)
                    .tint(riskColor)
            } else {
                ProgressView(value: 0)
                    .tint(.gray)
                    .opacity(0.35)
            }

            HStack(spacing: 8) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh this account")

                Button {
                    openDashboard()
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open dashboard")

                Button {
                    captureCLI()
                } label: {
                    Image(systemName: "key")
                }
                .help("Capture current CLI login for this account")

                Button {
                    switchCLI()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Switch CLI to this account")
                .disabled(!hasSnapshot)

                Spacer()

                Text(cliStateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
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

    private var cliStateText: String {
        if hasSnapshot && activeLoginPresent {
            return "snapshot saved"
        }
        if hasSnapshot {
            return "snapshot saved"
        }
        return "no snapshot"
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
