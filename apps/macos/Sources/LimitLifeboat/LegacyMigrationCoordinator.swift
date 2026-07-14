import AppKit
import Foundation
import LimitLifeboatCore
import Security

@MainActor
enum LegacyMigrationStartupResult {
    case proceed(enableLaunchAtLogin: Bool)
    case quit
}

@MainActor
final class LegacyMigrationCoordinator {
    private let validateCredentialAccess: @Sendable () throws -> Void

    init(validateCredentialAccess: @escaping @Sendable () throws -> Void) {
        self.validateCredentialAccess = validateCredentialAccess
    }

    func runIfNeeded() throws -> LegacyMigrationStartupResult {
        let legacyStore = KeychainCredentialStore(
            service: LegacyInstallIdentity.credentialService,
            validateAccess: validateCredentialAccess
        )
        let currentStore = KeychainCredentialStore(validateAccess: validateCredentialAccess)
        let migrator = try LegacyInstallMigrator(
            legacyCredentialStore: legacyStore,
            destinationCredentialStore: currentStore
        )
        let inspection = try migrator.inspect()
        guard inspection.requiresMigration else {
            if inspection.hasDestinationConflict {
                throw LegacyMigrationError.destinationConflict("the new data folder has no migration marker")
            }
            return .proceed(enableLaunchAtLogin: false)
        }
        guard !inspection.hasDestinationConflict else {
            throw LegacyMigrationError.destinationConflict("the new data folder has no migration marker")
        }

        guard quitLegacyApplicationsIfNeeded() else {
            return .quit
        }

        guard DistributionSignature.isDeveloperIDApplication else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Migration waits for the signed release"
            alert.informativeText = "Limit Lifeboat found data from LLM Usage Monitor. To keep migrated Keychain approvals attached to the permanent app identity, open the Developer ID-signed Limit Lifeboat release to migrate it. Development and ad-hoc builds leave the old data untouched."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return .quit
        }

        if inspection.isInProgress {
            let resume = NSAlert()
            resume.alertStyle = .informational
            resume.messageText = "Resume the Limit Lifeboat migration?"
            resume.informativeText = "A previous migration stopped before it finished. Resume its staged file copy and remaining Keychain items. The old files and Keychain items are still untouched; do not reopen LLM Usage Monitor until this finishes."
            resume.addButton(withTitle: "Resume")
            if inspection.canStartFresh {
                resume.addButton(withTitle: "Start Fresh")
            }
            resume.addButton(withTitle: "Quit")
            let response = resume.runModal()
            if inspection.canStartFresh, response == .alertSecondButtonReturn {
                guard try confirmStartFresh(using: migrator) else {
                    return try runIfNeeded()
                }
                return .proceed(enableLaunchAtLogin: false)
            }
            guard response == .alertFirstButtonReturn else {
                return .quit
            }
            guard let summary = try migrateWithRetry(migrator) else {
                return .quit
            }
            return showCompletion(summary)
        }

        let consent = NSAlert()
        consent.alertStyle = .informational
        consent.messageText = "Copy your accounts to Limit Lifeboat?"
        consent.informativeText = "Found \(inspection.profileCount) saved account\(inspection.profileCount == 1 ? "" : "s") from LLM Usage Monitor. Limit Lifeboat can copy profiles, usage history, preferences, and app-owned credential snapshots. Old plaintext backup files are left only in the untouched legacy data. macOS may ask you to approve Keychain access."
        consent.addButton(withTitle: "Migrate")
        consent.addButton(withTitle: "Start Fresh")
        consent.addButton(withTitle: "Quit")

        switch consent.runModal() {
        case .alertFirstButtonReturn:
            let summary = try migrateWithRetry(migrator)
            guard let summary else {
                return .quit
            }
            return showCompletion(summary)
        case .alertSecondButtonReturn:
            guard try confirmStartFresh(using: migrator) else {
                return try runIfNeeded()
            }
            return .proceed(enableLaunchAtLogin: false)
        default:
            return .quit
        }
    }

    private func confirmStartFresh(using migrator: LegacyInstallMigrator) throws -> Bool {
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Start without the old accounts?"
        confirmation.informativeText = "Limit Lifeboat will start empty. LLM Usage Monitor files and Keychain items will not be deleted."
        confirmation.addButton(withTitle: "Start Fresh")
        confirmation.addButton(withTitle: "Go Back")
        guard confirmation.runModal() == .alertFirstButtonReturn else {
            return false
        }
        try migrator.skipAndStartFresh()
        return true
    }

    private func migrateWithRetry(_ migrator: LegacyInstallMigrator) throws -> LegacyMigrationSummary? {
        while true {
            do {
                return try CredentialAccess.userInitiated(
                    reason: "migrate saved accounts to Limit Lifeboat"
                ) {
                    try migrator.migrate()
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Migration is paused"
                alert.informativeText = "No old data was deleted. \(error.localizedDescription) You can retry now or quit and resume on the next launch."
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn {
                    return nil
                }
            }
        }
    }

    private func showCompletion(_ summary: LegacyMigrationSummary) -> LegacyMigrationStartupResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Migration complete"
        var details = "Copied \(summary.profileCount) account\(summary.profileCount == 1 ? "" : "s") and \(summary.credentialCount) saved credential snapshot\(summary.credentialCount == 1 ? "" : "s")."
        if summary.profilesNeedingLogin > 0 {
            details += " \(summary.profilesNeedingLogin) account\(summary.profilesNeedingLogin == 1 ? "" : "s") had no saved snapshot and may need login."
        }
        details += " macOS treats the new bundle ID as a new app: approve Notifications when asked, allow Terminal Automation when you first use login, and sign in to embedded dashboards again. The old app's login item is separate; disable it in System Settings before enabling this one. The legacy data remains untouched until you choose to remove it."
        alert.informativeText = details
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Continue and Launch at Login")
        let response = alert.runModal()
        return .proceed(enableLaunchAtLogin: response == .alertSecondButtonReturn)
    }

    private func quitLegacyApplicationsIfNeeded() -> Bool {
        while true {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: LegacyInstallIdentity.bundleIdentifier
            ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            guard !running.isEmpty else {
                return true
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit LLM Usage Monitor first"
            alert.informativeText = "The old app is still running and could change its data during migration. Limit Lifeboat must quit it before copying anything."
            alert.addButton(withTitle: "Quit Old App")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return false
            }
            running.forEach { _ = $0.terminate() }

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline,
                  !NSRunningApplication.runningApplications(
                    withBundleIdentifier: LegacyInstallIdentity.bundleIdentifier
                  ).isEmpty {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
    }
}

private enum DistributionSignature {
    static var isDeveloperIDApplication: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
                == errSecSuccess,
              let staticCode else {
            return false
        }

        // Checking against the code's own designated requirement is not
        // enough: a self-signed certificate could choose a misleading common
        // name. Require Apple's trust anchor and the Developer ID Application
        // certificate/intermediate OIDs in addition to the permanent bundle ID.
        let requirementSource = """
        identifier "\(LegacyInstallIdentity.currentBundleIdentifier)" and
        anchor apple generic and
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and
        certificate leaf[subject.OU] = "\(DistributionIdentity.appleTeamIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementSource as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess
    }
}
