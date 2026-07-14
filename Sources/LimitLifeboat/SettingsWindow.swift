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
            let hosting = NSHostingController(rootView: SettingsView(state: state, settings: state.settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Limit Lifeboat Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            // Drop the window on close so the next open builds a fresh view —
            // otherwise @State (login-item toggle, update-check message) keeps
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
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginMessage: String?
    @State private var isCheckingForUpdates = false
    @State private var upToDateMessage: String?
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
                        if let update = state.availableUpdate {
                            Button("Download version \(update.version)…") {
                                state.openAvailableUpdate()
                            }
                        } else {
                            Button(isCheckingForUpdates ? "Checking…" : "Check for Updates") {
                                checkForUpdates()
                            }
                            .disabled(isCheckingForUpdates)
                            if let upToDateMessage {
                                StatusBanner(
                                    text: upToDateMessage,
                                    systemImage: "checkmark.circle.fill",
                                    color: DS.success
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
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
        .animation(reduceMotion ? nil : DS.Motion.standard, value: upToDateMessage)
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

    private func checkForUpdates() {
        isCheckingForUpdates = true
        upToDateMessage = nil
        Task {
            let found = await state.checkForUpdatesNow()
            withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                upToDateMessage = found ? nil : "You're up to date."
            }
            isCheckingForUpdates = false
        }
    }
}
