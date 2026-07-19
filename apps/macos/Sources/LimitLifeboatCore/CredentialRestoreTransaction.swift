import Foundation

struct CredentialRestoreHooks {
    var beforeDestinationCheck: ((URL) throws -> Void)?
    var afterDestinationWrite: ((URL) throws -> Void)?

    init(
        beforeDestinationCheck: ((URL) throws -> Void)? = nil,
        afterDestinationWrite: ((URL) throws -> Void)? = nil
    ) {
        self.beforeDestinationCheck = beforeDestinationCheck
        self.afterDestinationWrite = afterDestinationWrite
    }

    static let none = CredentialRestoreHooks()
}

/// Executes the backup/write/validate/rollback transaction independently of
/// provider capture and account selection. Temporary rollback material is
/// removed after a validated commit or successful rollback. It is retained
/// only when an outside change makes automatic rollback unsafe.
final class CredentialRestoreTransaction {
    private let homeDirectory: URL
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let claudeCredentialSource: ClaudeCLICredentialSource
    private let hooks: CredentialRestoreHooks

    init(
        homeDirectory: URL,
        backupDirectory: URL,
        fileManager: FileManager,
        claudeCredentialSource: ClaudeCLICredentialSource,
        hooks: CredentialRestoreHooks = .none
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.claudeCredentialSource = claudeCredentialSource
        self.hooks = hooks
    }

