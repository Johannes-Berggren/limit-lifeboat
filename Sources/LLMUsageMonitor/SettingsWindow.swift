import AppKit
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
            window.title = "LLM Usage Monitor Settings"
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

    var body: some View {
        Form {
            Section("General") {
                Picker("Refresh usage every", selection: $settings.refreshIntervalMinutes) {
                    ForEach(SettingsStore.refreshIntervalOptions, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }

                Picker("Menu bar shows", selection: $settings.menuBarWindowPreference) {
                    Text("Most constrained window").tag(MenuBarWindowPreference.mostConstrained)
                    Text("Session (5-hour)").tag(MenuBarWindowPreference.session)
                    Text("Weekly").tag(MenuBarWindowPreference.weekly)
                }
                .help("Which quota window the menu-bar percentage tracks. A missing window falls back to the most constrained one.")

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
                    .disabled(!LaunchAtLogin.isSupported)
                if let launchAtLoginMessage {
                    Text(launchAtLoginMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Notifications") {
                Toggle("Warn when included usage nears its limit", isOn: $settings.usageAlertsEnabled)
                Toggle("Alert when an account's quota is likely back", isOn: $settings.resetAlertsEnabled)
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
                        Text(upToDateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled: enabled)
            launchAtLoginMessage = nil
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchAtLoginMessage = "Could not update the login item: \(error.localizedDescription)"
        }
    }

    private func checkForUpdates() {
        isCheckingForUpdates = true
        upToDateMessage = nil
        Task {
            let found = await state.checkForUpdatesNow()
            upToDateMessage = found ? nil : "You're up to date."
            isCheckingForUpdates = false
        }
    }
}
