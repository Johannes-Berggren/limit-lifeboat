import AppKit
import LLMUsageMonitorCore

private var retainedDelegate: AppDelegate?

@main
enum LLMUsageMonitorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var state: AppState?
    private var executableMonitor: RunningExecutableMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let executableURL = Bundle.main.executableURL else {
                throw RunningExecutableIntegrityError.unavailable(path: Bundle.main.bundlePath)
            }
            let integrityGuard = try RunningExecutableIntegrityGuard(executableURL: executableURL)
            let validateCredentialAccess: @Sendable () throws -> Void = {
                try integrityGuard.validate()
            }

            let repository = try ProfileRepository()
            let credentialStore = KeychainCredentialStore(validateAccess: validateCredentialAccess)
            let claudeCredentials = ClaudeCodeCredentialsKeychain(validateAccess: validateCredentialAccess)
            let switcher = CLISwitcher(
                backupDirectory: repository.applicationSupportDirectory
                    .appendingPathComponent("Backups", isDirectory: true),
                credentialStore: credentialStore,
                claudeCLICredentialSource: claudeCredentials
            )
            let state = try AppState(repository: repository, cliSwitcher: switcher)
            self.state = state
            self.menuBarController = MenuBarController(state: state)
            self.executableMonitor = try RunningExecutableMonitor(executableURL: executableURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRunningExecutableInvalidation()
                }
            }

            Task {
                await state.refreshAll()
                state.startBackgroundRefresh()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "LLM Usage Monitor could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func handleRunningExecutableInvalidation() {
        state?.stopForInvalidatedBundle()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LLM Usage Monitor was replaced while running"
        alert.informativeText = "This app bundle was rebuilt, moved, or deleted. macOS can no longer verify the running copy for Keychain access, so it will quit now. Relaunch LLM Usage Monitor from an app bundle that still exists."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
