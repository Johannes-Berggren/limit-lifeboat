import Foundation

public enum CLISwitcherError: Error, LocalizedError {
    case missingCredentials(String)
    case missingStoredSnapshot(UUID)
    case providerMismatch(expected: Provider, actual: Provider)
    case invalidJSON(String)
    case backupFailed(path: String, underlying: Error)
    case credentialConflict(String)
    case rollbackConflict(paths: [String], underlying: Error)

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
        case .rollbackConflict(let paths, let underlying):
            return "The switch failed and outside changes were preserved at \(paths.joined(separator: ", ")). \(underlying.localizedDescription)"
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

    public func captureAndStoreSnapshot(for profile: AccountProfile) throws -> CredentialSnapshot {
        let observation = try liveObservation(provider: profile.provider)
        return try storeObservation(observation, for: profile)
    }

    public func storeObservation(_ observation: LiveCredentialObservation, for profile: AccountProfile) throws -> CredentialSnapshot {
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
           let stored = try credentialStore.loadSnapshot(for: profile.id),
           let keychainItem = stored.items.first(where: { $0.kind == .keychainJSONFields }) {
            snapshot.items.append(keychainItem)
        }

        try credentialStore.save(snapshot: snapshot, for: profile.id)
        return snapshot
    }

    public func liveObservation(provider: Provider) throws -> LiveCredentialObservation {
        switch provider {
        case .codex:
            return try codexCredentials.observe()
        case .claude:
            return try claudeCredentials.observe()
        }
    }

    /// A short, synchronous stabilization gate for explicit capture/switch
    /// actions. File-driven/background paths use the async equivalent in
    /// AppState so they do not block the main actor.
    public func stableLiveObservation(provider: Provider, delay: TimeInterval = 0.25) throws -> LiveCredentialObservation {
        let first = try liveObservation(provider: provider)
        Thread.sleep(forTimeInterval: delay)
        let second = try liveObservation(provider: provider)
        guard first.stabilityKey == second.stabilityKey else {
            throw CLISwitcherError.credentialConflict("live \(provider.displayName) credentials")
        }
        return second
    }

    public func captureSnapshot(provider: Provider) throws -> CredentialSnapshot {
        switch provider {
        case .codex:
            return try codexCredentials.captureSnapshot()
        case .claude:
            return try claudeCredentials.captureSnapshot()
        }
    }

    public func restoreSnapshot(
        for profile: AccountProfile,
        expectedLiveFingerprint: String? = nil,
        enforceExpectedLiveState: Bool = false
    ) throws -> RestoreResult {
        guard let snapshot = try credentialStore.loadSnapshot(for: profile.id) else {
            throw CLISwitcherError.missingStoredSnapshot(profile.id)
        }
        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }
        let shouldEnforceLiveState = enforceExpectedLiveState || expectedLiveFingerprint != nil
        if shouldEnforceLiveState {
            let actual = try liveObservation(provider: profile.provider).credentialFingerprint
            guard actual == expectedLiveFingerprint else {
                throw CLISwitcherError.credentialConflict("live \(profile.provider.displayName) credentials")
            }
        }
        return try CredentialRestoreTransaction(
            homeDirectory: homeDirectory,
            backupDirectory: backupDirectory,
            fileManager: fileManager,
            claudeCredentialSource: claudeCLICredentialSource
        ).restore(
            snapshot,
            expectedLiveFingerprint: shouldEnforceLiveState ? .some(expectedLiveFingerprint) : nil
        )
    }

    public func deleteStoredSnapshot(for profileID: UUID) throws {
        try credentialStore.deleteSnapshot(for: profileID)
    }

    public func currentIdentity(provider: Provider) -> AccountIdentity? {
        (try? liveObservation(provider: provider))?.identity
    }

    public func hasStoredSnapshot(for profile: AccountProfile) throws -> Bool {
        try credentialStore.hasSnapshot(for: profile.id)
    }

    public func storedCredentialFingerprint(for profileID: UUID) throws -> String? {
        try credentialStore.loadSnapshot(for: profileID).map(CredentialFingerprint.make(for:))
    }

    public func validateActiveLogin(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            return codexCredentials.validateActiveLogin()
        case .claude:
            return claudeCredentials.validateActiveLogin()
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

    @discardableResult
    public func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        ifAccessTokenMatches expectedAccessToken: String
    ) throws -> Bool {
        let live = try claudeCLICredentialSource.readLiveItemJSON()
        guard live.flatMap({ ClaudeOAuthCredentials.extract(fromKeychainItemJSON: $0) })?.accessToken == expectedAccessToken else {
            return false
        }
        let merged = mergeClaudeAiOauth(credentials.rawClaudeAiOauth, intoItemJSON: live)
        // Re-read at the last mutation boundary. Keychain has no cross-process
        // compare-and-swap, but this prevents every detectable outside change.
        guard try claudeCLICredentialSource.readLiveItemJSON() == live else {
            return false
        }
        try claudeCLICredentialSource.writeLiveItemJSON(merged)
        return true
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

    @discardableResult
    public func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifAccessTokenMatches expectedAccessToken: String
    ) throws -> Bool {
        guard try storedClaudeOAuthCredentials(for: profileID)?.accessToken == expectedAccessToken else {
            return false
        }
        try updateStoredClaudeOAuthCredentials(credentials, for: profileID)
        return true
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
