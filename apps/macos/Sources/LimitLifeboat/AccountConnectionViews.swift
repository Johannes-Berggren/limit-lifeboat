import LimitLifeboatAppWorkflows
import LimitLifeboatCore
import SwiftUI

struct ConnectionProgressView: View {
    let provider: Provider
    let progress: AccountConnectionProgress
    var retryLogin: () -> Void
    var refresh: () -> Void
    var authorize: () -> Void
    var dismiss: () -> Void

    private var title: String {
        switch progress.stage {
        case .starting: return "Opening \(provider.displayName) login"
        case .waiting: return "Finish signing in to \(provider.displayName)"
        case .verifying: return "Verifying the \(provider.displayName) account"
        case .loadingUsage: return "Account saved · loading usage"
        case .connected: return "\(provider.displayName) connected"
        case .authorizationRequired: return "Authorize to finish connecting"
        case .usageUnavailable: return "Account saved · usage unavailable"
        case .failed: return "Login needs attention"
        case .timedOut: return "Login was not confirmed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                if progress.stage.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: progress.stage == .connected ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(progress.stage == .connected ? DS.success : DS.warning)
                }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                if !progress.stage.isBusy {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss connection result")
                }
            }
            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.lg) {
                step("Sign in", complete: progress.usageRequestedAt != nil, number: 1)
                step("Verify account", complete: progress.usageRequestedAt != nil, number: 2)
                step("Load usage", complete: progress.stage == .connected, number: 3)
            }
            .font(.caption2)
            switch progress.stage {
            case .authorizationRequired(.claudeCode):
                Button("Authorize Claude Keychain Access…", action: authorize)
                    .buttonStyle(.bordered).controlSize(.small)
            case .failed, .timedOut:
                Button("Try Signing In Again", action: retryLogin)
                    .buttonStyle(.bordered).controlSize(.small)
            case .usageUnavailable:
                Button("Refresh Usage", action: refresh)
                    .buttonStyle(.bordered).controlSize(.small)
            default: EmptyView()
            }
        }
        .modifier(ConnectionNoticeSurface(tint: DS.accent))
        .accessibilityElement(children: .contain)
    }

    private func step(_ title: String, complete: Bool, number: Int) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "\(number).circle")
            .foregroundStyle(complete ? DS.accent : .secondary)
    }
}

struct SwitchReceiptView: View {
    let receipt: AccountSwitchReceipt
    let isChecking: Bool
    var copyRestartCommand: () -> Void
    var recheck: () -> Void
    var dismiss: () -> Void
    @State private var copiedRestartCommand = false

    private var title: String {
        if receipt.loginVerification == .differentLogin { return "The CLI login changed after switching" }
        if receipt.loginVerification == .unavailable { return "CLI login needs verification" }
        if receipt.serverStatus == .restartNeeded { return "Login changed · server restart needed" }
        return "\(receipt.provider.displayName) CLI login verified"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: receipt.needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(receipt.needsAttention ? DS.warning : DS.success)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss switch result")
            }
            if receipt.loginVerification == .verified {
                Text("Saved CLI login: \(receipt.label)")
                    .font(.caption.weight(.medium))
            }
            if receipt.serverStatus == .restartNeeded || receipt.serverStatus == .unknown {
                Text(receipt.serverStatus == .restartNeeded
                     ? "The background server present at the switch is still running. Restart it in Terminal when your running work can be interrupted, then check again."
                     : "The background server's restart could not be confirmed. Restart it in Terminal when your running work can be interrupted, then check again.")
                Text("codex app-server daemon restart")
                    .font(.caption.monospaced())
            } else if receipt.serverStatus == .previousServerStopped {
                Text("The previous background server has stopped. This check does not verify a new server's account.")
            }
            if receipt.hasPlaintextOverride {
                Text("A leftover ~/.claude/.credentials.json may override this login. If Claude Code shows the wrong account, move that file aside, then check again.")
            }
            Text("Already-running sessions may keep their previous login. Restart those sessions before relying on the new account.")
            if let message = receipt.recheckMessage { Text(message) }
            HStack(spacing: DS.Spacing.md) {
                if receipt.serverStatus == .restartNeeded || receipt.serverStatus == .unknown {
                    Button(copiedRestartCommand ? "Command Copied" : "Copy Restart Command") {
                        copyRestartCommand()
                        copiedRestartCommand = true
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                Button(isChecking ? "Checking…" : "Check Again", action: recheck)
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isChecking)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ConnectionNoticeSurface(tint: receipt.needsAttention ? DS.warning : DS.accent))
        .accessibilityElement(children: .contain)
    }
}

/// Match the shortfall banner's legible, tinted notice surface. Native glass
/// is reserved for the account cards and controls behind these instructions.
private struct ConnectionNoticeSurface: ViewModifier {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        content
            .padding(DS.Spacing.cardPadding)
            .background(reduceTransparency ? Color(nsColor: .controlBackgroundColor) : tint.opacity(0.06), in: shape)
            .overlay { shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.5) }
    }
}