    func restore(
        _ snapshot: CredentialSnapshot,
        expectedLiveFingerprint: String?? = nil,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        claudeKeychainItemLocation: ClaudeKeychainItemLocation? = nil,
        validateRestoredCredentials: () throws -> Void
    ) throws -> [URL] {
        var normalizedItems = try snapshot.items.map { try normalized($0, provider: snapshot.provider) }
        if snapshot.provider == .claude {
            appendMissingClaudeRemovalPatch(
                relativePath: "Library/Application Support/Claude/config.json",
                ownedKeys: ClaudeCredentialAdapter.configOwnedKeys,
                to: &normalizedItems
            )
            appendMissingClaudeRemovalPatch(
                relativePath: ".claude.json",
                ownedKeys: ClaudeCredentialAdapter.accountOwnedKeys,
                to: &normalizedItems
            )
        }
        let fileItems = normalizedItems.filter { $0.kind != .keychainJSONFields }
        let keychainItems = normalizedItems.filter { $0.kind == .keychainJSONFields }

        // Phase 1: record every existing destination in a private temporary
        // directory before writing a single byte. These are transaction-local
        // rollback files, not persistent account-switch backups.
        let restoreBackupDirectory = backupDirectory.appendingPathComponent(uniqueBackupDirectoryName(), isDirectory: true)
        var retainRecoveryDirectory = false
        defer {
            if !retainRecoveryDirectory {
                try? fileManager.removeItem(at: restoreBackupDirectory)
            }
        }
        do {
            // Create the Backups root as 0o700 rather than the umask default:
            // it transiently holds cleartext credential rollback files during a
            // switch. (Existing directories keep their permissions; the 0o700
            // leaf directory and 0o600 files below protect contents regardless.)
            try fileManager.createDirectory(
                at: backupDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: restoreBackupDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: restoreBackupDirectory.path
            )
        } catch {
            throw CLISwitcherError.backupFailed(path: backupDirectory.path, underlying: error)
        }

        var baselines: [String: Data] = [:]
        var baselinePermissions: [String: Int] = [:]
        var baselineBackupURLs: [String: URL] = [:]
        var missingBaselines: Set<String> = []

        for item in fileItems {
            let destination = resolve(relativePath: item.relativePath)
            let baseline: Data?
            do {
                baseline = fileManager.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
            } catch {
                throw CLISwitcherError.backupFailed(path: destination.path, underlying: error)
            }
            if let baseline {
                baselines[destination.path] = baseline
                baselinePermissions[destination.path] =
                    (try? fileManager.attributesOfItem(atPath: destination.path)[.posixPermissions]) as? Int
            } else {
                missingBaselines.insert(destination.path)
            }
            guard let baseline else {
                continue
            }
            do {
                let backup = restoreBackupDirectory.appendingPathComponent(sanitizedBackupName(for: item.relativePath))
                try baseline.write(to: backup, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                baselineBackupURLs[destination.path] = backup
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
                liveKeychainBackup = try readClaudeKeychainItem(
                    at: claudeKeychainItemLocation,
                    accessMode: accessMode
                )
            } catch {
                throw CLISwitcherError.backupFailed(path: CLISwitcher.claudeKeychainItemPath, underlying: error)
            }
            if let liveKeychainBackup {
                do {
                    let backup = restoreBackupDirectory
                        .appendingPathComponent(sanitizedBackupName(for: CLISwitcher.claudeKeychainItemPath) + ".json")
                    try liveKeychainBackup.write(to: backup, options: [.atomic])
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                } catch {
                    throw CLISwitcherError.backupFailed(path: CLISwitcher.claudeKeychainItemPath, underlying: error)
                }
            }
        }

        // Backups can take long enough for Conductor or a CLI to switch the
        // account. Recheck the provider-owned fingerprint after all backups and
        // immediately before the first mutation; per-destination byte checks
        // cover changes from this point onward.
        try validateExpectedLiveFingerprint(
            expectedLiveFingerprint,
            provider: snapshot.provider,
            accessMode: accessMode,
            claudeKeychainItemLocation: claudeKeychainItemLocation,
            claudeKeychainItemData: liveKeychainBackup
        )

        // Phase 2: write all items; on failure roll back from the backups.
        // The keychain merge goes last so a file failure never leaves the CLI
        // logged into a half-switched account.
        var touched: [URL] = []
        var writtenFiles: [String: Data] = [:]
        var writtenKeychain: Data?
        do {
            for item in fileItems {
                let destination = resolve(relativePath: item.relativePath)
                if item.onlyIfDestinationExists == true,
                   !fileManager.fileExists(atPath: destination.path) {
                    continue
                }
                try hooks.beforeDestinationCheck?(destination)
                let current = fileManager.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
                let matchesBaseline = baselines[destination.path].map { current == $0 }
                    ?? (missingBaselines.contains(destination.path) && current == nil)
                guard matchesBaseline else {
                    throw CLISwitcherError.credentialConflict(destination.path)
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let written: Data
                switch item.kind {
                case .fullFile:
                    try item.contents.write(to: destination, options: [.atomic])
                    written = item.contents
                case .jsonFields:
                    written = try mergeJSONFields(
                        item.contents,
                        ownedKeys: item.ownedJSONKeys,
                        into: destination
                    )
                case .keychainJSONFields:
                    preconditionFailure("Keychain items are restored after files")
                }
                // Register the exact mutation before any later operation can
                // throw. Permission changes, injected checks, and validation
                // must all be able to roll this write back safely.
                touched.append(destination)
                writtenFiles[destination.path] = written
                try hooks.afterDestinationWrite?(destination)
                try fileManager.setAttributes(
                    [.posixPermissions: item.posixPermissions ?? 0o600],
                    ofItemAtPath: destination.path
                )
            }
            for item in keychainItems {
                let current = try readClaudeKeychainItem(
                    at: claudeKeychainItemLocation,
                    accessMode: accessMode
                )
                guard current == liveKeychainBackup else {
                    throw CLISwitcherError.credentialConflict(CLISwitcher.claudeKeychainItemPath)
                }
                let merged = try mergeClaudeAiOauth(item.contents, intoItemJSON: liveKeychainBackup)
                try writeClaudeKeychainItem(
                    merged,
                    at: claudeKeychainItemLocation,
                    accessMode: accessMode
                )
                writtenKeychain = merged
            }
            // Verification is part of the transaction: rollback material is
            // not deleted until the restored login identifies the target.
            try validateRestoredCredentials()
        } catch {
            let originalError = error
            var rollbackDisposition = credentialDisposition(from: originalError)
            var rollbackConflicts: [String] = []
            for destination in touched.reversed() {
                guard let written = writtenFiles[destination.path] else { continue }
                let current = try? Data(contentsOf: destination)
                guard current == written else {
                    rollbackConflicts.append(destination.path)
                    continue
                }
                do {
                    if let backupURL = baselineBackupURLs[destination.path] {
                        let baseline = try Data(contentsOf: backupURL)
                        try baseline.write(to: destination, options: [.atomic])
                        if let permissions = baselinePermissions[destination.path] {
                            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
                        }
                    } else if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                } catch let rollbackError {
                    rollbackDisposition = rollbackDisposition
                        ?? credentialDisposition(from: rollbackError)
                    rollbackConflicts.append(destination.path)
                }
            }
            if let writtenKeychain {
                do {
                    if try readClaudeKeychainItem(
                        at: claudeKeychainItemLocation,
                        accessMode: accessMode
                    ) == writtenKeychain {
                        if let liveKeychainBackup {
                            try writeClaudeKeychainItem(
                                liveKeychainBackup,
                                at: claudeKeychainItemLocation,
                                accessMode: accessMode
                            )
                        } else {
                            try deleteClaudeKeychainItem(
                                at: claudeKeychainItemLocation,
                                accessMode: accessMode
                            )
                        }
                    } else {
                        rollbackConflicts.append(CLISwitcher.claudeKeychainItemPath)
                    }
                } catch let rollbackError {
                    rollbackDisposition = rollbackDisposition
                        ?? credentialDisposition(from: rollbackError)
                    rollbackConflicts.append(CLISwitcher.claudeKeychainItemPath)
                }
            }
            if !rollbackConflicts.isEmpty {
                retainRecoveryDirectory = true
                throw CLISwitcherError.rollbackConflict(
                    paths: rollbackConflicts,
                    recoveryDirectory: restoreBackupDirectory,
                    underlying: originalError,
                    disposition: rollbackDisposition
                )
            }
            throw originalError
        }

        return touched
    }

    private func validateExpectedLiveFingerprint(
        _ expected: String??,
        provider: Provider,
        accessMode: CredentialAccessMode,
        claudeKeychainItemLocation: ClaudeKeychainItemLocation?,
        claudeKeychainItemData: Data?
    ) throws {
        guard let expected else { return }
        let observation: LiveCredentialObservation
        switch provider {
        case .codex:
            observation = try CodexCredentialAdapter(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ).observe(accessMode: accessMode)
        case .claude:
            observation = try ClaudeCredentialAdapter(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                credentialSource: claudeCredentialSource
            ).observe(
                liveItem: claudeKeychainItemData,
                location: claudeKeychainItemLocation
            )
        }
        guard observation.credentialFingerprint == expected else {
            throw CLISwitcherError.credentialConflict("live \(provider.displayName) credentials")
        }
    }

    private func readClaudeKeychainItem(
        at location: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        if let location {
            return try claudeCredentialSource.readLiveItemJSON(
                at: location,
                accessMode: accessMode
            )
        }
        return try claudeCredentialSource.readLiveItemJSON(accessMode: accessMode)
    }

    private func writeClaudeKeychainItem(
        _ data: Data,
        at location: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws {
        if let location {
            try claudeCredentialSource.writeLiveItemJSON(
                data,
                at: location,
                accessMode: accessMode
            )
        } else {
            try claudeCredentialSource.writeLiveItemJSON(data, accessMode: accessMode)
        }
    }

    private func deleteClaudeKeychainItem(
        at location: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws {
        if let location {
            try claudeCredentialSource.deleteLiveItem(
                at: location,
                accessMode: accessMode
            )
        } else {
            try claudeCredentialSource.deleteLiveItem(accessMode: accessMode)
        }
    }

    private func credentialDisposition(from error: Error) -> CredentialAccessDisposition? {
        if let error = error as? ClaudeCodeCredentialsKeychainError {
            return error.credentialAccessDisposition
        }
        if let error = error as? CredentialStoreError {
            return error.credentialAccessDisposition
        }
        if let error = error as? CLISwitcherError {
            return error.credentialAccessDisposition
        }
        return nil
    }

    private func resolve(relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(homeDirectory) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func mergeJSONFields(_ fieldsData: Data, ownedKeys: [String]?, into url: URL) throws -> Data {
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
        for key in ownedKeys ?? [] {
            destinationObject.removeValue(forKey: key)
        }
        for (key, value) in fields {
            destinationObject[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: destinationObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        return data
    }

    /// Converts snapshots from older builds that captured whole auth files into
    /// provider-owned field patches before a byte is written.
    private func normalized(_ item: CredentialSnapshotItem, provider: Provider) throws -> CredentialSnapshotItem {
        let ownedKeys: [String]?
        switch (provider, item.relativePath) {
        case (.codex, ".codex/auth.json"):
            ownedKeys = CodexCredentialAdapter.ownedKeys
        case (.claude, ".claude.json"):
            ownedKeys = ClaudeCredentialAdapter.accountOwnedKeys
        case (.claude, "Library/Application Support/Claude/config.json"):
            ownedKeys = ClaudeCredentialAdapter.configOwnedKeys
        default:
            ownedKeys = item.ownedJSONKeys
        }
        guard let ownedKeys, item.kind != .keychainJSONFields else { return item }
        guard let object = try JSONSerialization.jsonObject(with: item.contents) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(item.relativePath)
        }
        let fields = ownedKeys.reduce(into: [String: Any]()) { result, key in result[key] = object[key] }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return CredentialSnapshotItem(
            relativePath: item.relativePath,
            kind: .jsonFields,
            contents: data,
            posixPermissions: item.posixPermissions,
            ownedJSONKeys: ownedKeys,
            onlyIfDestinationExists: item.onlyIfDestinationExists ?? false
        )
    }

    private func appendMissingClaudeRemovalPatch(
        relativePath: String,
        ownedKeys: [String],
        to items: inout [CredentialSnapshotItem]
    ) {
        guard !items.contains(where: { $0.relativePath == relativePath }) else { return }
        items.append(
            CredentialSnapshotItem(
                relativePath: relativePath,
                kind: .jsonFields,
                contents: Data("{}".utf8),
                posixPermissions: nil,
                ownedJSONKeys: ownedKeys,
                onlyIfDestinationExists: true
            )
        )
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
