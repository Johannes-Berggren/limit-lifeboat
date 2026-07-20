import AppKit
import LimitLifeboatCore
import ServiceManagement
import UserNotifications

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
        // Registered before AppState exists so a notification click that
        // launches the app is still delivered to this delegate. Guarded like
        // every UNUserNotificationCenter touch: an unbundled `swift run` has
        // no notification center and must not crash.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        do {
            let applicationVariant = try ApplicationVariant.resolve()
            guard let executableURL = Bundle.main.executableURL else {
                throw RunningExecutableIntegrityError.unavailable(path: Bundle.main.bundlePath)
            }
            let integrityGuard = try RunningExecutableIntegrityGuard(executableURL: executableURL)
            let codeSignatureStatus = ApplicationCodeSignatureInspector.inspect(
                executableURL: executableURL
            )
            let validateCredentialAccess: @Sendable () throws -> Void = {
                try integrityGuard.validate()
                if case .invalid(let status) = codeSignatureStatus {
                    throw RunningExecutableIntegrityError.invalidCodeSignature(status: status)
                }
                if applicationVariant == .distribution {
                    guard case .developerIDApplication(let teamIdentifier) = codeSignatureStatus,
                          teamIdentifier == DistributionIdentity.appleTeamIdentifier else {
                        throw RunningExecutableIntegrityError.unsupportedCodeSignature
                    }
                }
            }
            // Fail closed before migration, UI construction, or any scheduled
            // credential work. Otherwise an empty profile set could let an
            // invalid (or ad-hoc distribution) bundle appear healthy until a
            // later Keychain operation happened to invoke this guard.
            try validateCredentialAccess()

            var enableLaunchAtLogin = false
            if applicationVariant.allowsLegacyMigration {
                let migrationResult = try LegacyMigrationCoordinator(
                    validateCredentialAccess: validateCredentialAccess
                ).runIfNeeded()
                switch migrationResult {
                case .proceed(let shouldEnable):
                    enableLaunchAtLogin = shouldEnable
                case .quit:
                    NSApplication.shared.terminate(nil)
                    return
                }
            }

            let repository = try ProfileRepository(
                applicationSupportDirectoryName: applicationVariant.applicationSupportDirectoryName
            )
            let credentialStore = KeychainCredentialStore(
                service: applicationVariant.credentialService,
                validateAccess: validateCredentialAccess
            )
            let claudeCredentials = ClaudeCodeCredentialsKeychain(validateAccess: validateCredentialAccess)
            let switcher = CLISwitcher(
                backupDirectory: repository.applicationSupportDirectory
                    .appendingPathComponent("Backups", isDirectory: true),
                credentialStore: credentialStore,
                claudeCLICredentialSource: claudeCredentials
            )
            let state = try AppState(
                repository: repository,
                cliSwitcher: switcher,
                codeSignatureStatus: codeSignatureStatus
            )
            self.state = state
            self.menuBarController = MenuBarController(state: state)
            self.executableMonitor = try RunningExecutableMonitor(executableURL: executableURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRunningExecutableInvalidation()
                }
            }

            if applicationVariant.supportsLaunchAtLogin, enableLaunchAtLogin {
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

    private func handleNotificationResponse(
        actionIdentifier: String,
        action: String?,
        providerRaw: String?,
        targetRaw: String?
    ) async {
        let provider = providerRaw.flatMap(Provider.init(rawValue:))

        if actionIdentifier == NotificationSwitchAction.refreshActionID,
           action == NotificationSwitchAction.refreshActionValue,
           let provider {
            await state?.performNotificationRefresh(
                provider: provider,
                profileID: targetRaw.flatMap(UUID.init)
            )
            return
        }

        if actionIdentifier == NotificationSwitchAction.actionID,
           action == NotificationSwitchAction.actionValue,
           let provider {
            await state?.performNotificationSwitch(
                provider: provider,
                embeddedTargetID: targetRaw.flatMap(UUID.init)
            )
            return
        }

        // Tapping the notification body (or an unrecognized payload) just
        // brings up the popover as the place to act.
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            menuBarController?.showPopover()
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Alerts must stay visible even while this accessory app counts as
    /// active (its popover being open would otherwise swallow them).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extract the Sendable pieces before hopping to the main actor —
        // UNNotificationResponse and its userInfo dictionary are not.
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        let action = userInfo[NotificationSwitchAction.actionKey] as? String
        let providerRaw = userInfo[NotificationSwitchAction.providerKey] as? String
        let targetRaw = userInfo[NotificationSwitchAction.targetKey] as? String
        await handleNotificationResponse(
            actionIdentifier: actionIdentifier,
            action: action,
            providerRaw: providerRaw,
            targetRaw: targetRaw
        )
    }
}
