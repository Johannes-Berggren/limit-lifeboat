import AppKit
import LimitLifeboatCore
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(state: AppState) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    settings: state.settings,
                    updater: state.updater,
                    exportUsageHistory: { [weak state] in state?.exportAllUsageHistoryCSV() },
                    applicationSupportDirectory: state.applicationSupportDirectory
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Limit Lifeboat Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            // Drop the window on close so the next open builds a fresh view —
            // otherwise @State (such as the login-item toggle) keeps
            // showing whatever was true the first time it opened.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.discardWindow()
                }
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func discardWindow() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }
}

enum LaunchAtLogin {
    /// SMAppService requires a real bundle; guard so an unbundled `swift run`
    /// does not crash (same constraint as notifications).
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil
            && ApplicationVariant.current.supportsLaunchAtLogin
    }

    static var isEnabled: Bool {
        guard isSupported else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) throws {
        guard isSupported else {
            return
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updater: AppUpdater
    /// Optional so previews and tests can construct the view without an
    /// AppState behind it.
    var exportUsageHistory: (() -> Void)? = nil
    /// Where the durable event log lives, so diagnostics can include events
    /// that predate this app session. Optional for the same preview/test reason.
    var applicationSupportDirectory: URL? = nil

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var diagnosticsMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CalmWindowBackground()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Label("Limit Lifeboat", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.title2.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary, .tint)
                    Text("Choose how usage is refreshed, shown, and acted on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.top, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.sm)

                Form {
                    Section("General") {
                        Picker("Refresh usage every", selection: $settings.refreshIntervalMinutes) {
                            ForEach(SettingsStore.refreshIntervalOptions, id: \.self) { minutes in
                                Text("\(minutes) minutes").tag(minutes)
                            }
                        }

                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, newValue in
                                applyLaunchAtLogin(newValue)
                            }
                            .disabled(!LaunchAtLogin.isSupported)
                        if let launchAtLoginMessage {
                            StatusBanner(
                                text: launchAtLoginMessage,
                                systemImage: "exclamationmark.triangle.fill",
                                color: DS.danger
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Section("Appearance") {
                        Toggle("Show organization names", isOn: $settings.showOrganizationNames)
                    }

                    Section("Notifications") {
                        Toggle("Warn when included usage nears its limit", isOn: $settings.usageAlertsEnabled)
                        Toggle("Alert when an account's quota is likely back", isOn: $settings.resetAlertsEnabled)
                        Toggle("Also alert for the short session window (~5h)", isOn: $settings.sessionWindowAlertsEnabled)
                        Toggle("Send a weekly usage summary", isOn: $settings.weeklyDigestEnabled)
                        Label(
                            "Session alerts can be chatty during heavy use — every long working session burns that window down.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Switching") {
                        Toggle("Switch CLI automatically when the active account is depleted", isOn: $settings.autoSwitchEnabled)
                        Label(
                            "Chooses the saved account with the most remaining quota and sends a notification. It only runs when another account clearly has more headroom.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Updates") {
                        LabeledContent("Version", value: AppInfo.version)
                        if updater.isEnabled {
                            Toggle(
                                "Automatically check for updates",
                                isOn: Binding(
                                    get: { updater.automaticallyChecksForUpdates },
                                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                                )
                            )
                            if let version = updater.availableVersion {
                                Label(
                                    "Version \(version) is ready to install.",
                                    systemImage: "arrow.down.circle.fill"
                                )
                                .foregroundStyle(DS.accent)
                            }
                            Button(
                                updater.availableVersion.map { "Install version \($0)…" }
                                    ?? "Check for Updates…"
                            ) {
                                updater.checkForUpdates()
                            }
                            .disabled(!updater.canCheckForUpdates)
                        } else {
                            Label(
                                "Updates are disabled in development builds.",
                                systemImage: "hammer"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Section("History") {
                        Button("Export Usage History as CSV…") {
                            exportUsageHistory?()
                        }
                        .disabled(exportUsageHistory == nil)
                        Label(
                            "Every account's usage readings from the last 30 days. The export names accounts by their labels only — never emails or organizations.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Troubleshooting") {
                        Button("Copy Diagnostics") {
                            copyDiagnostics()
                        }
                        Label(
                            "Copies this session's app logs for a bug report. Logs identify accounts by internal IDs only — never credentials, emails, or account names.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let diagnosticsMessage {
                            StatusBanner(
                                text: diagnosticsMessage,
                                systemImage: "doc.on.clipboard",
                                color: DS.accent
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(DS.accent)
        .animation(reduceMotion ? nil : DS.Motion.standard, value: launchAtLoginMessage)
        .animation(reduceMotion ? nil : DS.Motion.standard, value: updater.availableVersion)
        .animation(reduceMotion ? nil : DS.Motion.standard, value: diagnosticsMessage)
    }

    private func copyDiagnostics() {
        Task {
            let message: String
            do {
                // Reading the log store can take a moment; keep it off the
                // main actor so the window stays responsive.
                let directory = applicationSupportDirectory
                let report = try await Task.detached(priority: .userInitiated) {
                    try DiagnosticsReport.generate(applicationSupportDirectory: directory)
                }.value
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                message = "Diagnostics copied to the clipboard."
            } catch {
                message = "Could not read the app's logs: \(error.localizedDescription)"
            }
            withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                diagnosticsMessage = message
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled: enabled)
            withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                launchAtLoginMessage = nil
            }
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                launchAtLoginMessage = "Could not update the login item: \(error.localizedDescription)"
            }
        }
    }
}
