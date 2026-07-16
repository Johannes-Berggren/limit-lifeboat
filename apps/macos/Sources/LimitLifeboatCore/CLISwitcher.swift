import Foundation

public enum CLISwitcherError: Error, LocalizedError {
    case missingCredentials(String)
    case missingStoredSnapshot(UUID)
    case providerMismatch(expected: Provider, actual: Provider)
    case invalidJSON(String)
    case backupFailed(path: String, underlying: Error)
    case credentialConflict(String)
    case restoreValidationFailed(provider: Provider, reason: String)
    case rollbackConflict(paths: [String], recoveryDirectory: URL, underlying: Error)

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
        case .credentialConflict(let path):
            return "Credentials changed in another app at \(path). The outside change was preserved; refresh and try again."
        case .restoreValidationFailed(let provider, let reason):
            return "The restored \(provider.displayName) login could not be verified, so the previous login was restored. \(reason)"
        case .rollbackConflict(let paths, let recoveryDirectory, let underlying):
            return "The switch failed and outside changes were preserved at \(paths.joined(separator: ", ")). Recovery files are at \(recoveryDirectory.path). \(underlying.localizedDescription)"
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
    private let codexCredentials: CodexCredentialAdapter
    private let claudeCredentials: ClaudeCredentialAdapter

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
        self.codexCredentials = CodexCredentialAdapter(homeDirectory: homeDirectory, fileManager: fileManager)
        self.claudeCredentials = ClaudeCredentialAdapter(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            credentialSource: claudeCLICredentialSource
        )
    }

    public func captureAndStoreSnapshot(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> CredentialSnapshot {
        let observation = try liveObservation(provider: profile.provider, accessMode: accessMode)
        return try storeObservation(observation, for: profile, accessMode: accessMode)
    }

    public func storeObservation(
        _ observation: LiveCredentialObservation,
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> CredentialSnapshot {
        guard observation.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: observation.provider)
        }
        guard var snapshot = observation.snapshot else {
            throw CLISwitcherError.missingCredentials(profile.provider.displayName)
        }
        if let liveIdentity = observation.identity,
           let profileIdentity = profile.identity,
           !profileIdentity.matches(liveIdentity) {
            throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) identity")
        }

        // A logged-out terminal must not erase the profile's captured OAuth
        // token: when the fresh capture has no keychain item but the stored
        // snapshot does, carry the stored item over (it belonged to this
        // same profile).
        if profile.provider == .claude,
           !snapshot.items.contains(where: { $0.kind == .keychainJSONFields }),
           let stored = try credentialStore.loadSnapshot(for: profile.id, accessMode: accessMode),
           let keychainItem = stored.items.first(where: { $0.kind == .keychainJSONFields }) {
            snapshot.items.append(keychainItem)
        }

        try credentialStore.save(snapshot: snapshot, for: profile.id, accessMode: accessMode)
        return snapshot
    }

    public func liveObservation(
        provider: Provider,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> LiveCredentialObservation {
        switch provider {
        case .codex:
            return try codexCredentials.observe(accessMode: accessMode)
        case .claude:
            return try claudeCredentials.observe(accessMode: accessMode)
        }
    }

    /// A short, synchronous stabilization gate for explicit capture/switch
    /// actions. File-driven/background paths use the async equivalent in
    /// AppState so they do not block the main actor.
    public func stableLiveObservation(
        provider: Provider,
        delay: TimeInterval = 0.25,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> LiveCredentialObservation {
        let first = try liveObservation(provider: provider, accessMode: accessMode)
        Thread.sleep(forTimeInterval: delay)
        let second = try liveObservation(provider: provider, accessMode: accessMode)
        guard first.stabilityKey == second.stabilityKey else {
            throw CLISwitcherError.credentialConflict("live \(provider.displayName) credentials")
        }
        return second
    }

    public func captureSnapshot(
        provider: Provider,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> CredentialSnapshot {
        switch provider {
        case .codex:
            return try codexCredentials.captureSnapshot(accessMode: accessMode)
        case .claude:
            return try claudeCredentials.captureSnapshot(accessMode: accessMode)
        }
    }

    public func restoreSnapshot(
        for profile: AccountProfile,
        expectedLiveFingerprint: String? = nil,
        enforceExpectedLiveState: Bool = false,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> RestoreResult {
        guard let snapshot = try credentialStore.loadSnapshot(for: profile.id, accessMode: accessMode) else {
            throw CLISwitcherError.missingStoredSnapshot(profile.id)
        }
        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }
        guard isRestorable(snapshot, for: profile.provider) else {
            throw CLISwitcherError.missingCredentials(
                "saved \(profile.provider.displayName) account snapshot"
            )
        }
        let shouldEnforceLiveState = enforceExpectedLiveState || expectedLiveFingerprint != nil
        if shouldEnforceLiveState {
            let actual = try liveObservation(provider: profile.provider, accessMode: accessMode).credentialFingerprint
            guard actual == expectedLiveFingerprint else {
                throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) credentials")
            }
        }
        let targetFingerprint = CredentialFingerprint.make(for: snapshot)
        var verifiedObservation: LiveCredentialObservation?
        let touchedPaths = try CredentialRestoreTransaction(
            homeDirectory: homeDirectory,
            backupDirectory: backupDirectory,
            fileManager: fileManager,
            claudeCredentialSource: claudeCLICredentialSource
        ).restore(
            snapshot,
            expectedLiveFingerprint: shouldEnforceLiveState ? .some(expectedLiveFingerprint) : nil,
            accessMode: accessMode,
            validateRestoredCredentials: { [self] in
                let observation: LiveCredentialObservation
                do {
                    observation = try liveObservation(provider: profile.provider, accessMode: accessMode)
                } catch {
                    throw CLISwitcherError.restoreValidationFailed(
                        provider: profile.provider,
                        reason: error.localizedDescription
                    )
                }
                let targetMatches: Bool
                if let expectedIdentity = profile.identity {
                    targetMatches = observation.identity.map(expectedIdentity.matches) == true
                } else {
                    // Legacy and manually created profiles may not have an
                    // identity yet. Their captured credential bytes are the
                    // strongest target signal available. A labeled profile,
                    // however, must never let this fallback override an
                    // observed identity mismatch.
                    targetMatches = observation.credentialFingerprint == targetFingerprint
                }
                guard observation.isLoggedIn, targetMatches else {
                    throw CLISwitcherError.restoreValidationFailed(
                        provider: profile.provider,
                        reason: "The live credentials did not identify \(profile.label)."
                    )
                }
                verifiedObservation = observation
            }
        )
        guard let verifiedObservation else {
            preconditionFailure("Credential restore returned without running validation")
        }
        return RestoreResult(
            touchedPaths: touchedPaths,
            verifiedObservation: verifiedObservation
        )
    }

    public func deleteStoredSnapshot(
        for profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        try credentialStore.deleteSnapshot(for: profileID, accessMode: accessMode)
    }

    public func currentIdentity(
        provider: Provider,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) -> AccountIdentity? {
        (try? liveObservation(provider: provider, accessMode: accessMode))?.identity
    }

    public func hasStoredSnapshot(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        try credentialStore.hasSnapshot(for: profile.id, accessMode: accessMode)
    }

    /// A stored item can contain only non-login metadata (legacy Claude
    /// config fields). Such an item is useful for identity reconciliation but
    /// must never be offered as a switch target: restoring it used to strip
    /// the current live OAuth login.
    public func hasRestorableSnapshot(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        guard let snapshot = try credentialStore.loadSnapshot(
            for: profile.id,
            accessMode: accessMode
        ), snapshot.provider == profile.provider else {
            return false
        }
        return isRestorable(snapshot, for: profile.provider)
    }

    private func isRestorable(_ snapshot: CredentialSnapshot, for provider: Provider) -> Bool {
        switch provider {
        case .claude:
            return snapshot.items.contains { $0.kind == .keychainJSONFields }
        case .codex:
            return snapshot.items.contains {
                ($0.kind == .jsonFields || $0.kind == .fullFile)
                    && $0.relativePath == ".codex/auth.json"
            }
        }
    }

    public func storedCredentialFingerprint(
        for profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> String? {
        try credentialStore.loadSnapshot(for: profileID, accessMode: accessMode).map(CredentialFingerprint.make(for:))
    }

    public func validateActiveLogin(
        provider: Provider,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) -> Bool {
        switch provider {
        case .codex:
            return codexCredentials.validateActiveLogin(accessMode: accessMode)
        case .claude:
            return claudeCredentials.validateActiveLogin(accessMode: accessMode)
        }
    }

    // MARK: - Claude OAuth credential access

    /// The CLI's current login tokens, straight from the login keychain.
    public func liveClaudeOAuthCredentials(
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> ClaudeOAuthCredentials? {
        guard let item = try claudeCLICredentialSource.readLiveItemJSON(accessMode: accessMode) else { return nil }
        return ClaudeOAuthCredentials.extract(fromKeychainItemJSON: item)
    }

    /// Merge-writes refreshed tokens into the live keychain item so the CLI
    /// keeps working after the app refreshes an access token (`mcpOAuth` and
    /// unknown siblings are preserved).
    public func writeLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        // A thrown read must abort the write: collapsing it into nil would
        // merge into {} and drop the item's siblings (mcpOAuth). Only a
        // genuine nil (item absent) starts a fresh item.
        let live = try claudeCLICredentialSource.readLiveItemJSON(accessMode: accessMode)
        let merged = mergeClaudeAiOauth(credentials.rawClaudeAiOauth, intoItemJSON: live)
        try claudeCLICredentialSource.writeLiveItemJSON(merged, accessMode: accessMode)
    }

    @discardableResult
    public func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        let live = try claudeCLICredentialSource.readLiveItemJSON(accessMode: accessMode)
        guard live.flatMap({ ClaudeOAuthCredentials.extract(fromKeychainItemJSON: $0) })?.accessToken == expectedAccessToken else {
            return false
        }
        let merged = mergeClaudeAiOauth(credentials.rawClaudeAiOauth, intoItemJSON: live)
        // Re-read at the last mutation boundary. Keychain has no cross-process
        // compare-and-swap, but this prevents every detectable outside change.
        guard try claudeCLICredentialSource.readLiveItemJSON(accessMode: accessMode) == live else {
            return false
        }
        try claudeCLICredentialSource.writeLiveItemJSON(merged, accessMode: accessMode)
        return true
    }

    /// The OAuth tokens captured into a profile's stored snapshot, if any.
    public func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> ClaudeOAuthCredentials? {
        guard let snapshot = try credentialStore.loadSnapshot(for: profileID, accessMode: accessMode),
              let item = snapshot.items.first(where: { $0.kind == .keychainJSONFields }) else {
            return nil
        }
        return ClaudeOAuthCredentials(claudeAiOauthJSON: item.contents)
    }

    /// Persists refreshed tokens back into the profile's stored snapshot so
    /// the next poll (and a later switch) starts from the fresh tokens.
    public func updateStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        guard var snapshot = try credentialStore.loadSnapshot(for: profileID, accessMode: accessMode) else {
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
        try credentialStore.save(snapshot: snapshot, for: profileID, accessMode: accessMode)
    }

    @discardableResult
    public func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        guard try storedClaudeOAuthCredentials(for: profileID, accessMode: accessMode)?.accessToken == expectedAccessToken else {
            return false
        }
        try updateStoredClaudeOAuthCredentials(credentials, for: profileID, accessMode: accessMode)
        return true
    }

    /// The raw `~/.codex/auth.json` captured into a profile's stored snapshot,
    /// if any — lets identity and plan tier be derived for an inactive Codex
    /// account without launching the CLI. Mirrors
    /// `storedClaudeOAuthCredentials` for the Claude side.
    public func storedCodexAuthJSON(
        for profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Data? {
        guard let snapshot = try credentialStore.loadSnapshot(for: profileID, accessMode: accessMode),
              let item = snapshot.items.first(where: Self.isCodexAuthItem) else {
            return nil
        }
        return item.contents
    }

    /// Replaces a stored Codex auth document only while the complete semantic
    /// snapshot still matches the one that was preflighted. This prevents a
    /// rotated refresh token from overwriting a newer capture made while the
    /// app-server request was in flight.
    @discardableResult
    public func replaceStoredCodexAuthJSON(
        _ authJSON: Data,
        for profileID: UUID,
        ifSnapshotFingerprintMatches expectedFingerprint: String,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        guard var snapshot = try credentialStore.loadSnapshot(for: profileID, accessMode: accessMode),
              CredentialFingerprint.make(for: snapshot) == expectedFingerprint,
              let index = snapshot.items.firstIndex(where: Self.isCodexAuthItem) else {
            return false
        }
        snapshot.items[index].contents = authJSON
        try credentialStore.save(snapshot: snapshot, for: profileID, accessMode: accessMode)
        return true
    }

    /// Merges refreshed Codex-owned auth fields into the live auth document
    /// only while it still has the exact semantic fingerprint that was copied
    /// into an isolated app-server check. Unknown sibling fields are retained,
    /// and a concurrent CLI/account change always wins.
    @discardableResult
    public func replaceLiveCodexAuthJSON(
        _ authJSON: Data,
        ifCredentialFingerprintMatches expectedFingerprint: String
    ) throws -> Bool {
        let authURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else { return false }

        let baseline = try Data(contentsOf: authURL)
        let baselineSnapshot = try codexCredentials.snapshot(from: baseline, at: authURL)
        guard CredentialFingerprint.make(for: baselineSnapshot) == expectedFingerprint,
              let liveObject = try JSONSerialization.jsonObject(with: baseline) as? [String: Any],
              let refreshedObject = try JSONSerialization.jsonObject(with: authJSON) as? [String: Any] else {
            return false
        }

        var merged = liveObject
        for key in CodexCredentialAdapter.ownedKeys {
            merged.removeValue(forKey: key)
            if let value = refreshedObject[key] {
                merged[key] = value
            }
        }
        let updated = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])

        // Re-read at the final mutation boundary. This is the same best-effort
        // compare-and-swap used for live Claude credentials: a byte change made
        // by Codex after our baseline read is preserved instead of overwritten.
        guard try Data(contentsOf: authURL) == baseline else { return false }
        try updated.write(to: authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        return true
    }

    private static func isCodexAuthItem(_ item: CredentialSnapshotItem) -> Bool {
        (item.kind == .jsonFields || item.kind == .fullFile)
            && item.relativePath == ".codex/auth.json"
    }

    public func hasActiveProcesses(provider: Provider) -> Bool {
        CLIProcessInspector().hasActiveProcesses(provider: provider)
    }

    /// Resolves an absolute path to a CLI executable so it can be launched from
    /// a Terminal window whose PATH may not include it. The login command
    /// otherwise assumes `codex` is on Terminal's default PATH — but here codex
    /// is provided by Conductor's bundle and may not be resolvable in a plain
    /// login shell. Tries the user's login shell (`command -v`) first so we
    /// match whatever the user gets when they type the command themselves, then
    /// falls back to well-known install locations. Returns `nil` when nothing
    /// resolves, so callers can fall back to the bare command name.
    public func resolveExecutablePath(command: String) -> String? {
        CLIExecutableResolver(homeDirectory: homeDirectory, fileManager: fileManager).resolve(command: command)
    }
}
