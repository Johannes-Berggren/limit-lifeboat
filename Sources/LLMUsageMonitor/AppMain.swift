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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let repository = try ProfileRepository()
            let credentialStore = KeychainCredentialStore()
            let switcher = CLISwitcher(
                backupDirectory: repository.applicationSupportDirectory
                    .appendingPathComponent("Backups", isDirectory: true),
                credentialStore: credentialStore
            )
            let state = try AppState(repository: repository, cliSwitcher: switcher)
            self.state = state
            self.menuBarController = MenuBarController(state: state)

            warnIfBundleOrphaned(state: state)

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

    /// Warns when the running executable no longer exists on disk — the app was
    /// launched from a bundle that has since been deleted, moved, or rebuilt.
    /// In that state macOS can't resolve this process's code identity, so every
    /// Keychain write (account capture/switch) fails with a code-signing error
    /// (e.g. -67068). Relaunching from a bundle that exists is the only fix.
    private func warnIfBundleOrphaned(state: AppState) {
        guard let executable = Bundle.main.executableURL,
              !FileManager.default.fileExists(atPath: executable.path) else {
            return
        }

        state.statusMessage = "This app is running from a deleted or replaced copy. "
            + "Account switching will fail until you quit and relaunch LLM Usage Monitor."

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LLM Usage Monitor is running from a deleted copy"
        alert.informativeText = "The app bundle it was launched from no longer exists on disk "
            + "(rebuilt, moved, or deleted). macOS can no longer verify its code signature, so "
            + "saving or switching accounts will fail with a Keychain error. Quit and relaunch the "
            + "app from its current location to fix this."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
