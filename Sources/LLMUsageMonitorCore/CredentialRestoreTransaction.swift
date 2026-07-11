import Foundation

/// Executes the backup/write/rollback transaction independently of provider
/// capture and account selection. Every destination is backed up before the
/// first write; failures restore files and the live Claude keychain item.
final class CredentialRestoreTransaction {
    private let homeDirectory: URL
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let claudeCredentialSource: ClaudeCLICredentialSource

    init(
        homeDirectory: URL,
        backupDirectory: URL,
        fileManager: FileManager,
        claudeCredentialSource: ClaudeCLICredentialSource
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.claudeCredentialSource = claudeCredentialSource
    }

    func restore(_ snapshot: CredentialSnapshot) throws -> RestoreResult {
        let fileItems = snapshot.items.filter { $0.kind != .keychainJSONFields }
        let keychainItems = snapshot.items.filter { $0.kind == .keychainJSONFields }

        // Phase 1: back up every existing destination into one directory per
        // restore call before writing a single byte, so a failure here leaves
        // the credentials untouched. The live keychain item is backed up as a
        // JSON file alongside the file backups.
        let restoreBackupDirectory = backupDirectory.appendingPathComponent(uniqueBackupDirectoryName(), isDirectory: true)
        var backups: [URL] = []
        var backedUp: [(destination: URL, backup: URL)] = []

        for item in fileItems {
            let destination = resolve(relativePath: item.relativePath)
            guard fileManager.fileExists(atPath: destination.path) else {
                continue
            }
            do {
                try fileManager.createDirectory(at: restoreBackupDirectory, withIntermediateDirectories: true)
                let backup = restoreBackupDirectory.appendingPathComponent(sanitizedBackupName(for: item.relativePath))
                if fileManager.fileExists(atPath: backup.path) {
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.copyItem(at: destination, to: backup)
                backups.append(backup)
                backedUp.append((destination, backup))
            } catch {
                throw CLISwitcherError.backupFailed(path: destination.path, underlying: error)
            }
        }

        var liveKeychainBackup: Data?
        if snapshot.provider == .claude {
            // A failed keychain read must abort the restore before a single
            // write happens — treating it as "absent" would merge into {}
            // (dropping mcpOAuth) or skip the logout below.
            do {
                liveKeychainBackup = try claudeCredentialSource.readLiveItemJSON()
            } catch {
                throw CLISwitcherError.backupFailed(path: CLISwitcher.claudeKeychainItemPath, underlying: error)
            }
            if let liveKeychainBackup {
                do {
                    try fileManager.createDirectory(at: restoreBackupDirectory, withIntermediateDirectories: true)
                    let backup = restoreBackupDirectory
                        .appendingPathComponent(sanitizedBackupName(for: CLISwitcher.claudeKeychainItemPath) + ".json")
                    try liveKeychainBackup.write(to: backup, options: [.atomic])
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    backups.append(backup)
                } catch {
                    throw CLISwitcherError.backupFailed(path: CLISwitcher.claudeKeychainItemPath, underlying: error)
                }
            }
        }

        // Phase 2: write all items; on failure roll back from the backups.
        // The keychain merge goes last so a file failure never leaves the CLI
        // logged into a half-switched account.
        var touched: [URL] = []
        var wroteKeychain = false
        do {
            for item in fileItems {
                let destination = resolve(relativePath: item.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch item.kind {
                case .fullFile:
                    try item.contents.write(to: destination, options: [.atomic])
                case .jsonFields:
                    try mergeJSONFields(item.contents, into: destination)
                case .keychainJSONFields:
                    break
                }
                try fileManager.setAttributes(
                    [.posixPermissions: item.posixPermissions ?? 0o600],
                    ofItemAtPath: destination.path
                )
                touched.append(destination)
            }
            for item in keychainItems {
                let merged = mergeClaudeAiOauth(item.contents, intoItemJSON: liveKeychainBackup)
                try claudeCredentialSource.writeLiveItemJSON(merged)
                wroteKeychain = true
            }
            if snapshot.provider == .claude, keychainItems.isEmpty,
               let liveKeychainBackup,
               var liveObject = try? JSONSerialization.jsonObject(with: liveKeychainBackup) as? [String: Any],
               liveObject["claudeAiOauth"] != nil {
                // Legacy snapshot without a captured token: strip the
                // previous account's claudeAiOauth so the CLI is honestly
                // logged out instead of silently staying on the old account.
                // Every sibling key (especially mcpOAuth) stays in place.
                liveObject.removeValue(forKey: "claudeAiOauth")
                let loggedOut = try JSONSerialization.data(withJSONObject: liveObject, options: [.sortedKeys])
                try claudeCredentialSource.writeLiveItemJSON(loggedOut)
                wroteKeychain = true
            }
        } catch {
            for (destination, backup) in backedUp {
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: backup, to: destination)
            }
            if wroteKeychain, let liveKeychainBackup {
                try? claudeCredentialSource.writeLiveItemJSON(liveKeychainBackup)
            }
            throw error
        }

        return RestoreResult(touchedPaths: touched, backupURLs: backups)
    }

    private func resolve(relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(homeDirectory) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func mergeJSONFields(_ fieldsData: Data, into url: URL) throws {
        guard let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(url.path)
        }
        var destinationObject: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let destinationData = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: destinationData) as? [String: Any] else {
                throw CLISwitcherError.invalidJSON(url.path)
            }
            destinationObject = parsed
        }
        for (key, value) in fields {
            destinationObject[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: destinationObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private func uniqueBackupDirectoryName() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(stamp)-\(UUID().uuidString.prefix(8))"
    }

    private func sanitizedBackupName(for relativePath: String) -> String {
        relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "_")
    }
}
