import Foundation

private func accessDisposition(from error: Error) -> CredentialAccessDisposition? {
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

public enum CLISwitcherError: Error, LocalizedError {
    case missingCredentials(String)
    case missingStoredSnapshot(UUID)
    case providerMismatch(expected: Provider, actual: Provider)
    case invalidJSON(String)
    case backupFailed(path: String, underlying: Error)
    case credentialConflict(String)
    case restoreValidationFailed(
        provider: Provider,
        reason: String,
        disposition: CredentialAccessDisposition?
    )
    case rollbackConflict(
        paths: [String],
        recoveryDirectory: URL,
        underlying: Error,
        disposition: CredentialAccessDisposition?
    )

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
        case .restoreValidationFailed(let provider, let reason, _):
            return "The restored \(provider.displayName) login could not be verified, so the previous login was restored. \(reason)"
        case .rollbackConflict(let paths, let recoveryDirectory, let underlying, _):
            return "The switch failed and outside changes were preserved at \(paths.joined(separator: ", ")). Recovery files are at \(recoveryDirectory.path). \(underlying.localizedDescription)"
        }
    }

    public var credentialAccessDisposition: CredentialAccessDisposition? {
        switch self {
        case .backupFailed(_, let underlying):
            return accessDisposition(from: underlying)
        case .rollbackConflict(_, _, let underlying, let disposition):
            return disposition ?? accessDisposition(from: underlying)
        case .restoreValidationFailed(_, _, let disposition):
            return disposition
        default:
            return nil
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
    /// Production enables this so every provider-owned Claude OAuth write is
    /// impossible outside Claude Code's cross-process lease. Tests and tools
    /// that use in-memory credential sources may leave it disabled.
    private let requiresClaudeOAuthLease: Bool
    private let codexCredentials: CodexCredentialAdapter
    private let claudeCredentials: ClaudeCredentialAdapter

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL,
        credentialStore: CredentialStoreProtocol,
        fileManager: FileManager = .default,
        claudeCLICredentialSource: ClaudeCLICredentialSource = ClaudeCodeCredentialsKeychain(),
        requiresClaudeOAuthLease: Bool = false
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.credentialStore = credentialStore
        self.fileManager = fileManager
        self.claudeCLICredentialSource = claudeCLICredentialSource
        self.requiresClaudeOAuthLease = requiresClaudeOAuthLease
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
        let storedRecord = try storedCredentialRecord(for: profile, accessMode: accessMode)
        return try storeObservation(
            observation,
            for: profile,
            storedRecord: storedRecord,
            accessMode: accessMode
        )
    }

    /// Stores an observation using the snapshot record already decoded by the
    /// surrounding workflow. Supplying `nil` means that workflow confirmed no
    /// item exists; it does not trigger another Keychain read.
    public func storeObservation(
        _ observation: LiveCredentialObservation,
        for profile: AccountProfile,
        storedRecord: StoredCredentialRecord?,
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

        let stored = storedRecord?.snapshot
        if profile.provider == .claude,
           let stored,
           let storedItem = stored.items.first(where: { $0.kind == .keychainJSONFields }) {
            if let liveIndex = snapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields }) {
                // Background usage can leave a rotated token in the private
                // snapshot while the provider-owned live Keychain item still
                // carries the previous generation. Never let polling copy the
                // older generation back over the recoverable one.
                if let storedCredentials = ClaudeOAuthCredentials(
                    claudeAiOauthJSON: storedItem.contents
                ),
                   let liveCredentials = ClaudeOAuthCredentials(
                    claudeAiOauthJSON: snapshot.items[liveIndex].contents
                   ),
                   storedCredentials.isFresher(than: liveCredentials, asOf: Date()) {
                    snapshot.items[liveIndex] = storedItem
                }
            } else {
                // A logged-out terminal must not erase the profile's captured
                // OAuth token. The stored item belonged to this same profile.
                snapshot.items.append(storedItem)
            }
        }

        if let stored,
           stored.provider == snapshot.provider,
           CredentialFingerprint.make(for: stored) == CredentialFingerprint.make(for: snapshot) {
            return snapshot
        }
        if let revision = storedRecord?.storeRevision {
            // Observation planning already read this exact encrypted owner.
            // Preserve a concurrent newer generation instead of turning the
            // capture into an unconditional last-writer-wins overwrite.
            guard try credentialStore.replaceSnapshot(
                snapshot,
                for: profile.id,
                ifRevisionMatches: revision,
                accessMode: accessMode
            ) != nil else {
                throw CLISwitcherError.credentialConflict(
                    "saved \(profile.provider.displayName) credentials"
                )
            }
        } else if let storedRecord {
            // Compatibility for snapshots created before opaque revisions:
            // compare the semantic generation again at the write boundary.
            guard let current = try credentialStore.loadSnapshot(
                for: profile.id,
                accessMode: accessMode
            ),
            CredentialFingerprint.make(for: current) == storedRecord.summary.fingerprint else {
                throw CLISwitcherError.credentialConflict(
                    "saved \(profile.provider.displayName) credentials"
                )
            }
            try credentialStore.save(snapshot: snapshot, for: profile.id, accessMode: accessMode)
        } else {
            // A first capture has no generation to replace. The store's atomic
            // insert makes an item appearing concurrently win without exposing
            // or overwriting its credential bytes.
            guard try credentialStore.insertSnapshotIfAbsent(
                snapshot,
                for: profile.id,
                accessMode: accessMode
            ) else {
                throw CLISwitcherError.credentialConflict(
                    "saved \(profile.provider.displayName) credentials"
                )
            }
        }
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

    /// Metadata-only discovery of the exact provider-owned Claude item. This
    /// does not request secret data and is safe for login-completion polling.
    public func locateClaudeKeychainItem(
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> ClaudeKeychainItemLocation? {
        try claudeCLICredentialSource.locateLiveItem(accessMode: accessMode)
    }

    /// Reads only the previously resolved Claude item, preventing a duplicate
    /// service/account entry or search-list change from redirecting an
    /// authorization workflow midway through the operation.
    public func readClaudeKeychainItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Data? {
        try claudeCLICredentialSource.readLiveItemJSON(at: location, accessMode: accessMode)
    }

    /// Reads and observes only the item generation selected by a preceding
    /// metadata sample. Login watchers must not rediscover by service/account
    /// here: the search list can change between the settle decision and the
    /// data read, which would otherwise let an un-settled replacement through.
    public func liveClaudeObservation(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> LiveCredentialObservation {
        guard let item = try claudeCLICredentialSource.readLiveItemJSON(
            at: location,
            accessMode: accessMode
        ) else {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
        return try claudeCredentials.observe(liveItem: item, location: location)
    }

    /// Resolves OAuth fields from one already-selected item generation. This
    /// is the usage-workflow counterpart to `liveClaudeObservation(at:)`: it
    /// never broadens to another service/account match after metadata was
    /// sampled.
    public func liveClaudeOAuthCredentialRecord(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> LiveClaudeOAuthCredentialRecord? {
        guard let item = try claudeCLICredentialSource.readLiveItemJSON(
            at: location,
            accessMode: accessMode
        ) else {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
        return try ClaudeOAuthCredentials.validatedExtract(
            fromKeychainItemJSON: item
        ).map {
            LiveClaudeOAuthCredentialRecord(
                credentials: $0,
                itemLocation: location
            )
        }
    }

    /// Reuses OAuth fields already validated as part of a live observation.
    /// Explicit retry workflows can therefore pass the same pinned generation
    /// to usage and persistence code without another shared-Keychain read.
    public func claudeOAuthCredentialRecord(
        from observation: LiveCredentialObservation
    ) throws -> LiveClaudeOAuthCredentialRecord? {
        guard observation.provider == .claude else {
            throw CLISwitcherError.providerMismatch(
                expected: .claude,
                actual: observation.provider
            )
        }
        guard let item = observation.snapshot?.items.first(where: {
            $0.kind == .keychainJSONFields
        }), let credentials = ClaudeOAuthCredentials(
            claudeAiOauthJSON: item.contents
        ) else {
            return nil
        }
        return LiveClaudeOAuthCredentialRecord(
            credentials: credentials,
            itemLocation: observation.claudeKeychainItemLocation
        )
    }

    /// Re-reads only Claude's nonsecret filesystem metadata around a cached
    /// observation. This method never calls the shared Keychain source.
    public func refreshClaudeFilesystemMetadata(
        in observation: LiveCredentialObservation
    ) throws -> LiveCredentialObservation {
        try claudeCredentials.refreshFilesystemMetadata(in: observation)
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
        guard let storedRecord = try storedCredentialRecord(
            for: profile,
            accessMode: accessMode
        ) else {
            throw CLISwitcherError.missingStoredSnapshot(profile.id)
        }
        return try restoreSnapshot(
            for: profile,
            storedRecord: storedRecord,
            expectedLiveFingerprint: expectedLiveFingerprint,
            enforceExpectedLiveState: enforceExpectedLiveState,
            accessMode: accessMode
        )
    }

    /// Restores the workflow-scoped record that was already decoded during
    /// preflight. Mutation-boundary live reads remain, but the private app
    /// snapshot is not loaded a second time.
    public func restoreSnapshot(
        for profile: AccountProfile,
        storedRecord: StoredCredentialRecord,
        expectedLiveFingerprint: String? = nil,
        enforceExpectedLiveState: Bool = false,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> RestoreResult {
        if profile.provider == .claude {
            try validateClaudeOAuthMutationLease()
        }
        let snapshot = storedRecord.snapshot
        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }
        guard isRestorable(snapshot, for: profile.provider) else {
            throw CLISwitcherError.missingCredentials(
                "saved \(profile.provider.displayName) account snapshot"
            )
        }
        // The live-fingerprint compare-and-swap that used to run here was a
        // duplicate of the identical validateExpectedLiveFingerprint check
        // CredentialRestoreTransaction.restore performs as its first step (via
        // the expectedLiveFingerprint forwarded below). Reading the shared
        // "Claude Code-credentials" item twice back-to-back only multiplied the
        // OS password prompts, so the read now happens once, inside the
        // transaction.
        let shouldEnforceLiveState = enforceExpectedLiveState || expectedLiveFingerprint != nil
        let targetFingerprint = CredentialFingerprint.make(for: snapshot)
        let claudeItemLocation: ClaudeKeychainItemLocation?
        if profile.provider == .claude {
            claudeItemLocation = try claudeCLICredentialSource.locateLiveItem(accessMode: accessMode)
            if claudeCLICredentialSource.supportsExactItemLocations,
               claudeItemLocation == nil {
                throw ClaudeCodeCredentialsKeychainError.missingLiveItem
            }
        } else {
            claudeItemLocation = nil
        }
        var verifiedObservation: LiveCredentialObservation?
        let touchedPaths = try CredentialRestoreTransaction(
            homeDirectory: homeDirectory,
            backupDirectory: backupDirectory,
            fileManager: fileManager,
            claudeCredentialSource: claudeCLICredentialSource,
            validateMutationLease: profile.provider == .claude
                ? { [self] in try validateClaudeOAuthMutationLease() }
                : nil
        ).restore(
            snapshot,
            expectedLiveFingerprint: shouldEnforceLiveState ? .some(expectedLiveFingerprint) : nil,
            accessMode: accessMode,
            claudeKeychainItemLocation: claudeItemLocation,
            validateRestoredCredentials: { [self] in
                let observation: LiveCredentialObservation
                do {
                    if let claudeItemLocation {
                        let item = try claudeCLICredentialSource.readLiveItemJSON(
                            at: claudeItemLocation,
                            accessMode: accessMode
                        )
                        observation = try claudeCredentials.observe(
                            liveItem: item,
                            location: claudeItemLocation
                        )
                    } else {
                        observation = try liveObservation(provider: profile.provider, accessMode: accessMode)
                    }
                } catch {
                    throw CLISwitcherError.restoreValidationFailed(
                        provider: profile.provider,
                        reason: error.localizedDescription,
                        disposition: accessDisposition(from: error)
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
                        reason: "The live credentials did not identify \(profile.label).",
                        disposition: nil
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
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        if profile.provider == .claude {
            // Profile removal participates in the same provider-wide
            // transaction as journal reconciliation. Check at the actual
            // Keychain mutation boundary, not only when that workflow starts.
            try validateClaudeOAuthMutationLease()
        }
        try credentialStore.deleteSnapshot(for: profile.id, accessMode: accessMode)
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

    /// Loads and decodes an app-owned snapshot once for a complete workflow.
    /// This replaces call sequences that separately queried its fingerprint,
    /// restorability, provider payload, and Claude expiry.
    public func storedCredentialRecord(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> StoredCredentialRecord? {
        guard let stored = try credentialStore.loadVersionedSnapshot(
            for: profile.id,
            accessMode: accessMode
        ) else {
            return nil
        }
        let snapshot = stored.snapshot
        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }
        return makeStoredCredentialRecord(
            from: snapshot,
            storeRevision: stored.revision
        )
    }

    public func makeStoredCredentialRecord(
        from snapshot: CredentialSnapshot,
        storeRevision: CredentialStoreRevision? = nil
    ) -> StoredCredentialRecord {
        let expiresAt: Date?
        let refreshChainFingerprint: String?
        if snapshot.provider == .claude,
           let item = snapshot.items.first(where: { $0.kind == .keychainJSONFields }) {
            let credentials = ClaudeOAuthCredentials(claudeAiOauthJSON: item.contents)
            expiresAt = credentials?.refreshTokenExpiresAt
            refreshChainFingerprint = ClaudeRefreshChainFingerprint.make(
                credentials: credentials
            )
        } else {
            expiresAt = nil
            refreshChainFingerprint = nil
        }
        return StoredCredentialRecord(
            snapshot: snapshot,
            summary: StoredCredentialSummary(
                provider: snapshot.provider,
                fingerprint: CredentialFingerprint.make(for: snapshot),
                isRestorable: isRestorable(snapshot, for: snapshot.provider),
                claudeRefreshTokenExpiresAt: expiresAt,
                claudeRefreshChainFingerprint: refreshChainFingerprint
            ),
            storeRevision: storeRevision
        )
    }

    /// A stored item can contain only non-login metadata (legacy Claude
    /// config fields). Such an item is useful for identity reconciliation but
    /// must never be offered as a switch target: restoring it used to strip
    /// the current live OAuth login.
    public func hasRestorableSnapshot(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        guard let stored = try credentialStore.loadVersionedSnapshot(
            for: profile.id,
            accessMode: accessMode
        ), stored.snapshot.provider == profile.provider else {
            return false
        }
        return isRestorable(stored.snapshot, for: profile.provider)
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
        try liveClaudeOAuthCredentialRecord(accessMode: accessMode)?.credentials
    }

    public func liveClaudeOAuthCredentialRecord(
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> LiveClaudeOAuthCredentialRecord? {
        if claudeCLICredentialSource.supportsExactItemLocations {
            guard let location = try claudeCLICredentialSource.locateLiveItem(
                accessMode: accessMode
            ),
            let item = try claudeCLICredentialSource.readLiveItemJSON(
                at: location,
                accessMode: accessMode
            ),
            let credentials = try ClaudeOAuthCredentials.validatedExtract(
                fromKeychainItemJSON: item
            ) else {
                return nil
            }
            return LiveClaudeOAuthCredentialRecord(
                credentials: credentials,
                itemLocation: location
            )
        }
        guard let item = try claudeCLICredentialSource.readLiveItemJSON(
            accessMode: accessMode
        ),
        let credentials = try ClaudeOAuthCredentials.validatedExtract(
            fromKeychainItemJSON: item
        ) else {
            return nil
        }
        return LiveClaudeOAuthCredentialRecord(
            credentials: credentials,
            itemLocation: nil
        )
    }

    /// Merge-writes refreshed tokens into the live keychain item so the CLI
    /// keeps working after the app refreshes an access token (`mcpOAuth` and
    /// unknown siblings are preserved).
    public func writeLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        try validateClaudeOAuthMutationLease()
        // A thrown read must abort the write: collapsing it into nil would
        // merge into {} and drop the item's siblings (mcpOAuth). Only a
        // genuine nil (item absent) starts a fresh item.
        let location = try resolveClaudeKeychainItemForMutation(accessMode: accessMode)
        let live = try readClaudeKeychainItem(at: location, accessMode: accessMode)
        let merged = try mergeClaudeAiOauth(credentials.rawClaudeAiOauth, intoItemJSON: live)
        try writeClaudeKeychainItem(merged, at: location, accessMode: accessMode)
    }

    @discardableResult
    public func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        at expectedItemLocation: ClaudeKeychainItemLocation? = nil,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        try validateClaudeOAuthMutationLease()
        let location = try expectedItemLocation
            ?? resolveClaudeKeychainItemForMutation(accessMode: accessMode)
        let live = try readClaudeKeychainItem(at: location, accessMode: accessMode)
        guard live.flatMap({
            ClaudeOAuthCredentials.extract(fromKeychainItemJSON: $0)
        })?.rawClaudeAiOauth == expectedCredentials.rawClaudeAiOauth else {
            return false
        }
        // Re-read at the last mutation boundary. An unrelated MCP sibling may
        // legitimately rotate while the OAuth request is in flight; preserve
        // that latest sibling state and conflict only when `claudeAiOauth`
        // itself changed (or the pinned item vanished/replaced).
        guard let latest = try readClaudeKeychainItem(
            at: location,
            accessMode: accessMode
        ),
        ClaudeOAuthCredentials.extract(fromKeychainItemJSON: latest)?
            .rawClaudeAiOauth == expectedCredentials.rawClaudeAiOauth else {
            return false
        }
        let merged = try mergeClaudeAiOauth(
            credentials.rawClaudeAiOauth,
            intoItemJSON: latest
        )
        try writeClaudeKeychainItem(merged, at: location, accessMode: accessMode)
        return true
    }

    private func validateClaudeOAuthMutationLease() throws {
        guard requiresClaudeOAuthLease else { return }
        try ClaudeOAuthMutationLeaseContext.requireCurrent().validate()
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
        guard let versioned = try credentialStore.loadVersionedSnapshot(
            for: profileID,
            accessMode: accessMode
        ) else {
            throw CLISwitcherError.missingStoredSnapshot(profileID)
        }
        let baselineFingerprint = CredentialFingerprint.make(
            for: versioned.snapshot
        )
        var snapshot = versioned.snapshot
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
        if let revision = versioned.revision {
            try validateClaudeOAuthMutationLease()
            guard try credentialStore.replaceSnapshot(
                snapshot,
                for: profileID,
                ifRevisionMatches: revision,
                accessMode: accessMode
            ) != nil else {
                throw CLISwitcherError.credentialConflict(
                    "saved Claude credentials"
                )
            }
            return
        }

        // Legacy snapshots have no opaque revision. Re-read and compare their
        // complete semantic generation immediately before the one-time save;
        // the save stamps a revision for all later rotations.
        guard let current = try credentialStore.loadSnapshot(
            for: profileID,
            accessMode: accessMode
        ),
        CredentialFingerprint.make(for: current) == baselineFingerprint else {
            throw CLISwitcherError.credentialConflict(
                "saved Claude credentials"
            )
        }
        try validateClaudeOAuthMutationLease()
        try credentialStore.save(
            snapshot: snapshot,
            for: profileID,
            accessMode: accessMode
        )
    }

    @discardableResult
    public func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> Bool {
        guard let stored = try credentialStore.loadVersionedSnapshot(
            for: profileID,
            accessMode: accessMode
        ) else {
            return false
        }
        return try replaceStoredClaudeOAuthCredentials(
            credentials,
            for: profileID,
            using: makeStoredCredentialRecord(
                from: stored.snapshot,
                storeRevision: stored.revision
            ),
            ifCurrentCredentialsMatch: expectedCredentials,
            accessMode: accessMode
        ) != nil
    }

    /// Persists a rotated Claude credential using the snapshot generation
    /// already decoded by the surrounding switch workflow. The credential
    /// store performs an atomic revision CAS, so no second private-store
    /// data read is needed and a concurrent capture still wins.
    @discardableResult
    public func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> StoredCredentialRecord? {
        guard storedRecord.snapshot.provider == .claude else {
            throw CLISwitcherError.providerMismatch(
                expected: .claude,
                actual: storedRecord.snapshot.provider
            )
        }
        let expectedFingerprint = storedRecord.summary.fingerprint
        guard CredentialFingerprint.make(for: storedRecord.snapshot) == expectedFingerprint else {
            return nil
        }
        var snapshot = storedRecord.snapshot
        guard let index = snapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields }),
              ClaudeOAuthCredentials(
                  claudeAiOauthJSON: snapshot.items[index].contents
              )?.rawClaudeAiOauth == expectedCredentials.rawClaudeAiOauth else {
            return nil
        }
        snapshot.items[index].contents = credentials.rawClaudeAiOauth
        if CredentialFingerprint.make(for: snapshot) == expectedFingerprint {
            return storedRecord
        }
        if let expectedRevision = storedRecord.storeRevision {
            try validateClaudeOAuthMutationLease()
            guard let newRevision = try credentialStore.replaceSnapshot(
                snapshot,
                for: profileID,
                ifRevisionMatches: expectedRevision,
                accessMode: accessMode
            ) else {
                return nil
            }
            return makeStoredCredentialRecord(
                from: snapshot,
                storeRevision: newRevision
            )
        }

        // One-time compatibility for app-owned items saved before opaque
        // revisions existed. Re-read immediately before the write, preserving
        // the legacy conflict check; save stamps a revision for future flows.
        guard let current = try credentialStore.loadSnapshot(
            for: profileID,
            accessMode: accessMode
        ),
        current.provider == .claude,
        CredentialFingerprint.make(for: current) == expectedFingerprint else {
            return nil
        }
        try validateClaudeOAuthMutationLease()
        try credentialStore.save(snapshot: snapshot, for: profileID, accessMode: accessMode)
        return makeStoredCredentialRecord(from: snapshot)
    }

    /// Resolve once, then keep every read/write in the mutation on the same
    /// persistent item. Production fails closed when no exact location exists;
    /// lightweight sources retain their compatibility behavior.
    private func resolveClaudeKeychainItemForMutation(
        accessMode: CredentialAccessMode
    ) throws -> ClaudeKeychainItemLocation? {
        let location = try claudeCLICredentialSource.locateLiveItem(accessMode: accessMode)
        if claudeCLICredentialSource.supportsExactItemLocations, location == nil {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
        return location
    }

    private func readClaudeKeychainItem(
        at location: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        if let location {
            return try claudeCLICredentialSource.readLiveItemJSON(
                at: location,
                accessMode: accessMode
            )
        }
        return try claudeCLICredentialSource.readLiveItemJSON(accessMode: accessMode)
    }

    private func writeClaudeKeychainItem(
        _ data: Data,
        at location: ClaudeKeychainItemLocation?,
        accessMode: CredentialAccessMode
    ) throws {
        // The reads and JSON merge preceding this helper can outlive a lock
        // replacement. Validate at the actual mutation boundary as well as at
        // the workflow entry so a stale lease can never write the live item.
        try validateClaudeOAuthMutationLease()
        if let location {
            try claudeCLICredentialSource.writeLiveItemJSON(
                data,
                at: location,
                accessMode: accessMode
            )
        } else {
            try claudeCLICredentialSource.writeLiveItemJSON(data, accessMode: accessMode)
        }
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
        guard let stored = try credentialStore.loadVersionedSnapshot(
            for: profileID,
            accessMode: accessMode
        ) else {
            return false
        }
        return try replaceStoredCodexAuthJSON(
            authJSON,
            for: profileID,
            using: makeStoredCredentialRecord(
                from: stored.snapshot,
                storeRevision: stored.revision
            ),
            ifSnapshotFingerprintMatches: expectedFingerprint,
            accessMode: accessMode
        ) != nil
    }

    /// Codex counterpart to the preloaded Claude mutation. App-server
    /// preflight can merge its refreshed auth document into the record it was
    /// given, then commit that generation with one read-free store CAS.
    @discardableResult
    public func replaceStoredCodexAuthJSON(
        _ authJSON: Data,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifSnapshotFingerprintMatches expectedFingerprint: String,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws -> StoredCredentialRecord? {
        guard storedRecord.snapshot.provider == .codex else {
            throw CLISwitcherError.providerMismatch(
                expected: .codex,
                actual: storedRecord.snapshot.provider
            )
        }
        guard storedRecord.summary.fingerprint == expectedFingerprint,
              CredentialFingerprint.make(for: storedRecord.snapshot) == expectedFingerprint else {
            return nil
        }
        var snapshot = storedRecord.snapshot
        guard let index = snapshot.items.firstIndex(where: Self.isCodexAuthItem) else {
            return nil
        }
        snapshot.items[index].contents = authJSON
        // App-server preflight often returns the same auth document with only
        // formatting differences. The semantic fingerprint deliberately
        // canonicalizes provider-owned JSON, so avoid a needless Keychain
        // update when no credential field changed.
        if CredentialFingerprint.make(for: snapshot) == expectedFingerprint {
            return storedRecord
        }
        if let expectedRevision = storedRecord.storeRevision {
            guard let newRevision = try credentialStore.replaceSnapshot(
                snapshot,
                for: profileID,
                ifRevisionMatches: expectedRevision,
                accessMode: accessMode
            ) else {
                return nil
            }
            return makeStoredCredentialRecord(
                from: snapshot,
                storeRevision: newRevision
            )
        }

        guard let current = try credentialStore.loadSnapshot(
            for: profileID,
            accessMode: accessMode
        ),
        current.provider == .codex,
        CredentialFingerprint.make(for: current) == expectedFingerprint else {
            return nil
        }
        try credentialStore.save(snapshot: snapshot, for: profileID, accessMode: accessMode)
        return makeStoredCredentialRecord(from: snapshot)
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
