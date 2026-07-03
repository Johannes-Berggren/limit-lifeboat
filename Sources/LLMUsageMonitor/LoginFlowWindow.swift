import AppKit
import LLMUsageMonitorCore
import SwiftUI

@MainActor
final class LoginFlowWindowManager {
    private var controller: NSWindowController?

    func open(state: AppState) {
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let rootView = LoginFlowView(state: state)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Account Setup"
        window.setContentSize(NSSize(width: 760, height: 620))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        self.controller = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.controller = nil
            }
        }

        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct LoginFlowView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(state.profiles.enumerated()), id: \.element.id) { index, profile in
                        LoginAccountSetupRow(
                            step: index + 1,
                            profile: profile,
                            snapshot: state.snapshots[profile.id],
                            hasCLISnapshot: state.hasStoredSnapshot(for: profile),
                            openDashboard: {
                                state.openDashboard(for: profile)
                            },
                            beginCLILogin: {
                                state.beginCLILogin(for: profile)
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
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("Account Setup", systemImage: "person.2.badge.gearshape")
                    .font(.title3.weight(.semibold))

                Spacer()

                Button {
                    state.importCurrentCLIForPrimaryAccounts()
                } label: {
                    Label("Use Current CLI Logins", systemImage: "square.and.arrow.down")
                }
            }

            Text("Use this screen only to connect accounts and save CLI snapshots. Usage refresh is controlled from the main menu; dashboard windows read the page after login and when you click Read Page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}

struct LoginAccountSetupRow: View {
    let step: Int
    let profile: AccountProfile
    let snapshot: UsageSnapshot?
    let hasCLISnapshot: Bool
    let openDashboard: () -> Void
    let beginCLILogin: () -> Void
    let captureCLI: () -> Void
    let switchCLI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(step)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(providerColor)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.label)
                        .font(.headline)
                    Text(profile.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(identityText)
                        .font(.caption)
                        .foregroundStyle(profile.identity == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                statusPill(text: profile.webDataStoreKind == .appDefault ? "Primary" : "Isolated", systemImage: profile.webDataStoreKind == .appDefault ? "person.crop.circle.fill" : "person.crop.circle.badge.plus", color: profile.webDataStoreKind == .appDefault ? .blue : .secondary)
                statusPill(text: dashboardStatus.text, systemImage: dashboardStatus.image, color: dashboardStatus.color)
                statusPill(text: hasCLISnapshot ? "CLI saved" : "CLI missing", systemImage: hasCLISnapshot ? "key.fill" : "key", color: hasCLISnapshot ? .green : .secondary)
            }

            UsageGauge(snapshot: snapshot, compact: false)

            HStack(spacing: 10) {
                Button {
                    openDashboard()
                } label: {
                    Label("Open Dashboard", systemImage: "safari")
                }

                Button {
                    beginCLILogin()
                } label: {
                    Label("Run CLI Login", systemImage: "terminal")
                }

                Button {
                    captureCLI()
                } label: {
                    Label("Save Snapshot", systemImage: "key")
                }

                Spacer()

                Button {
                    switchCLI()
                } label: {
                    Label("Switch CLI", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!hasCLISnapshot)
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var dashboardStatus: (text: String, image: String, color: Color) {
        guard let snapshot else {
            return ("Dashboard missing", "globe.badge.chevron.backward", .secondary)
        }

        if snapshot.riskLevel == .stale || snapshot.message.lowercased().contains("login") {
            return ("Dashboard login", "person.crop.circle.badge.exclamationmark", .orange)
        }

        if snapshot.parseConfidence == .none {
            return ("Dashboard unclear", "questionmark.circle", .secondary)
        }

        return ("Dashboard linked", "checkmark.circle.fill", .green)
    }

    private var providerColor: Color {
        profile.provider == .claude ? .purple : .blue
    }

    private var identityText: String {
        guard let identity = profile.identity else {
            return "No email or organization read yet"
        }

        var parts: [String] = []
        if let email = identity.email {
            parts.append(email)
        } else if let name = identity.displayName {
            parts.append(name)
        } else if let accountID = identity.accountID {
            parts.append(accountID)
        }

        if let organization = identity.organization, !organization.isEmpty {
            parts.append("Org: \(organization)")
        } else {
            parts.append("Org not read")
        }

        parts.append(identity.source == .codexIDToken ? "from CLI" : "from dashboard")
        return parts.joined(separator: " • ")
    }

    private func statusPill(text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
