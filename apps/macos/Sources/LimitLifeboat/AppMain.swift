import AppKit
import LimitLifeboatCore
import ServiceManagement

private var retainedDelegate: AppDelegate?

@main
enum LimitLifeboatMain {
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

            let migrationResult = try LegacyMigrationCoordinator(
                validateCredentialAccess: validateCredentialAccess
            ).runIfNeeded()
            let enableLaunchAtLogin: Bool
            switch migrationResult {
            case .proceed(let shouldEnable):
                enableLaunchAtLogin = shouldEnable
            case .quit:
                NSApplication.shared.terminate(nil)
                return
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

            if enableLaunchAtLogin {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Launch at Login could not be enabled"
                    alert.informativeText = "Your accounts were migrated successfully. Enable Launch at Login later in Limit Lifeboat Settings. \(error.localizedDescription)"
                    alert.addButton(withTitle: "Continue")
                    alert.runModal()
                }
            }

            Task {
                await state.refreshAll()
                state.startBackgroundRefresh()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Limit Lifeboat could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func handleRunningExecutableInvalidation() {
        state?.stopForInvalidatedBundle()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Limit Lifeboat was replaced while running"
        alert.informativeText = "This app bundle was rebuilt, moved, or deleted. macOS can no longer verify the running copy for Keychain access, so it will quit now. Relaunch Limit Lifeboat from an app bundle that still exists."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
