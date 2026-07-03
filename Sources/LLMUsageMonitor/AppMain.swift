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
}
