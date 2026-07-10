import Foundation

public enum CLISwitcherError: Error, LocalizedError {
    case missingCredentials(String)
    case missingStoredSnapshot(UUID)
    case providerMismatch(expected: Provider, actual: Provider)
    case invalidJSON(String)
    case backupFailed(path: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let path):
            return "No credential material was found at \(path)."
        case .missingStoredSnapshot(let id):
            return "No saved credential snapshot exists for account \(id.uuidString)."
        case .providerMismatch(let expected, let actual):
            return "Stored snapshot is for \(actual.displayName), not \(expected.displayName)."
        case .invalidJSON(let path):
            return "Could not parse JSON at \(path)."
        case .backupFailed(let path, let underlying):
            return "Could not back up \(path) before switching; nothing was changed. (\(underlying.localizedDescription))"
        }
    }
}

public final class CLISwitcher {
    /// Marker `relativePath` for the CLI's login-keychain credentials item;
    /// snapshot items with this path are keychain merges, not file writes.
    public static let claudeKeychainItemPath = "keychain/Claude Code-credentials"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let backupDirectory: URL
    private let credentialStore: CredentialStoreProtocol
    private let claudeCLICredentialSource: ClaudeCLICredentialSource

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL,
        credentialStore: CredentialStoreProtocol,
        fileManager: FileManager = .default,
        claudeCLICredentialSource: ClaudeCLICredentialSource = ClaudeCodeCredentialsKeychain()
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.credentialStore = credentialStore
        self.fileManager = fileManager
        self.claudeCLICredentialSource = claudeCLICredentialSource
    }

    public func captureAndStoreSnapshot(for profile: AccountProfile) throws -> CredentialSnapshot {
        var snapshot = try captureSnapshot(provider: profile.provider)

        // A logged-out terminal must not erase the profile's captured OAuth
        // token: when the fresh capture has no keychain item but the stored
        // snapshot does, carry the stored item over (it belonged to this
        // same profile).
        if profile.provider == .claude,
           !snapshot.items.contains(where: { $0.kind == .keychainJSONFields }),
           let stored = try credentialStore.loadSnapshot(for: profile.id),
           let keychainItem = stored.items.first(where: { $0.kind == .keychainJSONFields }) {
            snapshot.items.append(keychainItem)
        }

        try credentialStore.save(snapshot: snapshot, for: profile.id)
        return snapshot
    }

    public func captureSnapshot(provider: Provider) throws -> CredentialSnapshot {
        switch provider {
        case .codex:
            return try captureCodexSnapshot()
        case .claude:
            return try captureClaudeSnapshot()
        }
    }

    public func restoreSnapshot(for profile: AccountProfile) throws -> RestoreResult {
        guard let snapshot = try credentialStore.loadSnapshot(for: profile.id) else {
            throw CLISwitcherError.missingStoredSnapshot(profile.id)
        }

        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }

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
                liveKeychainBackup = try claudeCLICredentialSource.readLiveItemJSON()
            } catch {
                throw CLISwitcherError.backupFailed(path: Self.claudeKeychainItemPath, underlying: error)
            }
            if let liveKeychainBackup {
                do {
                    try fileManager.createDirectory(at: restoreBackupDirectory, withIntermediateDirectories: true)
                    let backup = restoreBackupDirectory
                        .appendingPathComponent(sanitizedBackupName(for: Self.claudeKeychainItemPath) + ".json")
                    try liveKeychainBackup.write(to: backup, options: [.atomic])
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    backups.append(backup)
                } catch {
                    throw CLISwitcherError.backupFailed(path: Self.claudeKeychainItemPath, underlying: error)
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
                try claudeCLICredentialSource.writeLiveItemJSON(merged)
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
                try claudeCLICredentialSource.writeLiveItemJSON(loggedOut)
                wroteKeychain = true
            }
        } catch {
            for (destination, backup) in backedUp {
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: backup, to: destination)
            }
            if wroteKeychain, let liveKeychainBackup {
                try? claudeCLICredentialSource.writeLiveItemJSON(liveKeychainBackup)
            }
            throw error
        }

        return RestoreResult(touchedPaths: touched, backupURLs: backups)
    }

    public func deleteStoredSnapshot(for profileID: UUID) throws {
        try credentialStore.deleteSnapshot(for: profileID)
    }

    public func currentIdentity(provider: Provider) -> AccountIdentity? {
        switch provider {
        case .claude:
            return ClaudeIdentityReader(homeDirectory: homeDirectory, fileManager: fileManager).readIdentity()
        case .codex:
            return CodexIdentityReader(homeDirectory: homeDirectory, fileManager: fileManager).readIdentity()
        }
    }

    public func hasStoredSnapshot(for profile: AccountProfile) throws -> Bool {
        try credentialStore.hasSnapshot(for: profile.id)
    }

    public func validateActiveLogin(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            let authURL = resolve(relativePath: ".codex/auth.json")
            return fileManager.fileExists(atPath: authURL.path) && ((try? Data(contentsOf: authURL).isEmpty) == false)
        case .claude:
            if liveClaudeOAuthCredentials() != nil {
                return true
            }
            if let fields = try? readClaudeConfigAuthFields(), !fields.isEmpty {
                return true
            }
            let claudeJSONURL = resolve(relativePath: ".claude.json")
            return containsAuthMaterial(in: claudeJSONURL)
        }
    }

    // MARK: - Claude OAuth credential access

    /// The CLI's current login tokens, straight from the login keychain.
    public func liveClaudeOAuthCredentials() -> ClaudeOAuthCredentials? {
        guard let item = try? claudeCLICredentialSource.readLiveItemJSON() else {
            return nil
        }
        return ClaudeOAuthCredentials.extract(fromKeychainItemJSON: item)
    }

    /// Merge-writes refreshed tokens into the live keychain item so the CLI
    /// keeps working after the app refreshes an access token (`mcpOAuth` and
    /// unknown siblings are preserved).
    public func writeLiveClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        // A thrown read must abort the write: collapsing it into nil would
        // merge into {} and drop the item's siblings (mcpOAuth). Only a
        // genuine nil (item absent) starts a fresh item.
        let live = try claudeCLICredentialSource.readLiveItemJSON()
        let merged = mergeClaudeAiOauth(credentials.rawClaudeAiOauth, intoItemJSON: live)
        try claudeCLICredentialSource.writeLiveItemJSON(merged)
    }

    /// The OAuth tokens captured into a profile's stored snapshot, if any.
    public func storedClaudeOAuthCredentials(for profileID: UUID) throws -> ClaudeOAuthCredentials? {
        guard let snapshot = try credentialStore.loadSnapshot(for: profileID),
              let item = snapshot.items.first(where: { $0.kind == .keychainJSONFields }) else {
            return nil
        }
        return ClaudeOAuthCredentials(claudeAiOauthJSON: item.contents)
    }

    /// Persists refreshed tokens back into the profile's stored snapshot so
    /// the next poll (and a later switch) starts from the fresh tokens.
    public func updateStoredClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials, for profileID: UUID) throws {
        guard var snapshot = try credentialStore.loadSnapshot(for: profileID) else {
            throw CLISwitcherError.missingStoredSnapshot(profileID)
        }
        if let index = snapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields }) {
            snapshot.items[index].contents = credentials.rawClaudeAiOauth
        } else {
            snapshot.items.append(
                CredentialSnapshotItem(
                    relativePath: Self.claudeKeychainItemPath,
                    kind: .keychainJSONFields,
                    contents: credentials.rawClaudeAiOauth,
                    posixPermissions: nil
                )
            )
        }
        try credentialStore.save(snapshot: snapshot, for: profileID)
    }

    /// The raw `~/.codex/auth.json` captured into a profile's stored snapshot,
    /// if any — lets identity and plan tier be derived for an inactive Codex
    /// account without launching the CLI. Mirrors
    /// `storedClaudeOAuthCredentials` for the Claude side.
    public func storedCodexAuthJSON(for profileID: UUID) throws -> Data? {
        guard let snapshot = try credentialStore.loadSnapshot(for: profileID),
              let item = snapshot.items.first(where: {
                  $0.kind == .fullFile && $0.relativePath == ".codex/auth.json"
              }) else {
            return nil
        }
        return item.contents
    }

    public func hasActiveProcesses(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            return runPgrep(arguments: ["-x", "codex"])
        case .claude:
            return runPgrep(arguments: ["-f", "(^|/)claude( |$)|Claude Code"])
        }
    }

    private func captureCodexSnapshot() throws -> CredentialSnapshot {
        let relativePath = ".codex/auth.json"
        let authURL = resolve(relativePath: relativePath)
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }
        let data = try Data(contentsOf: authURL)
        guard !data.isEmpty else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }

        return CredentialSnapshot(
            provider: .codex,
            items: [
                CredentialSnapshotItem(
                    relativePath: relativePath,
                    kind: .fullFile,
                    contents: data,
                    posixPermissions: filePermissions(authURL)
                )
            ]
        )
    }

    private func captureClaudeSnapshot() throws -> CredentialSnapshot {
        var items: [CredentialSnapshotItem] = []

        // The CLI's tokens live in the login keychain; capturing them per
        // profile is what makes switching and per-account API polling work
        // for modern Claude Code. A failed read aborts the capture — a
        // transient keychain error must never be mistaken for "logged out"
        // and produce a snapshot missing the tokens.
        if let liveItem = try claudeCLICredentialSource.readLiveItemJSON(),
           let credentials = ClaudeOAuthCredentials.extract(fromKeychainItemJSON: liveItem) {
            items.append(
                CredentialSnapshotItem(
                    relativePath: Self.claudeKeychainItemPath,
                    kind: .keychainJSONFields,
                    contents: credentials.rawClaudeAiOauth,
                    posixPermissions: nil
                )
            )
        }

        let configRelativePath = "Library/Application Support/Claude/config.json"
        let fields = try readClaudeConfigAuthFields()
        if !fields.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            let configURL = resolve(relativePath: configRelativePath)
            items.append(
                CredentialSnapshotItem(
                    relativePath: configRelativePath,
                    kind: .jsonFields,
                    contents: data,
                    posixPermissions: filePermissions(configURL)
                )
            )
        }

        let claudeJSONRelativePath = ".claude.json"
        let claudeJSONURL = resolve(relativePath: claudeJSONRelativePath)
        if containsAuthMaterial(in: claudeJSONURL) {
            items.append(
                CredentialSnapshotItem(
                    relativePath: claudeJSONRelativePath,
                    kind: .fullFile,
                    contents: try Data(contentsOf: claudeJSONURL),
                    posixPermissions: filePermissions(claudeJSONURL)
                )
            )
        }

        guard !items.isEmpty else {
            throw CLISwitcherError.missingCredentials("Claude OAuth token cache")
        }

        return CredentialSnapshot(provider: .claude, items: items)
    }

    private func readClaudeConfigAuthFields() throws -> [String: Any] {
        let configURL = resolve(relativePath: "Library/Application Support/Claude/config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(configURL.path)
        }

        let knownAuthKeys = [
            "oauth:tokenCache",
            "oauth:tokenCacheV2"
        ]

        var fields: [String: Any] = [:]
        for key in knownAuthKeys {
            if let value = object[key] {
                fields[key] = value
            }
        }
        return fields
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

    private func containsAuthMaterial(in url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsAuthMaterial(inJSONObject: json)
    }

    private func containsAuthMaterial(inJSONObject value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let lower = key.lowercased()
                if lower.contains("oauth")
                    || lower == "access_token"
                    || lower == "refresh_token"
                    || lower == "id_token"
                    || lower == "session_token" {
                    return true
                }
                if containsAuthMaterial(inJSONObject: nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsAuthMaterial(inJSONObject:))
        }
        return false
    }

    private func resolve(relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(homeDirectory) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }

    private func filePermissions(_ url: URL) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.posixPermissions] as? Int
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

    private func runPgrep(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
