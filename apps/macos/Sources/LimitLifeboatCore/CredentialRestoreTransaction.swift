import Foundation

struct CredentialRestoreHooks {
    var beforeDestinationCheck: ((URL) throws -> Void)?
    var beforeDestinationWrite: ((URL) throws -> Void)?
    var beforeKeychainWrite: (() throws -> Void)?
    var afterDestinationWrite: ((URL) throws -> Void)?

    init(
        beforeDestinationCheck: ((URL) throws -> Void)? = nil,
        beforeDestinationWrite: ((URL) throws -> Void)? = nil,
        beforeKeychainWrite: (() throws -> Void)? = nil,
        afterDestinationWrite: ((URL) throws -> Void)? = nil
    ) {
        self.beforeDestinationCheck = beforeDestinationCheck
        self.beforeDestinationWrite = beforeDestinationWrite
        self.beforeKeychainWrite = beforeKeychainWrite
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
    private let validateMutationLease: (() throws -> Void)?

    init(
        homeDirectory: URL,
        backupDirectory: URL,
        fileManager: FileManager,
        claudeCredentialSource: ClaudeCLICredentialSource,
        hooks: CredentialRestoreHooks = .none,
        validateMutationLease: (() throws -> Void)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.claudeCredentialSource = claudeCredentialSource
        self.hooks = hooks
        self.validateMutationLease = validateMutationLease
    }

    func restore(
        _ snapshot: CredentialSnapshot,
        expectedLiveFingerprint: String?? = nil,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        claudeKeychainItemLocation: ClaudeKeychainItemLocation? = nil,
        validateRestoredCredentials: (ClaudeKeychainItemLocation?) throws -> Void
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
        var baselineFileGenerations: [String: FileGenerationStamp] = [:]
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
                do {
                    baselineFileGenerations[destination.path] =
                        try fileGenerationStamp(at: destination)
                } catch {
                    throw CLISwitcherError.backupFailed(
                        path: destination.path,
                        underlying: error
                    )
                }
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
            if claudeCredentialSource.supportsExactItemLocations,
               !keychainItems.isEmpty,
               (claudeKeychainItemLocation == nil || liveKeychainBackup == nil) {
                throw CLISwitcherError.backupFailed(
                    path: CLISwitcher.claudeKeychainItemPath,
                    underlying: ClaudeCodeCredentialsKeychainError.missingLiveItem
                )
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
        try validateMutationLease?()

        // Phase 2: write all items; on failure roll back from the backups.
        // The keychain merge goes last so a file failure never leaves the CLI
        // logged into a half-switched account.
        var touched: [URL] = []
        var writtenFiles: [String: Data] = [:]
        var writtenFileGenerations: [String: FileGenerationStamp] = [:]
        var writtenKeychain: Data?
        var keychainWriteRequiresReconciliation = false
        var currentClaudeKeychainItemLocation = claudeKeychainItemLocation
        do {
            for item in fileItems {
                try validateMutationLease?()
                let destination = resolve(relativePath: item.relativePath)
                if item.onlyIfDestinationExists == true,
                   !fileManager.fileExists(atPath: destination.path) {
                    continue
                }
                try hooks.beforeDestinationCheck?(destination)
                let current = fileManager.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil
                let matchesBaseline = baselineMatchesCurrentFile(
                    at: destination,
                    currentData: current,
                    baselines: baselines,
                    baselineGenerations: baselineFileGenerations,
                    missingBaselines: missingBaselines
                )
                guard matchesBaseline else {
                    throw CLISwitcherError.credentialConflict(destination.path)
                }
                try validateMutationLease?()
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let written: Data
                switch item.kind {
                case .fullFile:
                    written = item.contents
                case .jsonFields:
                    written = try mergeJSONFields(
                        item.contents,
                        ownedKeys: item.ownedJSONKeys,
                        into: current,
                        destinationPath: destination.path
                    )
                case .keychainJSONFields:
                    preconditionFailure("Keychain items are restored after files")
                }
                try hooks.beforeDestinationWrite?(destination)
                try validateMutationLease?()
                let finalCurrent =
                    fileManager.fileExists(atPath: destination.path)
                    ? try Data(contentsOf: destination)
                    : nil
                guard baselineMatchesCurrentFile(
                    at: destination,
                    currentData: finalCurrent,
                    baselines: baselines,
                    baselineGenerations: baselineFileGenerations,
                    missingBaselines: missingBaselines
                ) else {
                    throw CLISwitcherError.credentialConflict(
                        destination.path
                    )
                }
                try written.write(to: destination, options: [.atomic])
                // Register the exact mutation before any later operation can
                // throw. Permission changes, injected checks, and validation
                // must all be able to roll this write back safely.
                touched.append(destination)
                writtenFiles[destination.path] = written
                writtenFileGenerations[destination.path] =
                    try fileGenerationStamp(at: destination)
                try hooks.afterDestinationWrite?(destination)
                try validateMutationLease?()
                try fileManager.setAttributes(
                    [.posixPermissions: item.posixPermissions ?? 0o600],
                    ofItemAtPath: destination.path
                )
            }
            for item in keychainItems {
                try validateMutationLease?()
                let current = try readClaudeKeychainItem(
                    at: currentClaudeKeychainItemLocation,
                    accessMode: accessMode
                )
                guard current == liveKeychainBackup else {
                    throw CLISwitcherError.credentialConflict(CLISwitcher.claudeKeychainItemPath)
                }
                let merged = try mergeClaudeAiOauth(item.contents, intoItemJSON: liveKeychainBackup)
                try hooks.beforeKeychainWrite?()
                let mutationAttempt = ClaudeCredentialWriteAttempt()
                let reportsMutationStart =
                    currentClaudeKeychainItemLocation != nil
                    && claudeCredentialSource is any ClaudeCredentialWriteReporting
                do {
                    try writeClaudeKeychainItem(
                        merged,
                        at: currentClaudeKeychainItemLocation,
                        accessMode: accessMode,
                        mutationAttempt: mutationAttempt
                    )
                    // The source completed its helper and full-value
                    // verification. Record that an exact provider item may
                    // now differ before the post-helper lease check can throw.
                    if currentClaudeKeychainItemLocation != nil {
                        // Legacy Keychain modification dates have one-second
                        // granularity, so even a matching post-write stamp
                        // cannot prove that a rapid same-byte outside update
                        // belongs to this transaction. Never auto-rollback an
                        // exact provider-owned item after the helper ran.
                        keychainWriteRequiresReconciliation = true
                    } else {
                        writtenKeychain = merged
                    }
                } catch {
                    // A helper can commit and then fail its identity/value
                    // verification. Preserve enough information to reconcile
                    // that uncertain outcome, but do not invent a mutation
                    // when a final pre-helper lease or authorization check
                    // proves the process never started.
                    switch keychainWriteOutcome(
                        after: error,
                        mutationAttempt: mutationAttempt,
                        reportsMutationStart: reportsMutationStart
                    ) {
                    case .confirmed:
                        keychainWriteRequiresReconciliation = true
                    case .uncertain:
                        keychainWriteRequiresReconciliation = true
                    case .notCommitted:
                        break
                    }
                    throw error
                }
                try validateMutationLease?()
                currentClaudeKeychainItemLocation = try refreshedClaudeKeychainItemLocation(
                    matching: currentClaudeKeychainItemLocation,
                    accessMode: accessMode
                )
            }
            // Verification is part of the transaction: rollback material is
            // not deleted until the restored login identifies the target.
            try validateMutationLease?()
            try validateRestoredCredentials(currentClaudeKeychainItemLocation)
        } catch {
            let originalError = error
            var rollbackDisposition = credentialDisposition(from: originalError)
            var rollbackFailure: Error?
            var rollbackConflicts: [String] = []
            for destination in touched.reversed() {
                guard let written = writtenFiles[destination.path],
                      let writtenGeneration =
                          writtenFileGenerations[destination.path] else {
                    rollbackConflicts.append(destination.path)
                    continue
                }
                let generationBeforeRead =
                    try? fileGenerationStamp(at: destination)
                let current = try? Data(contentsOf: destination)
                let generationAfterRead =
                    try? fileGenerationStamp(at: destination)
                guard current == written,
                      generationBeforeRead == writtenGeneration,
                      generationAfterRead == writtenGeneration else {
                    rollbackConflicts.append(destination.path)
                    continue
                }
                do {
                    // Rollback is still a provider-owned Claude mutation. If
                    // the shared lease was replaced after our forward write,
                    // preserve the exact recovery backup and leave the current
                    // bytes untouched for explicit repair.
                    try validateMutationLease?()
                    if let backupURL = baselineBackupURLs[destination.path] {
                        let baseline = try Data(contentsOf: backupURL)
                        try validateMutationLease?()
                        guard try fileGenerationStamp(at: destination)
                            == writtenGeneration else {
                            throw FileRollbackGenerationChanged()
                        }
                        try baseline.write(to: destination, options: [.atomic])
                        let restoredGeneration =
                            try fileGenerationStamp(at: destination)
                        try validateMutationLease?()
                        if let permissions = baselinePermissions[destination.path] {
                            guard try fileGenerationStamp(at: destination)
                                == restoredGeneration else {
                                throw FileRollbackGenerationChanged()
                            }
                            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
                            try validateMutationLease?()
                        }
                    } else if fileManager.fileExists(atPath: destination.path) {
                        try validateMutationLease?()
                        guard try fileGenerationStamp(at: destination)
                            == writtenGeneration else {
                            throw FileRollbackGenerationChanged()
                        }
                        try fileManager.removeItem(at: destination)
                        try validateMutationLease?()
                    }
                } catch is FileRollbackGenerationChanged {
                    rollbackConflicts.append(destination.path)
                } catch let rollbackError {
                    rollbackDisposition =
                        credentialDisposition(from: rollbackError)
                        ?? rollbackDisposition
                    rollbackFailure = rollbackFailure ?? rollbackError
                    rollbackConflicts.append(destination.path)
                }
            }
            if let writtenKeychain {
                do {
                    try validateMutationLease?()
                    let rollbackLocation = try refreshedClaudeKeychainItemLocation(
                        matching: currentClaudeKeychainItemLocation
                            ?? claudeKeychainItemLocation,
                        accessMode: accessMode
                    )
                    let current = try readClaudeKeychainItem(
                        at: rollbackLocation,
                        accessMode: accessMode
                    )
                    if current == writtenKeychain {
                        if let liveKeychainBackup {
                            try writeClaudeKeychainItem(
                                liveKeychainBackup,
                                at: rollbackLocation,
                                accessMode: accessMode,
                                mutationAttempt: ClaudeCredentialWriteAttempt()
                            )
                            try validateMutationLease?()
                        } else {
                            // Limit Lifeboat never creates or deletes Claude's
                            // provider-owned item. An item appearing where the
                            // baseline was absent is an ambiguous external
                            // generation and must be left for explicit repair.
                            rollbackConflicts.append(CLISwitcher.claudeKeychainItemPath)
                        }
                    } else if current != liveKeychainBackup {
                        // The forward write either lost an item-replacement
                        // race or another client changed the value. Preserve
                        // that outside generation instead of broad-writing a
                        // stale rollback value.
                        rollbackConflicts.append(CLISwitcher.claudeKeychainItemPath)
                    }
                } catch let rollbackError {
                    rollbackDisposition =
                        credentialDisposition(from: rollbackError)
                        ?? rollbackDisposition
                    rollbackFailure = rollbackFailure ?? rollbackError
                    rollbackConflicts.append(CLISwitcher.claudeKeychainItemPath)
                }
            }
            if keychainWriteRequiresReconciliation {
                do {
                    try validateMutationLease?()
                    let observedLocation = try refreshedClaudeKeychainItemLocation(
                        matching: currentClaudeKeychainItemLocation
                            ?? claudeKeychainItemLocation,
                        accessMode: accessMode
                    )
                    let current = try readClaudeKeychainItem(
                        at: observedLocation,
                        accessMode: accessMode
                    )
                    if current != liveKeychainBackup {
                        // Legacy Keychain metadata cannot uniquely attribute
                        // rapid same-byte updates. Once the helper may have
                        // written, preserve any non-baseline value, retain the
                        // exact recovery material, and require explicit retry
                        // instead of risking a stale rollback.
                        rollbackConflicts.append(
                            CLISwitcher.claudeKeychainItemPath
                        )
                    }
                } catch let rollbackError {
                    rollbackDisposition =
                        credentialDisposition(from: rollbackError)
                        ?? rollbackDisposition
                    rollbackFailure = rollbackFailure ?? rollbackError
                    rollbackConflicts.append(
                        CLISwitcher.claudeKeychainItemPath
                    )
                }
            }
            if !rollbackConflicts.isEmpty {
                retainRecoveryDirectory = true
                throw CLISwitcherError.rollbackConflict(
                    paths: rollbackConflicts,
                    recoveryDirectory: restoreBackupDirectory,
                    underlying: rollbackFailure ?? originalError,
                    disposition: rollbackDisposition
                )
            }
            throw originalError
        }

        return touched
    }

    /// A successful Keychain update keeps the persistent identity but advances
    /// the modification generation. Re-resolve that same identity before any
    /// post-write read; carrying the pre-write stamp would make our own update
    /// look like an outside replacement.
    private func refreshedClaudeKeychainItemLocation(
        matching expected: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeKeychainItemLocation? {
        guard claudeCredentialSource.supportsExactItemLocations else {
            return expected
        }
        guard let expected,
              let current = try claudeCredentialSource.locateLiveItem(
                  accessMode: accessMode
              ),
              current.identity == expected.identity else {
            throw ClaudeCodeCredentialsKeychainError.securityToolError(
                .itemChanged
            )
        }
        return current
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
        accessMode: CredentialAccessMode,
        mutationAttempt: ClaudeCredentialWriteAttempt
    ) throws {
        try validateMutationLease?()
        if let location,
           let reportingSource =
               claudeCredentialSource as? any ClaudeCredentialWriteReporting {
            try reportingSource.writeLiveItemJSON(
                data,
                at: location,
                accessMode: accessMode,
                mutationAttempt: mutationAttempt
            )
        } else if let location {
            try claudeCredentialSource.writeLiveItemJSON(
                data,
                at: location,
                accessMode: accessMode
            )
        } else {
            try claudeCredentialSource.writeLiveItemJSON(data, accessMode: accessMode)
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

    private enum KeychainWriteOutcome {
        case notCommitted
        case confirmed
        case uncertain
    }

    private struct FileGenerationStamp: Equatable {
        let systemNumber: UInt64
        let systemFileNumber: UInt64
        let size: UInt64
        let modificationDate: Date
    }

    private struct FileGenerationUnavailable: Error {}
    private struct FileRollbackGenerationChanged: Error {}

    private func fileGenerationStamp(at url: URL) throws -> FileGenerationStamp {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let systemNumber =
                  (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let systemFileNumber =
                  (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw FileGenerationUnavailable()
        }
        return FileGenerationStamp(
            systemNumber: systemNumber,
            systemFileNumber: systemFileNumber,
            size: size,
            modificationDate: modificationDate
        )
    }

    private func baselineMatchesCurrentFile(
        at url: URL,
        currentData: Data?,
        baselines: [String: Data],
        baselineGenerations: [String: FileGenerationStamp],
        missingBaselines: Set<String>
    ) -> Bool {
        if let baseline = baselines[url.path],
           let baselineGeneration = baselineGenerations[url.path] {
            guard currentData == baseline,
                  let generationBeforeRead =
                      try? fileGenerationStamp(at: url),
                  generationBeforeRead == baselineGeneration,
                  let generationAfterRead =
                      try? fileGenerationStamp(at: url),
                  generationAfterRead == baselineGeneration else {
                return false
            }
            return true
        }
        return missingBaselines.contains(url.path) && currentData == nil
    }

    private func keychainWriteOutcome(
        after error: Error,
        mutationAttempt: ClaudeCredentialWriteAttempt,
        reportsMutationStart: Bool
    ) -> KeychainWriteOutcome {
        if let error = error as? ClaudeCodeCredentialsKeychainError,
           case .securityToolError(.itemChanged) = error {
            // An item/generation change is authoritative regardless of whether
            // our upsert helper had started. Coincidentally equal bytes are
            // never permission to roll that outside change back.
            return mutationAttempt.helperStarted ? .uncertain : .notCommitted
        }
        if reportsMutationStart {
            if mutationAttempt.helperSucceeded {
                return .confirmed
            }
            guard mutationAttempt.helperStarted else {
                return .notCommitted
            }
            // A launched helper with no success result is normally known not
            // to have committed for authorization/cancellation failures.
            // Timeout and opaque helper failures remain uncertain and are
            // reconciled against the exact baseline/intended bytes.
            if let error = error as? ClaudeCodeCredentialsKeychainError {
                switch error {
                case .securityToolError(let toolError):
                    switch toolError {
                    case .authorizationDenied, .userCancelled,
                         .keychainLocked, .invalidArgument,
                         .payloadTooLarge:
                        return .notCommitted
                    case .itemChanged:
                        return .notCommitted
                    case .toolFailed(let exitCode):
                        return exitCode == nil ? .uncertain : .notCommitted
                    case .toolTimedOut:
                        return .uncertain
                    case .malformedToolOutput, .verificationFailed:
                        return .uncertain
                    }
                case .credentialAccessUnavailable, .missingLiveItem,
                     .itemIdentityMismatch, .unsupportedSecurityToolAccess:
                    return .notCommitted
                case .duplicateLiveItems, .malformedItemMetadata,
                     .malformedCredentialJSON, .keychainError:
                    return .uncertain
                }
            }
            return .uncertain
        }
        if error is ClaudeOAuthRefreshCoordinatorError {
            // The transaction helper performs its lease validation before it
            // enters a non-reporting credential source. Post-helper lease
            // validation is deliberately outside the source call, after a
            // successful return has registered the write.
            return .notCommitted
        }
        guard let error = error as? ClaudeCodeCredentialsKeychainError else {
            // A source without phase reporting cannot prove that matching
            // target bytes belong to this transaction.
            return .uncertain
        }
        switch error {
        case .credentialAccessUnavailable, .missingLiveItem,
             .itemIdentityMismatch, .unsupportedSecurityToolAccess:
            return .notCommitted
        case .securityToolError(let toolError):
            switch toolError {
            case .authorizationDenied, .userCancelled, .keychainLocked,
                 .invalidArgument, .payloadTooLarge:
                return .notCommitted
            case .itemChanged:
                return .notCommitted
            case .toolFailed(let exitCode):
                return exitCode == nil ? .uncertain : .notCommitted
            case .malformedToolOutput, .verificationFailed,
                 .toolTimedOut:
                return .uncertain
            }
        case .duplicateLiveItems, .malformedItemMetadata,
             .malformedCredentialJSON, .keychainError:
            return .uncertain
        }
    }

    private func resolve(relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(homeDirectory) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func mergeJSONFields(
        _ fieldsData: Data,
        ownedKeys: [String]?,
        into destinationData: Data?,
        destinationPath: String
    ) throws -> Data {
        guard let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(destinationPath)
        }
        var destinationObject: [String: Any] = [:]
        if let destinationData {
            guard let parsed = try JSONSerialization.jsonObject(with: destinationData) as? [String: Any] else {
                throw CLISwitcherError.invalidJSON(destinationPath)
            }
            destinationObject = parsed
        }
        for key in ownedKeys ?? [] {
            destinationObject.removeValue(forKey: key)
        }
        for (key, value) in fields {
            destinationObject[key] = value
        }
        return try JSONSerialization.data(withJSONObject: destinationObject, options: [.prettyPrinted, .sortedKeys])
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
