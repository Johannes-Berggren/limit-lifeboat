import CryptoKit
import Foundation
import os

/// The credential surface `ClaudeAccountUsageService` needs; `CLISwitcher`
/// is the production implementation, tests use an in-memory fake.
public protocol ClaudeOAuthCredentialProviding: AnyObject {
    func liveClaudeOAuthCredentialRecord(
        accessMode: CredentialAccessMode
    ) throws -> LiveClaudeOAuthCredentialRecord?
    func writeLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws
    @discardableResult
    func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        at expectedItemLocation: ClaudeKeychainItemLocation?,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> Bool
    func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeOAuthCredentials?
    func storedClaudeOAuthCredentialRecord(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord?
    func updateStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws
    @discardableResult
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> Bool
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord?
}

public extension ClaudeOAuthCredentialProviding {
    func storedClaudeOAuthCredentialRecord(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        guard let credentials = try storedClaudeOAuthCredentials(
            for: profile.id,
            accessMode: accessMode
        ) else {
            return nil
        }
        let snapshot = CredentialSnapshot(
            provider: .claude,
            capturedAt: Date(),
            items: [
                CredentialSnapshotItem(
                    relativePath: "keychain/Claude Code-credentials",
                    kind: .keychainJSONFields,
                    contents: credentials.rawClaudeAiOauth,
                    posixPermissions: nil
                )
            ]
        )
        return StoredCredentialRecord(
            snapshot: snapshot,
            summary: StoredCredentialSummary(
                provider: .claude,
                fingerprint: CredentialFingerprint.make(for: snapshot),
                isRestorable: true,
                claudeRefreshTokenExpiresAt: credentials.refreshTokenExpiresAt,
                claudeRefreshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: credentials
                )
            )
        )
    }

    /// Compatibility path for lightweight providers. CLISwitcher overrides
    /// this requirement with its revisioned, read-free credential-store CAS.
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        guard try replaceStoredClaudeOAuthCredentials(
            credentials,
            for: profileID,
            ifCurrentCredentialsMatch: expectedCredentials,
            accessMode: accessMode
        ) else {
            return nil
        }
        var snapshot = storedRecord.snapshot
        guard let index = snapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields }) else {
            return nil
        }
        snapshot.items[index].contents = credentials.rawClaudeAiOauth
        return StoredCredentialRecord(
            snapshot: snapshot,
            summary: StoredCredentialSummary(
                provider: .claude,
                fingerprint: CredentialFingerprint.make(for: snapshot),
                isRestorable: true,
                claudeRefreshTokenExpiresAt: credentials.refreshTokenExpiresAt,
                claudeRefreshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: credentials
                )
            ),
            storeRevision: storedRecord.storeRevision
        )
    }
}

extension CLISwitcher: ClaudeOAuthCredentialProviding {
    public func storedClaudeOAuthCredentialRecord(
        for profile: AccountProfile,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        try storedCredentialRecord(for: profile, accessMode: accessMode)
    }
}

public enum ClaudeAccountUsageFetchError: Error, LocalizedError {
    /// The profile has no captured OAuth token yet (it becomes pollable
    /// after being the active CLI login once).
    case noCredentials
    /// The Keychain is locked or read access was denied — distinct from
    /// `noCredentials` so the UI can prompt to grant access instead of
    /// treating the account as unlinked.
    case keychainLocked
    /// A read already pinned the provider-owned item, but a later live-item
    /// write was denied. Preserve both the typed disposition and exact item so
    /// AppState can invalidate that authorization context instead of leaving
    /// it incorrectly marked ready.
    case liveCredentialAccessDenied(
        error: ClaudeCodeCredentialsKeychainError,
        item: ClaudeKeychainItemLocation?
    )
    /// The active CLI credential needs rotation, but a background task must
    /// not consume its refresh token out from under Claude Code.
    case interactiveRefreshRequired
    /// A different profile owns the live CLI login for this same Claude account
    /// (e.g. the same account under another organization). Rotating this copy's
    /// refresh token would invalidate the active login's single-use chain, so
    /// it is never rotated — the account must be switched to instead.
    case accountActiveElsewhere
    /// Cross-process locking or reconciliation deferred an otherwise allowed
    /// rotation. This is recoverable and never proves that login expired.
    case rotationDeferred(Error)
    /// Claude issued a fresh OAuth generation, but one of the intended local
    /// owners could not be updated. The service retained enough workflow-local
    /// state to repair the split on the next explicit Retry or user switch
    /// without consuming the refresh chain a second time.
    case credentialRepairRequired(Error)
    /// The token endpoint advanced the refresh chain, but neither the
    /// encrypted journal nor any intended owner retained the fresh
    /// generation. This is terminal because the stale chain may be consumed.
    case credentialRecoveryFailed(Error)
    /// Duplicate, malformed, ambiguous, or otherwise unsafe provider-owned
    /// credential state. This is deliberately not an authorization failure and
    /// must never trigger a CLI fallback.
    case credentialUnavailable(Error)
    case refreshFailed(Error)
    case unauthorized
    case forbidden
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No captured OAuth token for this account yet."
        case .keychainLocked:
            return "The macOS Keychain denied access to this account's saved credentials."
        case .liveCredentialAccessDenied(let error, _):
            return error.localizedDescription
        case .interactiveRefreshRequired:
            return "The active Claude login needs an explicit Retry before its access token can be refreshed."
        case .accountActiveElsewhere:
            return "This account shares its Claude login with the active CLI account; switch to it to refresh."
        case .rotationDeferred(let underlying):
            return underlying.localizedDescription
        case .credentialRepairRequired(let underlying):
            return underlying.localizedDescription
        case .credentialRecoveryFailed(let underlying):
            return underlying.localizedDescription
        case .credentialUnavailable(let underlying):
            return "The shared Claude credential could not be used safely (\(underlying.localizedDescription))."
        case .refreshFailed(let underlying):
            return "Could not refresh the access token (\(underlying.localizedDescription))."
        case .unauthorized:
            return "The Anthropic usage API rejected the account's tokens."
        case .forbidden:
            return "The Anthropic usage API denied this login access to usage data. Renew the login or ask an organization administrator for access."
        case .transport(let underlying):
            return underlying.localizedDescription
        }
    }
}

/// Describes why a Claude usage workflow is running. Credential access mode
/// controls whether macOS may prompt for Keychain access; it deliberately does
/// not grant permission to rotate a single-use OAuth refresh chain.
public enum ClaudeRotationIntent: Sendable, Equatable {
    case scheduledReadOnly
    case userRetry
    case userInitiatedSwitch
    case automaticSwitch

    public var allowsCredentialRotation: Bool {
        switch self {
        case .userRetry, .userInitiatedSwitch:
            return true
        case .scheduledReadOnly, .automaticSwitch:
            return false
        }
    }
}

public struct ClaudeCredentialRepairRequiredError: Error, LocalizedError, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

/// A refresh-token exchange completed, but neither the encrypted recovery
/// journal nor any intended credential owner retained the fresh generation.
/// The stale refresh token may already have been consumed, so this is the one
/// persistence failure that genuinely requires a new login.
public struct ClaudeCredentialPersistenceFailedError: Error, LocalizedError, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public struct ClaudeRotationDeferredError: Error, LocalizedError, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

/// A switch preflight needs the credential generation that produced its
/// usage response so a workflow-local stored record can follow a successful
/// token rotation without decoding the private snapshot again.
public struct ClaudeAccountUsageFetchResult: Sendable {
    public var snapshot: UsageSnapshot
    public var credentials: ClaudeOAuthCredentials

    public init(snapshot: UsageSnapshot, credentials: ClaudeOAuthCredentials) {
        self.snapshot = snapshot
        self.credentials = credentials
    }
}

/// Controls whether an active-account usage workflow may touch Claude's
/// provider-owned Keychain item. AppState selects `knownDenied` only after a
/// metadata-only check proves that the item generation which previously
/// denied access is unchanged. Stored credentials may still serve usage, but
/// the service preserves active-account rotation rules and never mutates the
/// unavailable live item.
public enum ClaudeLiveCredentialReadPolicy: Sendable {
    case read
    case knownDenied
    /// The caller already performed the workflow's one exact live-item read.
    /// Reusing that record prevents account-info and fallback work from
    /// decrypting the shared item again.
    case preloaded(LiveClaudeOAuthCredentialRecord?)
}

/// A switch preflight can safely persist a rotated credential before the
/// following usage request fails. Preserve that committed generation in the
/// error so a workflow-local snapshot cache never restores the spent token.
public struct ClaudeAccountUsagePreflightError: Error, LocalizedError {
    public var underlying: ClaudeAccountUsageFetchError
    public var latestPersistedCredentials: ClaudeOAuthCredentials?

    public init(
        underlying: ClaudeAccountUsageFetchError,
        latestPersistedCredentials: ClaudeOAuthCredentials?
    ) {
        self.underlying = underlying
        self.latestPersistedCredentials = latestPersistedCredentials
    }

    public var errorDescription: String? {
        underlying.localizedDescription
    }
}

/// Fetches an exact, account-wide usage snapshot for one Claude profile via
/// the OAuth usage API — active or inactive, no CLI launch. Callers should
/// process profiles sequentially so concurrent token refreshes cannot race.
public struct ClaudeAccountUsageService {
    private let apiClient: ClaudeUsageAPIClient
    private let refresher: ClaudeOAuthTokenRefresher
    private let credentials: ClaudeOAuthCredentialProviding
    private let refreshCoordinator: ClaudeOAuthRefreshCoordinator
    private let recoveryStore: (any ClaudeRotationRecoveryStoring)?
    private let liveRepairs: ClaudeLiveRepairRegistry
    private let storedRepairs: ClaudeStoredRepairRegistry

    public init(
        apiClient: ClaudeUsageAPIClient = ClaudeUsageAPIClient(),
        refresher: ClaudeOAuthTokenRefresher = ClaudeOAuthTokenRefresher(),
        credentials: ClaudeOAuthCredentialProviding,
        refreshCoordinator: ClaudeOAuthRefreshCoordinator = ClaudeOAuthRefreshCoordinator(),
        recoveryStore: (any ClaudeRotationRecoveryStoring)? = nil
    ) {
        self.apiClient = apiClient
        self.refresher = refresher
        self.credentials = credentials
        self.refreshCoordinator = refreshCoordinator
        self.recoveryStore = recoveryStore
        self.liveRepairs = ClaudeLiveRepairRegistry()
        self.storedRepairs = ClaudeStoredRepairRegistry()
    }

    /// True when this process holds a fresh generation that still needs a
    /// provider-owned or app-owned repair. This complements the durable journal:
    /// repeated journal-save failure can leave the only repair marker in memory,
    /// and switch verification must not bypass that state.
    public var hasPendingCredentialRepair: Bool {
        liveRepairs.hasEntries || storedRepairs.hasEntries
    }

    /// Must run under the provider-wide mutation lease before deleting a
    /// stored Claude snapshot. A prepared transaction may have that snapshot
    /// as its only surviving fresh owner; materialize the fresh secret into
    /// the encrypted journal first while retaining the owner link. The link is
    /// removed only after the caller's snapshot deletion succeeds.
    public func prepareRecoveryForStoredProfileRemoval(
        _ profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) throws {
        guard let recoveryStore else { return }
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }

        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profileID
        )
        let records: [ClaudeRotationRecoveryRecord]
        do {
            records = try recoveryStore.loadAll(accessMode: accessMode)
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.keychainLocked
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude recovery could not inspect its encrypted journal before account removal."
                )
            )
        }

        for original in records
            where original.pendingDestinations.contains(destination) {
            guard let record = try materializePreparedRecoveryRecord(
                original,
                accessMode: accessMode
            ) else { continue }
            if record != original {
                try persistRecoveryRecord(record, accessMode: accessMode)
            }
        }
    }

    /// Executes the snapshot deletion between the recovery prepare/finalize
    /// phases. If deletion throws, every journal destination remains linked to
    /// the still-present profile. If finalization throws after deletion, the
    /// conservative link also remains so an explicit repair can recreate the
    /// app-owned copy before removal is retried.
    public func performStoredProfileRemoval(
        _ profileID: UUID,
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        deleteSnapshot: () throws -> Void
    ) throws {
        try prepareRecoveryForStoredProfileRemoval(
            profileID,
            accessMode: accessMode
        )
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }
        try deleteSnapshot()
        try completeRecoveryForStoredProfileRemoval(
            profileID,
            accessMode: accessMode
        )
    }

    private func completeRecoveryForStoredProfileRemoval(
        _ profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws {
        guard let recoveryStore else { return }
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }
        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profileID
        )
        let records: [ClaudeRotationRecoveryRecord]
        do {
            records = try recoveryStore.loadAll(accessMode: accessMode)
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.keychainLocked
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude recovery could not finalize its encrypted journal after account removal."
                )
            )
        }
        for original in records
            where original.pendingDestinations.contains(destination) {
            var record = original
            guard !record.isPrepared else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude recovery remained prepared after snapshot deletion; its owner link was retained for repair."
                    )
                )
            }
            record.pendingDestinations.remove(destination)
            try persistRecoveryRecord(record, accessMode: accessMode)
        }
    }

    public func fetchSnapshot(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool = false,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        rotationIntent: ClaudeRotationIntent = .scheduledReadOnly,
        additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination> = [],
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy = .read,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)? = nil,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)? = nil
    ) async throws -> UsageSnapshot {
        try await fetchSnapshotResult(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            now: now,
            accessMode: accessMode,
            rotationIntent: rotationIntent,
            additionalRecoveryDestinations: additionalRecoveryDestinations,
            liveCredentialReadPolicy: liveCredentialReadPolicy,
            liveCredentialAccessDenied: liveCredentialAccessDenied,
            storedCredentialSource: .provider,
            credentialDidPersist: nil,
            credentialDidResolve: credentialDidResolve
        ).snapshot
    }

    /// Switch-only overload that consumes the record already decoded at the
    /// start of the workflow. It never asks the credential provider to load
    /// that private snapshot again.
    public func fetchSnapshot(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        storedRecord: StoredCredentialRecord,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        rotationIntent: ClaudeRotationIntent = .scheduledReadOnly,
        additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination> = [],
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy = .read,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)? = nil,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)? = nil
    ) async throws -> ClaudeAccountUsageFetchResult {
        guard storedRecord.summary.provider == .claude else {
            throw ClaudeAccountUsageFetchError.credentialUnavailable(
                CLISwitcherError.providerMismatch(
                    expected: .claude,
                    actual: storedRecord.summary.provider
                )
            )
        }
        var latestPersistedCredentials: ClaudeOAuthCredentials?
        do {
            return try await fetchSnapshotResult(
                for: profile,
                isActiveCLI: isActiveCLI,
                // A switch is activating this target, so its own chain is the one
                // being made live — never treat it as a shared-account sibling.
                accountIsLiveElsewhere: false,
                now: now,
                accessMode: accessMode,
                rotationIntent: rotationIntent,
                additionalRecoveryDestinations: additionalRecoveryDestinations,
                liveCredentialReadPolicy: liveCredentialReadPolicy,
                liveCredentialAccessDenied: liveCredentialAccessDenied,
                storedCredentialSource: .preloaded(storedRecord),
                credentialDidPersist: { latestPersistedCredentials = $0 },
                credentialDidResolve: credentialDidResolve
            )
        } catch let error as ClaudeAccountUsageFetchError {
            throw ClaudeAccountUsagePreflightError(
                underlying: error,
                latestPersistedCredentials: latestPersistedCredentials
            )
        }
    }

    private func fetchSnapshotResult(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        now: Date,
        accessMode: CredentialAccessMode,
        rotationIntent: ClaudeRotationIntent,
        additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination>,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?,
        storedCredentialSource: StoredCredentialSource,
        credentialDidPersist: ((ClaudeOAuthCredentials) -> Void)?,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)?
    ) async throws -> ClaudeAccountUsageFetchResult {
        do {
            try refreshCoordinator.validateSupportedConfiguration()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }
        if rotationIntent.allowsCredentialRotation,
           ClaudeOAuthMutationLeaseContext.current == nil {
            do {
                return try await refreshCoordinator.withLease { _ in
                    try await performFetchSnapshotResult(
                        for: profile,
                        isActiveCLI: isActiveCLI,
                        accountIsLiveElsewhere: accountIsLiveElsewhere,
                        now: now,
                        accessMode: accessMode,
                        rotationIntent: rotationIntent,
                        additionalRecoveryDestinations: additionalRecoveryDestinations,
                        liveCredentialReadPolicy: liveCredentialReadPolicy,
                        liveCredentialAccessDenied: liveCredentialAccessDenied,
                        storedCredentialSource: storedCredentialSource,
                        credentialDidPersist: credentialDidPersist,
                        credentialDidResolve: credentialDidResolve
                    )
                }
            } catch let error as ClaudeAccountUsageFetchError {
                throw error
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                throw ClaudeAccountUsageFetchError.rotationDeferred(error)
            }
        }
        return try await performFetchSnapshotResult(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            now: now,
            accessMode: accessMode,
            rotationIntent: rotationIntent,
            additionalRecoveryDestinations: additionalRecoveryDestinations,
            liveCredentialReadPolicy: liveCredentialReadPolicy,
            liveCredentialAccessDenied: liveCredentialAccessDenied,
            storedCredentialSource: storedCredentialSource,
            credentialDidPersist: credentialDidPersist,
            credentialDidResolve: credentialDidResolve
        )
    }

    private func performFetchSnapshotResult(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        now: Date,
        accessMode: CredentialAccessMode,
        rotationIntent: ClaudeRotationIntent,
        additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination>,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?,
        storedCredentialSource: StoredCredentialSource,
        credentialDidPersist: ((ClaudeOAuthCredentials) -> Void)?,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)?
    ) async throws -> ClaudeAccountUsageFetchResult {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            now: now,
            accessMode: accessMode,
            rotationIntent: rotationIntent,
            additionalRecoveryDestinations: additionalRecoveryDestinations,
            liveCredentialReadPolicy: liveCredentialReadPolicy,
            liveCredentialAccessDenied: liveCredentialAccessDenied,
            storedCredentialSource: storedCredentialSource
        )
        credentialDidResolve?(resolution.credentials)
        if resolution.wasRefreshed {
            credentialDidPersist?(resolution.credentials)
        }

        do {
            let usageResult = try await fetchUsage(
                with: resolution,
                for: profile,
                now: now,
                accessMode: accessMode,
                credentialDidPersist: { credentials in
                    credentialDidPersist?(credentials)
                    credentialDidResolve?(credentials)
                }
            )
            credentialDidResolve?(usageResult.credentials)
            // A 2xx body with no recognizable windows must fail the fetch:
            // a parseConfidence-.none snapshot would overwrite the last good
            // one and bypass AppState's CLI fallback.
            guard !usageResult.usage.windows.isEmpty else {
                throw ClaudeAccountUsageFetchError.transport(ClaudeUsageAPIError.malformedResponse)
            }
            return ClaudeAccountUsageFetchResult(
                snapshot: apiClient.makeSnapshot(
                    for: profile,
                    usage: usageResult.usage,
                    now: now
                ),
                credentials: usageResult.credentials
            )
        } catch let error as ClaudeAccountUsageFetchError {
            throw error
        } catch {
            throw ClaudeAccountUsageFetchError.transport(error)
        }
    }

    /// Identity + plan tier from the profile endpoint. Called sparingly (only
    /// when a profile is missing them) — same credential resolution and
    /// single-refresh policy as `fetchSnapshot`.
    public func fetchAccountInfo(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool = false,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        rotationIntent: ClaudeRotationIntent = .scheduledReadOnly,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy = .read,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)? = nil
    ) async throws -> ClaudeAPIAccountInfo {
        do {
            try refreshCoordinator.validateSupportedConfiguration()
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }
        if rotationIntent.allowsCredentialRotation,
           ClaudeOAuthMutationLeaseContext.current == nil {
            do {
                return try await refreshCoordinator.withLease { _ in
                    try await performFetchAccountInfo(
                        for: profile,
                        isActiveCLI: isActiveCLI,
                        accountIsLiveElsewhere: accountIsLiveElsewhere,
                        now: now,
                        accessMode: accessMode,
                        rotationIntent: rotationIntent,
                        liveCredentialReadPolicy: liveCredentialReadPolicy,
                        liveCredentialAccessDenied: liveCredentialAccessDenied
                    )
                }
            } catch let error as ClaudeAccountUsageFetchError {
                throw error
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                throw ClaudeAccountUsageFetchError.rotationDeferred(error)
            }
        }
        return try await performFetchAccountInfo(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            now: now,
            accessMode: accessMode,
            rotationIntent: rotationIntent,
            liveCredentialReadPolicy: liveCredentialReadPolicy,
            liveCredentialAccessDenied: liveCredentialAccessDenied
        )
    }

    private func performFetchAccountInfo(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        now: Date,
        accessMode: CredentialAccessMode,
        rotationIntent: ClaudeRotationIntent,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?
    ) async throws -> ClaudeAPIAccountInfo {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            now: now,
            accessMode: accessMode,
            rotationIntent: rotationIntent,
            additionalRecoveryDestinations: [],
            liveCredentialReadPolicy: liveCredentialReadPolicy,
            liveCredentialAccessDenied: liveCredentialAccessDenied,
            storedCredentialSource: .provider
        )

        do {
            return try await apiClient.fetchAccountInfo(
                accessToken: resolution.credentials.accessToken,
                now: now
            )
        } catch ClaudeUsageAPIError.unauthorized {
            guard !resolution.wasRefreshed else {
                throw ClaudeAccountUsageFetchError.unauthorized
            }
            let refreshed = try await refreshAndPersist(
                resolution,
                for: profile,
                now: now,
                accessMode: accessMode
            )
            do {
                return try await apiClient.fetchAccountInfo(
                    accessToken: refreshed.accessToken,
                    now: now
                )
            } catch ClaudeUsageAPIError.unauthorized {
                throw ClaudeAccountUsageFetchError.unauthorized
            } catch ClaudeUsageAPIError.forbidden {
                throw ClaudeAccountUsageFetchError.forbidden
            }
        } catch ClaudeUsageAPIError.forbidden {
            throw ClaudeAccountUsageFetchError.forbidden
        } catch let error as ClaudeAccountUsageFetchError {
            throw error
        } catch {
            throw ClaudeAccountUsageFetchError.transport(error)
        }
    }

    /// Reuses the credential already resolved for a usage request in the same
    /// workflow. Account enrichment is immediate and read-only, so it must not
    /// reload either the shared item or the app-owned snapshot.
    public func fetchAccountInfo(
        for profile: AccountProfile,
        resolvedCredentials: ClaudeOAuthCredentials,
        now: Date = Date()
    ) async throws -> ClaudeAPIAccountInfo {
        do {
            return try await apiClient.fetchAccountInfo(
                accessToken: resolvedCredentials.accessToken,
                now: now
            )
        } catch ClaudeUsageAPIError.unauthorized {
            throw ClaudeAccountUsageFetchError.unauthorized
        } catch ClaudeUsageAPIError.forbidden {
            throw ClaudeAccountUsageFetchError.forbidden
        } catch {
            throw ClaudeAccountUsageFetchError.transport(error)
        }
    }

    private struct CredentialResolution {
        var credentials: ClaudeOAuthCredentials
        var liveAccessTokenAtRead: String?
        /// Full OAuth-object identity, including the refresh chain and fixed
        /// login expiry. Access-token equality alone cannot prove that Claude
        /// Code did not advance the generation while this workflow waited.
        var liveCredentialFingerprintAtRead: String?
        var liveCredentialsAtRead: ClaudeOAuthCredentials?
        var liveItemLocationAtRead: ClaudeKeychainItemLocation?
        var storedAccessTokenAtRead: String?
        var storedCredentialFingerprintAtRead: String?
        /// The exact app-owned OAuth object observed before exchange. Primary
        /// persistence merges the rotated fields into this owner so profile-
        /// local and unknown fields are never replaced by the live holder's
        /// JSON when the active credential was selected for refresh.
        var storedCredentialsAtRead: ClaudeOAuthCredentials?
        var preloadedStoredRecordAtRead: StoredCredentialRecord?
        var liveAccessWasDenied: Bool
        var isActiveCLI: Bool
        /// True for the active profile and for an inactive user-clicked switch
        /// whose target still shares the live single-use refresh chain. Such a
        /// rotation must update the provider-owned item in the same lease.
        var liveOwnerMustBeUpdated: Bool
        /// A sibling profile owns the live CLI login for this same account —
        /// this copy shares the active login's single-use chain and must never
        /// be rotated in any mode.
        var accountIsLiveElsewhere: Bool
        var wasRefreshed: Bool
        /// The caller's explicit reason for this workflow. This—not Keychain
        /// access mode or active/inactive ownership—controls rotation.
        var rotationIntent: ClaudeRotationIntent
        var additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination>
    }

    private enum StoredCredentialSource {
        case provider
        case preloaded(StoredCredentialRecord)
    }

    /// The single rotation gate both guard sites share. A shared-account sibling
    /// is never rotated (it would strand the live login). Both active and
    /// inactive credentials rotate only on an explicit Retry or user-clicked
    /// switch; scheduled polling and automatic switching are read-only.
    private static func mayRotate(
        accountIsLiveElsewhere: Bool,
        rotationIntent: ClaudeRotationIntent
    ) -> Bool {
        if accountIsLiveElsewhere {
            return false
        }
        return rotationIntent.allowsCredentialRotation
    }

    /// Missing refresh credentials and a locally known fixed-login expiry are
    /// terminal facts, not reasons to defer rotation. Classify them before the
    /// read-only intent gate so scheduled work can ask for login without ever
    /// acquiring the shared locks or attempting a token request.
    private static func requireUsableRefreshCredential(
        _ credentials: ClaudeOAuthCredentials,
        now: Date
    ) throws {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeAccountUsageFetchError.refreshFailed(
                ClaudeOAuthError.missingRefreshToken
            )
        }
        guard !credentials.isLoginExpired(asOf: now) else {
            throw ClaudeAccountUsageFetchError.refreshFailed(
                ClaudeOAuthError.refreshTokenExpired
            )
        }
    }

    private static func rotationBlockedError(
        accountIsLiveElsewhere: Bool
    ) -> ClaudeAccountUsageFetchError {
        accountIsLiveElsewhere ? .accountActiveElsewhere : .interactiveRefreshRequired
    }

    /// Active profiles consider both copies and use the credential generation
    /// with the later login/access expiry. Reading a newer generation is safe;
    /// rotating any generation requires an explicit Retry or user switch.
    private func resolveCredentials(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        now: Date,
        accessMode: CredentialAccessMode,
        rotationIntent: ClaudeRotationIntent,
        additionalRecoveryDestinations: Set<ClaudeRotationRecoveryDestination>,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?,
        storedCredentialSource: StoredCredentialSource
    ) async throws -> CredentialResolution {
        var live: ClaudeOAuthCredentials?
        var liveRecord: LiveClaudeOAuthCredentialRecord?
        var liveAccessDenied = false
        if isActiveCLI {
            switch liveCredentialReadPolicy {
            case .knownDenied:
                liveAccessDenied = true
            case .preloaded(let preloaded):
                liveRecord = preloaded
                live = preloaded?.credentials
            case .read:
                do {
                    liveRecord = try credentials.liveClaudeOAuthCredentialRecord(
                        accessMode: accessMode
                    )
                    live = liveRecord?.credentials
                } catch let error as ClaudeCodeCredentialsKeychainError where error.isKeychainAccessDenied {
                    liveAccessDenied = true
                    liveCredentialAccessDenied?(
                        error.credentialAccessDisposition ?? .interactionRequired
                    )
                } catch {
                    throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
                }
            }
        }

        var stored: ClaudeOAuthCredentials?
        var preloadedStoredRecord: StoredCredentialRecord?
        var storedAccessDenied = false
        var storedReadSucceeded = false
        switch storedCredentialSource {
        case .preloaded(let preloaded):
            stored = preloaded.claudeOAuthCredentials
            preloadedStoredRecord = preloaded
            storedReadSucceeded = true
        case .provider:
            do {
                stored = try credentials.storedClaudeOAuthCredentials(
                    for: profile.id,
                    accessMode: accessMode
                )
                storedReadSucceeded = true
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                storedAccessDenied = true
                stored = nil
            } catch {
                // Corrupt or ambiguous saved credentials are not equivalent to
                // absence. Fail closed so presentation can prioritize repair
                // guidance and discard any cached fixed-expiry claim.
                throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
            }
        }

        let forcePreparedRecoveryProbe = try reconcileRecoveryJournal(
            for: profile,
            isActiveCLI: isActiveCLI,
            rotationIntent: rotationIntent,
            accessMode: accessMode,
            live: &live,
            liveRecord: &liveRecord,
            stored: &stored,
            preloadedStoredRecord: &preloadedStoredRecord
        )

        if let repair = storedRepairs.entry(for: profile.id) {
            guard storedReadSucceeded else {
                if storedAccessDenied {
                    throw ClaudeAccountUsageFetchError.keychainLocked
                }
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude has a fresh login generation waiting to be saved, but the saved account copy is unreadable. Retry after restoring Keychain access."
                    )
                )
            }

            let recoveryFingerprint = rotatedCredentialFingerprint(repair.credentials)
            let storedFingerprint = stored.map(rotatedCredentialFingerprint)
            let storedStillExpected: Bool
            if let stored {
                storedStillExpected = repair.staleStoredAccessTokenFingerprint
                    == accessTokenFingerprint(stored.accessToken)
            } else {
                storedStillExpected = repair.staleStoredAccessTokenFingerprint == nil
            }
            let liveStillOwnsRecovery = !repair.requiresFreshLiveCredential
                || live.map(rotatedCredentialFingerprint) == recoveryFingerprint

            if storedFingerprint == recoveryFingerprint {
                // A previous attempt completed even if its caller did not see
                // the success. Adopt the durable generation.
                storedRepairs.clear(for: profile.id)
                stored = repair.credentials
            } else if !storedStillExpected || !liveStillOwnsRecovery {
                // A newer external login or account switch wins. Never replay
                // the pending generation over an owner we did not observe.
                storedRepairs.clear(for: profile.id)
            } else {
                guard rotationIntent.allowsCredentialRotation else {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "Claude refreshed this login, but its saved account copy still needs repair. Use Retry to finish saving it without rotating again."
                        )
                    )
                }

                do {
                    _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                    let repaired: Bool
                    if let expectedStored = stored {
                        if let storedRecord = preloadedStoredRecord {
                            repaired = try credentials.replaceStoredClaudeOAuthCredentials(
                                repair.credentials,
                                for: profile.id,
                                using: storedRecord,
                                ifCurrentCredentialsMatch: expectedStored,
                                accessMode: accessMode
                            ) != nil
                        } else {
                            repaired = try credentials.replaceStoredClaudeOAuthCredentials(
                                repair.credentials,
                                for: profile.id,
                                ifCurrentCredentialsMatch: expectedStored,
                                accessMode: accessMode
                            )
                        }
                    } else {
                        try credentials.updateStoredClaudeOAuthCredentials(
                            repair.credentials,
                            for: profile.id,
                            accessMode: accessMode
                        )
                        repaired = true
                    }
                    guard repaired else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The saved Claude credential changed while its fresh generation was being repaired. Retry after reconciliation finishes."
                            )
                        )
                    }
                } catch let error as ClaudeAccountUsageFetchError {
                    throw error
                } catch let error as ClaudeOAuthRefreshCoordinatorError {
                    throw ClaudeAccountUsageFetchError.rotationDeferred(error)
                } catch {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "The fresh Claude credential could not be saved yet. Retry after restoring Keychain access."
                        )
                    )
                }

                storedRepairs.clear(for: profile.id)
                stored = repair.credentials
            }
        }

        if isActiveCLI,
           let repair = liveRepairs.entry(for: profile.id) {
            guard storedReadSucceeded else {
                // A denial, decode failure, or unavailable private Keychain
                // cannot prove that the recovery generation changed. Retain
                // the marker and fail closed.
                throw ClaudeAccountUsageFetchError.keychainLocked
            }
            let storedFingerprint = stored.map(rotatedCredentialFingerprint)
            if storedFingerprint != repair.recoveryFingerprint {
                // The saved generation changed independently, so this old
                // repair marker must not suppress the new credential.
                liveRepairs.clear(for: profile.id)
            } else if let stored {
                guard let currentLive = live else {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "The active Claude credential still needs repair in its current Keychain item. Use Retry after authorizing access."
                        )
                    )
                }
                let liveTokenStillStale = accessTokenFingerprint(
                    currentLive.accessToken
                ) == repair.staleLiveAccessTokenFingerprint
                if itemLocationFingerprint(liveRecord?.itemLocation)
                    != repair.staleLiveItemFingerprint,
                   liveTokenStillStale,
                   !rotationIntent.allowsCredentialRotation {
                    // A replacement item is a new authorization context. Do
                    // not copy a recovery token into it during scheduled work,
                    // even when Claude preserved the same token string. Once
                    // the replacement is explicitly authorized, Retry may
                    // repair the freshly pinned location below.
                    throw ClaudeAccountUsageFetchError.keychainLocked
                }
                let liveFingerprint = rotatedCredentialFingerprint(currentLive)
                if liveFingerprint == repair.recoveryFingerprint {
                    liveRepairs.clear(for: profile.id)
                } else if accessTokenFingerprint(currentLive.accessToken)
                            != repair.staleLiveAccessTokenFingerprint {
                    // Claude or the user replaced the live generation after
                    // the failed write. That external change wins.
                    liveRepairs.clear(for: profile.id)
                } else {
                    guard rotationIntent.allowsCredentialRotation else {
                        // A valid stored recovery token may serve usage only
                        // when no failed active rotation is outstanding. Keep
                        // the visible remediation state until an explicit
                        // retry repairs the provider-owned item.
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The active Claude Code credential still needs repair. Use Retry to restore the saved fresh generation."
                            )
                        )
                    }
                    guard let mergedLive = currentLive.mergingRotatedTokenFields(
                        from: stored
                    ) else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The active Claude credential could not merge its saved recovery generation. Retry after repairing the saved login."
                            )
                        )
                    }
                    do {
                        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                        guard try credentials.replaceLiveClaudeOAuthCredentials(
                            mergedLive,
                            at: liveRecord?.itemLocation,
                            ifCurrentCredentialsMatch: currentLive,
                            accessMode: accessMode
                        ) else {
                            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                                ClaudeCredentialRepairRequiredError(
                                    reason: "The active Claude credential changed while its saved recovery copy was being restored. Retry after reconciliation finishes."
                                )
                            )
                        }
                    } catch let error as ClaudeCodeCredentialsKeychainError
                        where error.isKeychainAccessDenied {
                        throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                            error: error,
                            item: liveRecord?.itemLocation
                        )
                    } catch let error as ClaudeAccountUsageFetchError {
                        throw error
                    } catch let error as ClaudeOAuthRefreshCoordinatorError {
                        throw ClaudeAccountUsageFetchError.rotationDeferred(error)
                    } catch {
                        throw ClaudeAccountUsageFetchError.refreshFailed(error)
                    }
                    liveRepairs.clear(for: profile.id)
                    live = mergedLive
                }
            }
        }

        // The encrypted recovery journal is the primary crash boundary, but
        // its Keychain item can be persistently unavailable while one of the
        // ordinary credential owners still commits successfully. On relaunch,
        // that durable owner is itself a recovery copy. A strictly fresher
        // live generation may therefore repair the active profile's stale
        // stored snapshot on the next explicit action, without spending the
        // refresh token again. Scheduled work only surfaces the split.
        if isActiveCLI,
           let currentLive = live,
           let currentStored = stored,
           rotatedCredentialFingerprint(currentLive)
                != rotatedCredentialFingerprint(currentStored),
           credentialIsFresher(currentLive, than: currentStored, asOf: now),
           rotationIntent.allowsCredentialRotation
                || currentStored.isExpired(asOf: now)
                || currentStored.isLoginExpired(asOf: now) {
            guard rotationIntent.allowsCredentialRotation else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude Code has a newer durable login generation than this account's saved copy. Use Retry to repair the saved copy without rotating again."
                    )
                )
            }
            guard let mergedStored = currentStored.mergingRotatedTokenFields(
                from: currentLive
            ) else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "The saved Claude profile could not merge the newer durable Claude Code generation. Retry after repairing the saved login."
                    )
                )
            }

            do {
                _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                let repaired: Bool
                if let expectedRecord = preloadedStoredRecord {
                    if let committed = try credentials
                        .replaceStoredClaudeOAuthCredentials(
                            mergedStored,
                            for: profile.id,
                            using: expectedRecord,
                            ifCurrentCredentialsMatch: currentStored,
                            accessMode: accessMode
                        ) {
                        preloadedStoredRecord = committed
                        repaired = true
                    } else {
                        repaired = false
                    }
                } else {
                    repaired = try credentials.replaceStoredClaudeOAuthCredentials(
                        mergedStored,
                        for: profile.id,
                        ifCurrentCredentialsMatch: currentStored,
                        accessMode: accessMode
                    )
                }

                if repaired {
                    stored = mergedStored
                } else if let latest = try credentials.storedClaudeOAuthCredentials(
                    for: profile.id,
                    accessMode: accessMode
                ), rotatedCredentialFingerprint(latest)
                    == rotatedCredentialFingerprint(currentLive) {
                    // A prior repair completed even though its CAS result was
                    // not observed. Adopt the durable generation.
                    stored = latest
                } else {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "The saved Claude credential changed while its newer live generation was being recovered. Retry after reconciliation finishes."
                        )
                    )
                }
            } catch let error as ClaudeAccountUsageFetchError {
                throw error
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                throw ClaudeAccountUsageFetchError.rotationDeferred(error)
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "The newer durable Claude Code generation could not be saved to this account yet. Restore Keychain access, then retry."
                    )
                )
            }
        }

        let selected: ClaudeOAuthCredentials?
        if isActiveCLI, let live, let stored {
            selected = credentialIsFresher(stored, than: live, asOf: now)
                ? stored
                : live
        } else if isActiveCLI {
            selected = live ?? stored
        } else {
            selected = stored
        }

        guard var active = selected else {
            if liveAccessDenied || storedAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            }
            throw ClaudeAccountUsageFetchError.noCredentials
        }
        var effectiveLiveAccessToken = live?.accessToken
        var effectiveStoredAccessToken = stored?.accessToken
        var wasRefreshed = false

        if forcePreparedRecoveryProbe || active.isExpired(asOf: now) {
            try Self.requireUsableRefreshCredential(active, now: now)
            if isActiveCLI, live == nil {
                throw liveAccessDenied
                    ? ClaudeAccountUsageFetchError.keychainLocked
                    : ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            guard Self.mayRotate(
                accountIsLiveElsewhere: accountIsLiveElsewhere,
                rotationIntent: rotationIntent
            ) else {
                throw Self.rotationBlockedError(accountIsLiveElsewhere: accountIsLiveElsewhere)
            }
            active = try await refreshAndPersist(
                CredentialResolution(
                    credentials: active,
                    liveAccessTokenAtRead: live?.accessToken,
                    liveCredentialFingerprintAtRead: live.map(credentialFingerprint),
                    liveCredentialsAtRead: live,
                    liveItemLocationAtRead: liveRecord?.itemLocation,
                    storedAccessTokenAtRead: stored?.accessToken,
                    storedCredentialFingerprintAtRead: stored.map(credentialFingerprint),
                    storedCredentialsAtRead: stored,
                    preloadedStoredRecordAtRead: preloadedStoredRecord,
                    liveAccessWasDenied: liveAccessDenied,
                    isActiveCLI: isActiveCLI,
                    liveOwnerMustBeUpdated: isActiveCLI,
                    accountIsLiveElsewhere: accountIsLiveElsewhere,
                    wasRefreshed: false,
                    rotationIntent: rotationIntent,
                    additionalRecoveryDestinations: additionalRecoveryDestinations
                ),
                for: profile,
                now: now,
                accessMode: accessMode
            )
            wasRefreshed = true
            effectiveStoredAccessToken = active.accessToken
            if isActiveCLI, rotationIntent.allowsCredentialRotation, live != nil {
                effectiveLiveAccessToken = active.accessToken
            }
        } else if isActiveCLI,
                  let currentLive = live,
                  let liveAccessToken = live?.accessToken,
                  liveAccessToken != active.accessToken {
            // An earlier build may have saved a rotated generation without
            // repairing the live item. Never hide that split with a successful
            // scheduled usage read; an explicit Retry heals it without
            // spending the fresh refresh token again, including after relaunch.
            guard rotationIntent.allowsCredentialRotation else {
                throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            guard let mergedLive = currentLive.mergingRotatedTokenFields(
                from: active
            ) else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "The active Claude credential could not merge its saved token generation. Retry after repairing the saved login."
                    )
                )
            }
            do {
                _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                guard try credentials.replaceLiveClaudeOAuthCredentials(
                    mergedLive,
                    at: liveRecord?.itemLocation,
                    ifCurrentCredentialsMatch: currentLive,
                    accessMode: accessMode
                ) else {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "The active Claude credential changed while its saved generation was being restored. Retry after reconciliation finishes."
                        )
                    )
                }
                effectiveLiveAccessToken = active.accessToken
            } catch let error as ClaudeCodeCredentialsKeychainError
                where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                    error: error,
                    item: liveRecord?.itemLocation
                )
            } catch let error as ClaudeAccountUsageFetchError {
                throw error
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                throw ClaudeAccountUsageFetchError.rotationDeferred(error)
            } catch {
                throw ClaudeAccountUsageFetchError.refreshFailed(error)
            }
        }

        return CredentialResolution(
            credentials: active,
            liveAccessTokenAtRead: effectiveLiveAccessToken,
            liveCredentialFingerprintAtRead: live.map(credentialFingerprint),
            liveCredentialsAtRead: live,
            liveItemLocationAtRead: liveRecord?.itemLocation,
            storedAccessTokenAtRead: effectiveStoredAccessToken,
            storedCredentialFingerprintAtRead: stored.map(credentialFingerprint),
            storedCredentialsAtRead: stored,
            preloadedStoredRecordAtRead: preloadedStoredRecord,
            liveAccessWasDenied: liveAccessDenied,
            isActiveCLI: isActiveCLI,
            liveOwnerMustBeUpdated: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            wasRefreshed: wasRefreshed,
            rotationIntent: rotationIntent,
            additionalRecoveryDestinations: additionalRecoveryDestinations
        )
    }

    private func reconcileRecoveryJournal(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        rotationIntent: ClaudeRotationIntent,
        accessMode: CredentialAccessMode,
        live: inout ClaudeOAuthCredentials?,
        liveRecord: inout LiveClaudeOAuthCredentialRecord?,
        stored: inout ClaudeOAuthCredentials?,
        preloadedStoredRecord: inout StoredCredentialRecord?
    ) throws -> Bool {
        guard let recoveryStore else { return false }

        let loadedRecords: [ClaudeRotationRecoveryRecord]
        do {
            loadedRecords = try recoveryStore.loadAll(accessMode: accessMode)
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.keychainLocked
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude credential recovery is waiting for access to its encrypted journal. Authorize Keychain access, then retry."
                )
            )
        }
        var forcePreparedRecoveryProbe = false
        var records: [ClaudeRotationRecoveryRecord] = []
        for loadedRecord in loadedRecords {
            if let materialized = try materializePreparedRecoveryRecord(
                loadedRecord,
                accessMode: accessMode,
                allowUnchangedExplicitProbe: rotationIntent.allowsCredentialRotation
            ) {
                records.append(materialized)
            } else {
                forcePreparedRecoveryProbe = true
            }
        }

        if rotationIntent.allowsCredentialRotation {
            try reconcileAllPendingRecoveryDestinations(
                records,
                for: profile,
                isActiveCLI: isActiveCLI,
                accessMode: accessMode,
                live: &live,
                liveRecord: &liveRecord,
                stored: &stored,
                preloadedStoredRecord: &preloadedStoredRecord
            )
            return forcePreparedRecoveryProbe
        }

        for originalRecord in records {
            let storedDestination = ClaudeRotationRecoveryDestination.storedProfile(
                profile.id
            )
            let handlesStored = originalRecord.pendingDestinations.contains(
                storedDestination
            )
            let handlesLive = isActiveCLI
                && originalRecord.pendingDestinations.contains(.liveClaudeCode)
            guard handlesStored || handlesLive else { continue }
            guard let fresh = originalRecord.credentials else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude credential recovery found an unreadable encrypted generation. Sign in again only after exporting diagnostics."
                    )
                )
            }

            let freshFingerprint = rotatedCredentialFingerprint(fresh)
            let liveNeedsRepair: Bool
            if handlesLive, let live {
                switch postExchangeOwnerDisposition(
                    live,
                    staleChainFingerprint: originalRecord.staleChainFingerprint,
                    refreshed: fresh,
                    ownerGenerationBaselines: originalRecord.ownerGenerationBaselines,
                    destination: .liveClaudeCode
                ) {
                case .pending:
                    liveNeedsRepair = true
                case .fresh, .superseding:
                    liveNeedsRepair = false
                }
            } else {
                liveNeedsRepair = handlesLive
            }
            let storedNeedsRepair: Bool
            if handlesStored, let stored {
                switch postExchangeOwnerDisposition(
                    stored,
                    staleChainFingerprint: originalRecord.staleChainFingerprint,
                    refreshed: fresh,
                    ownerGenerationBaselines: originalRecord.ownerGenerationBaselines,
                    destination: storedDestination
                ) {
                case .pending:
                    storedNeedsRepair = true
                case .fresh, .superseding:
                    storedNeedsRepair = false
                }
            } else {
                storedNeedsRepair = handlesStored
            }

            if liveNeedsRepair || storedNeedsRepair {
                guard rotationIntent.allowsCredentialRotation else {
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "Claude has a safely recovered login generation waiting to be reconciled. Use Retry to finish without rotating again."
                        )
                    )
                }
                do {
                    _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                } catch let error as ClaudeOAuthRefreshCoordinatorError {
                    throw ClaudeAccountUsageFetchError.rotationDeferred(error)
                }
            }

            var record = originalRecord
            if handlesLive, let currentLive = live {
                if rotatedCredentialFingerprint(currentLive) == freshFingerprint {
                    if rotationIntent.allowsCredentialRotation {
                        record.pendingDestinations.remove(.liveClaudeCode)
                        try persistRecoveryRecord(record, accessMode: accessMode)
                    }
                } else if liveNeedsRepair {
                    guard let mergedLive = currentLive.mergingRotatedTokenFields(
                        from: fresh
                    ) else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The active Claude credential could not merge its recovered token generation. Retry after repairing the saved login."
                            )
                        )
                    }
                    do {
                        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                        guard try credentials.replaceLiveClaudeOAuthCredentials(
                            mergedLive,
                            at: liveRecord?.itemLocation,
                            ifCurrentCredentialsMatch: currentLive,
                            accessMode: accessMode
                        ) else {
                            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                                ClaudeCredentialRepairRequiredError(
                                    reason: "The active Claude credential changed while its recovered generation was being restored. Retry after reconciliation finishes."
                                )
                            )
                        }
                    } catch let error as ClaudeCodeCredentialsKeychainError
                        where error.isKeychainAccessDenied {
                        throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                            error: error,
                            item: liveRecord?.itemLocation
                        )
                    }
                    live = mergedLive
                    record.pendingDestinations.remove(.liveClaudeCode)
                    try persistRecoveryRecord(record, accessMode: accessMode)
                } else if rotationIntent.allowsCredentialRotation {
                    // A different live login superseded the stale chain.
                    record.pendingDestinations.remove(.liveClaudeCode)
                    try persistRecoveryRecord(record, accessMode: accessMode)
                }
            } else if handlesLive, rotationIntent.allowsCredentialRotation {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude has a recovered active generation, but the live Claude Code item is unavailable. Restore Keychain access, then retry."
                    )
                )
            }

            if handlesStored {
                if stored.map(rotatedCredentialFingerprint) == freshFingerprint {
                    if rotationIntent.allowsCredentialRotation {
                        record.pendingDestinations.remove(storedDestination)
                        try persistRecoveryRecord(record, accessMode: accessMode)
                    }
                } else if storedNeedsRepair || stored == nil {
                    guard rotationIntent.allowsCredentialRotation else {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "Claude has a safely recovered login generation waiting to be saved. Use Retry to finish without rotating again."
                            )
                        )
                    }
                    let mergedStored: ClaudeOAuthCredentials
                    if let stored {
                        guard let merged = stored.mergingRotatedTokenFields(
                            from: fresh
                        ) else {
                            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                                ClaudeCredentialRepairRequiredError(
                                    reason: "The saved Claude profile could not merge its recovered token generation. Retry after repairing the saved login."
                                )
                            )
                        }
                        mergedStored = merged
                    } else {
                        mergedStored = fresh
                    }
                    do {
                        _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                        if let expectedStored = stored {
                            let persisted: Bool
                            if let preloadedStoredRecord {
                                persisted = try credentials.replaceStoredClaudeOAuthCredentials(
                                    mergedStored,
                                    for: profile.id,
                                    using: preloadedStoredRecord,
                                    ifCurrentCredentialsMatch: expectedStored,
                                    accessMode: accessMode
                                ) != nil
                            } else {
                                persisted = try credentials.replaceStoredClaudeOAuthCredentials(
                                    mergedStored,
                                    for: profile.id,
                                    ifCurrentCredentialsMatch: expectedStored,
                                    accessMode: accessMode
                                )
                            }
                            guard persisted else {
                                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                                    ClaudeCredentialRepairRequiredError(
                                        reason: "The saved Claude credential changed while its recovered generation was being restored. Retry after reconciliation finishes."
                                    )
                                )
                            }
                        } else {
                            try credentials.updateStoredClaudeOAuthCredentials(
                                mergedStored,
                                for: profile.id,
                                accessMode: accessMode
                            )
                        }
                    } catch let error as ClaudeAccountUsageFetchError {
                        throw error
                    } catch {
                        throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                            ClaudeCredentialRepairRequiredError(
                                reason: "The recovered Claude credential could not be saved yet. Restore Keychain access, then retry."
                            )
                        )
                    }
                    stored = mergedStored
                    record.pendingDestinations.remove(storedDestination)
                    try persistRecoveryRecord(record, accessMode: accessMode)
                } else if rotationIntent.allowsCredentialRotation {
                    // A newer stored login superseded the journal generation.
                    record.pendingDestinations.remove(storedDestination)
                    try persistRecoveryRecord(record, accessMode: accessMode)
                }
            }
        }
        return false
    }

    /// A prepared record deliberately contains the pre-exchange credential,
    /// not the fresh secret. It therefore cannot prove that an advanced owner
    /// came from this process rather than an external Claude login. Changed
    /// owners always win and are never replayed into stale siblings. A fresh
    /// app-issued generation is recoverable only from a `freshGeneration`
    /// checkpoint, which is required before normal owner writes.
    private func materializePreparedRecoveryRecord(
        _ record: ClaudeRotationRecoveryRecord,
        accessMode: CredentialAccessMode,
        allowUnchangedExplicitProbe: Bool = false
    ) throws -> ClaudeRotationRecoveryRecord? {
        guard record.isPrepared else { return record }
        guard let baselines = record.ownerGenerationBaselines else {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude found a prepared recovery transaction without exact owner baselines. Leave the credentials unchanged and renew the login only after exporting diagnostics."
                )
            )
        }

        var changedGenerations: [String: ClaudeOAuthCredentials] = [:]
        for destination in record.pendingDestinations {
            let current: ClaudeOAuthCredentials?
            do {
                switch destination {
                case .liveClaudeCode:
                    current = try credentials.liveClaudeOAuthCredentialRecord(
                        accessMode: accessMode
                    )?.credentials
                case .storedProfile(let profileID):
                    current = try credentials.storedClaudeOAuthCredentials(
                        for: profileID,
                        accessMode: accessMode
                    )
                }
            } catch let error as ClaudeCodeCredentialsKeychainError
                where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
            }

            guard let current else { continue }
            let fingerprint = rotatedCredentialFingerprint(current)
            if baselines[destination] != fingerprint {
                changedGenerations[fingerprint] = current
            }
        }

        guard !changedGenerations.isEmpty else {
            guard allowUnchangedExplicitProbe else {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude found an interrupted prepared refresh with unchanged local owners. Use Retry to safely probe the pinned refresh token; scheduled work will not consume it."
                    )
                )
            }
            do {
                _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                try recoveryStore?.delete(id: record.id, accessMode: accessMode)
            } catch let error as ClaudeOAuthRefreshCoordinatorError {
                throw ClaudeAccountUsageFetchError.rotationDeferred(error)
            } catch {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude could not clear an unchanged prepared refresh before probing it. Restore encrypted journal access, then Retry."
                    )
                )
            }
            return nil
        }
        guard allowUnchangedExplicitProbe else {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "One or more Claude credential owners changed while a prepared refresh was pending. Use Retry to adopt those external generations without copying them into other accounts."
                )
            )
        }
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
            try recoveryStore?.delete(id: record.id, accessMode: accessMode)
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude could not clear a prepared refresh after an external credential change. Restore encrypted journal access, then Retry."
                )
            )
        }
        // Return a process-local no-op sentinel rather than nil: current owner
        // generations are adopted normally, but no forced stale-chain probe is
        // performed merely because an external login changed one destination.
        var superseded = record
        superseded.phase = .freshGeneration
        superseded.pendingDestinations.removeAll()
        return superseded
    }

    /// An explicit Retry or user-clicked switch owns one provider-wide lease,
    /// so it reconciles the complete encrypted journal rather than only the row
    /// that initiated the action. This is what lets Retry on already-committed
    /// owner A repair pending sibling B after a crash without another exchange.
    private func reconcileAllPendingRecoveryDestinations(
        _ records: [ClaudeRotationRecoveryRecord],
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accessMode: CredentialAccessMode,
        live: inout ClaudeOAuthCredentials?,
        liveRecord: inout LiveClaudeOAuthCredentialRecord?,
        stored: inout ClaudeOAuthCredentials?,
        preloadedStoredRecord: inout StoredCredentialRecord?
    ) throws {
        var firstFailure: Error?

        for originalRecord in records {
            guard let fresh = originalRecord.credentials else {
                if firstFailure == nil {
                    firstFailure = ClaudeCredentialRepairRequiredError(
                        reason: "Claude credential recovery found an unreadable encrypted generation."
                    )
                }
                continue
            }

            var record = originalRecord
            let orderedDestinations = record.pendingDestinations.sorted {
                recoveryDestinationSortKey($0) < recoveryDestinationSortKey($1)
            }

            for destination in orderedDestinations {
                do {
                    _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                    var destinationCompleted = false

                    switch destination {
                    case .liveClaudeCode:
                        guard let currentRecord = try credentials
                            .liveClaudeOAuthCredentialRecord(accessMode: accessMode) else {
                            throw ClaudeCredentialRepairRequiredError(
                                reason: "The live Claude Code credential is unavailable for recovery."
                            )
                        }
                        var resolvedRecord = currentRecord
                        switch postExchangeOwnerDisposition(
                            currentRecord.credentials,
                            staleChainFingerprint: record.staleChainFingerprint,
                            refreshed: fresh,
                            ownerGenerationBaselines: record.ownerGenerationBaselines,
                            destination: destination
                        ) {
                        case .fresh, .superseding:
                            destinationCompleted = true
                        case .pending:
                            guard let merged = currentRecord.credentials
                                .mergingRotatedTokenFields(from: fresh) else {
                                throw ClaudeCredentialRepairRequiredError(
                                    reason: "The live Claude owner could not merge its recovered token generation."
                                )
                            }
                            if try credentials.replaceLiveClaudeOAuthCredentials(
                                merged,
                                at: currentRecord.itemLocation,
                                ifCurrentCredentialsMatch: currentRecord.credentials,
                                accessMode: accessMode
                            ) {
                                resolvedRecord = LiveClaudeOAuthCredentialRecord(
                                    credentials: merged,
                                    itemLocation: currentRecord.itemLocation
                                )
                                destinationCompleted = true
                            } else if let latest = try credentials
                                .liveClaudeOAuthCredentialRecord(accessMode: accessMode) {
                                switch postExchangeOwnerDisposition(
                                    latest.credentials,
                                    staleChainFingerprint: record.staleChainFingerprint,
                                    refreshed: fresh,
                                    ownerGenerationBaselines: record.ownerGenerationBaselines,
                                    destination: destination
                                ) {
                                case .fresh, .superseding:
                                    resolvedRecord = latest
                                    destinationCompleted = true
                                case .pending:
                                    break
                                }
                            }
                        }
                        if destinationCompleted, isActiveCLI {
                            live = resolvedRecord.credentials
                            liveRecord = resolvedRecord
                        }

                    case .storedProfile(let ownerID):
                        let currentOwner: ClaudeOAuthCredentials?
                        if ownerID == profile.id {
                            currentOwner = stored
                        } else {
                            currentOwner = try credentials.storedClaudeOAuthCredentials(
                                for: ownerID,
                                accessMode: accessMode
                            )
                        }

                        if let currentOwner {
                            var resolvedOwner = currentOwner
                            switch postExchangeOwnerDisposition(
                                currentOwner,
                                staleChainFingerprint: record.staleChainFingerprint,
                                refreshed: fresh,
                                ownerGenerationBaselines: record.ownerGenerationBaselines,
                                destination: destination
                            ) {
                            case .fresh, .superseding:
                                destinationCompleted = true
                            case .pending:
                                guard let merged = currentOwner
                                    .mergingRotatedTokenFields(from: fresh) else {
                                    throw ClaudeCredentialRepairRequiredError(
                                        reason: "A saved Claude owner could not merge its recovered token generation."
                                    )
                                }
                                if ownerID == profile.id,
                                   let expectedRecord = preloadedStoredRecord {
                                    if let committed = try credentials
                                        .replaceStoredClaudeOAuthCredentials(
                                            merged,
                                            for: ownerID,
                                            using: expectedRecord,
                                            ifCurrentCredentialsMatch: currentOwner,
                                            accessMode: accessMode
                                        ) {
                                        preloadedStoredRecord = committed
                                        resolvedOwner = merged
                                        destinationCompleted = true
                                    }
                                } else if try credentials
                                    .replaceStoredClaudeOAuthCredentials(
                                        merged,
                                        for: ownerID,
                                        ifCurrentCredentialsMatch: currentOwner,
                                        accessMode: accessMode
                                    ) {
                                    resolvedOwner = merged
                                    destinationCompleted = true
                                }

                                if !destinationCompleted,
                                   let latest = try credentials
                                    .storedClaudeOAuthCredentials(
                                        for: ownerID,
                                        accessMode: accessMode
                                    ) {
                                    switch postExchangeOwnerDisposition(
                                        latest,
                                        staleChainFingerprint: record.staleChainFingerprint,
                                        refreshed: fresh,
                                        ownerGenerationBaselines: record.ownerGenerationBaselines,
                                        destination: destination
                                    ) {
                                    case .fresh, .superseding:
                                        resolvedOwner = latest
                                        destinationCompleted = true
                                    case .pending:
                                        break
                                    }
                                }
                            }
                            if destinationCompleted, ownerID == profile.id {
                                stored = resolvedOwner
                            }
                        } else {
                            // An existing profile snapshot may have lost only
                            // its OAuth item. The provider decides whether the
                            // owner still exists; a removed profile fails here
                            // and remains journaled until removal reconciliation.
                            try credentials.updateStoredClaudeOAuthCredentials(
                                fresh,
                                for: ownerID,
                                accessMode: accessMode
                            )
                            destinationCompleted = true
                            if ownerID == profile.id {
                                stored = fresh
                            }
                        }
                    }

                    if destinationCompleted {
                        record.pendingDestinations.remove(destination)
                    } else if firstFailure == nil {
                        firstFailure = ClaudeCredentialRepairRequiredError(
                            reason: "A Claude credential owner changed while recovery was reconciling it."
                        )
                    }
                } catch let error as ClaudeOAuthRefreshCoordinatorError {
                    throw ClaudeAccountUsageFetchError.rotationDeferred(error)
                } catch let error as ClaudeAccountUsageFetchError {
                    if case .rotationDeferred = error { throw error }
                    if firstFailure == nil { firstFailure = error }
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }

            if record != originalRecord {
                do {
                    try persistRecoveryRecord(record, accessMode: accessMode)
                } catch let error as ClaudeAccountUsageFetchError {
                    if case .rotationDeferred = error { throw error }
                    if firstFailure == nil { firstFailure = error }
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
            if !record.pendingDestinations.isEmpty, firstFailure == nil {
                firstFailure = ClaudeCredentialRepairRequiredError(
                    reason: "One or more Claude credential owners still need recovery."
                )
            }
        }

        if let failure = firstFailure {
            if let fetchError = failure as? ClaudeAccountUsageFetchError {
                throw fetchError
            }
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude's fresh credential is safely journaled, but not every local owner could be repaired. \(failure.localizedDescription)"
                )
            )
        }
    }

    private func persistRecoveryRecord(
        _ record: ClaudeRotationRecoveryRecord,
        accessMode: CredentialAccessMode
    ) throws {
        guard let recoveryStore else { return }
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
            if record.pendingDestinations.isEmpty {
                try recoveryStore.delete(id: record.id, accessMode: accessMode)
            } else {
                try recoveryStore.save(record, accessMode: accessMode)
            }
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude credentials were recovered, but the encrypted recovery journal could not be updated yet. Retry after restoring Keychain access."
                )
            )
        }
    }

    private struct UsageResolution {
        var usage: ClaudeAPIUsage
        var credentials: ClaudeOAuthCredentials
    }

    private func fetchUsage(
        with resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode,
        credentialDidPersist: ((ClaudeOAuthCredentials) -> Void)? = nil
    ) async throws -> UsageResolution {
        do {
            return UsageResolution(
                usage: try await apiClient.fetchUsage(
                    accessToken: resolution.credentials.accessToken
                ),
                credentials: resolution.credentials
            )
        } catch ClaudeUsageAPIError.unauthorized {
            // The token can be revoked before its recorded expiry; one forced
            // refresh is the only retry. Active background work defers this to
            // an explicit Retry so it cannot race Claude Code's own rotation.
            guard !resolution.wasRefreshed else {
                throw ClaudeAccountUsageFetchError.unauthorized
            }
            let refreshed = try await refreshAndPersist(
                resolution,
                for: profile,
                now: now,
                accessMode: accessMode
            )
            credentialDidPersist?(refreshed)
            do {
                return UsageResolution(
                    usage: try await apiClient.fetchUsage(
                        accessToken: refreshed.accessToken
                    ),
                    credentials: refreshed
                )
            } catch ClaudeUsageAPIError.unauthorized {
                throw ClaudeAccountUsageFetchError.unauthorized
            } catch ClaudeUsageAPIError.forbidden {
                throw ClaudeAccountUsageFetchError.forbidden
            }
        } catch ClaudeUsageAPIError.forbidden {
            throw ClaudeAccountUsageFetchError.forbidden
        }
    }

    private func refreshAndPersist(
        _ resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> ClaudeOAuthCredentials {
        // Read-only workflows must fail before touching the shared lock paths;
        // automatic polling/switching must not wait behind or disturb a Claude
        // Code credential mutation merely because an access token returned 401.
        try Self.requireUsableRefreshCredential(resolution.credentials, now: now)
        guard Self.mayRotate(
            accountIsLiveElsewhere: resolution.accountIsLiveElsewhere,
            rotationIntent: resolution.rotationIntent
        ) else {
            throw Self.rotationBlockedError(
                accountIsLiveElsewhere: resolution.accountIsLiveElsewhere
            )
        }
        do {
            if let lease = ClaudeOAuthMutationLeaseContext.current {
                return try await refreshAndPersist(
                    resolution,
                    for: profile,
                    now: now,
                    accessMode: accessMode,
                    under: lease
                )
            }
            return try await refreshCoordinator.withLease { lease in
                try await refreshAndPersist(
                    resolution,
                    for: profile,
                    now: now,
                    accessMode: accessMode,
                    under: lease
                )
            }
        } catch let error as ClaudeAccountUsageFetchError {
            throw error
        } catch let error as ClaudeOAuthRefreshCoordinatorError {
            throw ClaudeAccountUsageFetchError.rotationDeferred(error)
        }
    }

    /// The cross-process lease spans the final generation re-read, exchange,
    /// and every intended persistence write. If Claude Code changed the
    /// generation while this workflow waited for the lock, that external
    /// generation wins without another token request or overwrite.
    private func refreshAndPersist(
        _ resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode,
        under lease: ClaudeOAuthRefreshLease
    ) async throws -> ClaudeOAuthCredentials {
        try lease.validate()
        let (lockedResolution, generationChanged) = try rereadCredentialGeneration(
            resolution,
            for: profile,
            accessMode: accessMode
        )
        if generationChanged {
            if lockedResolution.credentials.isExpired(asOf: now) {
                try Self.requireUsableRefreshCredential(
                    lockedResolution.credentials,
                    now: now
                )
                throw ClaudeAccountUsageFetchError.rotationDeferred(
                    ClaudeRotationDeferredError(
                        reason: "Claude credentials changed while Limit Lifeboat waited for the shared lock. Retry using the newer generation."
                    )
                )
            }
            return lockedResolution.credentials
        }

        try lease.validate()
        return try await refreshAndPersistHoldingLease(
            lockedResolution,
            for: profile,
            now: now,
            accessMode: accessMode,
            lease: lease
        )
    }

    private func rereadCredentialGeneration(
        _ resolution: CredentialResolution,
        for profile: AccountProfile,
        accessMode: CredentialAccessMode
    ) throws -> (CredentialResolution, Bool) {
        var current = resolution
        var generationChanged = false
        var liveGenerationChanged = false

        // Every allowed rotation inspects the provider-owned item under the
        // shared lease, including an inactive Retry. Profile metadata can be
        // stale; the live refresh-chain digest is the final authority on
        // whether rotating this target would strand Claude Code.
        let liveRecord: LiveClaudeOAuthCredentialRecord?
        do {
            liveRecord = try credentials.liveClaudeOAuthCredentialRecord(
                accessMode: accessMode
            )
        } catch let error as ClaudeCodeCredentialsKeychainError
            where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                error: error,
                item: resolution.liveItemLocationAtRead
            )
        } catch {
            throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
        }

        if resolution.isActiveCLI {
            guard let liveRecord else {
                throw ClaudeAccountUsageFetchError.rotationDeferred(
                    ClaudeRotationDeferredError(
                        reason: "The active Claude credential disappeared while Limit Lifeboat waited for the shared lock. Retry after Claude Code finishes."
                    )
                )
            }
            let liveFingerprint = credentialFingerprint(liveRecord.credentials)
            let liveChanged = liveFingerprint
                    != resolution.liveCredentialFingerprintAtRead
                || liveRecord.itemLocation != resolution.liveItemLocationAtRead
            if liveChanged {
                generationChanged = true
                liveGenerationChanged = true
                current.credentials = liveRecord.credentials
                current.liveAccessTokenAtRead = liveRecord.credentials.accessToken
                current.liveCredentialFingerprintAtRead = liveFingerprint
                current.liveCredentialsAtRead = liveRecord.credentials
                current.liveItemLocationAtRead = liveRecord.itemLocation
            }
        } else {
            current.liveAccessTokenAtRead = liveRecord?.credentials.accessToken
            current.liveCredentialFingerprintAtRead = liveRecord.map {
                credentialFingerprint($0.credentials)
            }
            current.liveCredentialsAtRead = liveRecord?.credentials
            current.liveItemLocationAtRead = liveRecord?.itemLocation
        }

        if let expectedRecord = resolution.preloadedStoredRecordAtRead {
            let latestRecord: StoredCredentialRecord?
            do {
                latestRecord = try credentials.storedClaudeOAuthCredentialRecord(
                    for: profile,
                    accessMode: accessMode
                )
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
            }
            guard let latestRecord,
                  let latestCredentials = latestRecord.claudeOAuthCredentials else {
                throw ClaudeAccountUsageFetchError.rotationDeferred(
                    ClaudeRotationDeferredError(
                        reason: "The saved Claude switch target disappeared while Limit Lifeboat waited for the shared lock. Reload the account before switching."
                    )
                )
            }
            let revisionMatches: Bool
            if let expectedRevision = expectedRecord.storeRevision {
                revisionMatches = latestRecord.storeRevision == expectedRevision
                    && resolution.storedCredentialFingerprintAtRead
                        == credentialFingerprint(latestCredentials)
            } else if let expectedCredentials = expectedRecord.claudeOAuthCredentials {
                revisionMatches = credentialFingerprint(latestCredentials)
                    == credentialFingerprint(expectedCredentials)
            } else {
                revisionMatches = false
            }
            guard revisionMatches else {
                throw ClaudeAccountUsageFetchError.rotationDeferred(
                    ClaudeRotationDeferredError(
                        reason: "The saved Claude switch target changed while Limit Lifeboat waited for the shared lock. Reload it before retrying the switch."
                    )
                )
            }
            current.preloadedStoredRecordAtRead = latestRecord
            current.storedAccessTokenAtRead = latestCredentials.accessToken
            current.storedCredentialFingerprintAtRead = credentialFingerprint(
                latestCredentials
            )
            current.storedCredentialsAtRead = latestCredentials
        } else {
            // Non-switch workflows re-read the app-owned copy under the lease
            // immediately before consuming the refresh chain.
            let stored: ClaudeOAuthCredentials?
            do {
                stored = try credentials.storedClaudeOAuthCredentials(
                    for: profile.id,
                    accessMode: accessMode
                )
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                throw ClaudeAccountUsageFetchError.credentialUnavailable(error)
            }

            let storedFingerprint = stored.map(credentialFingerprint)
            current.storedCredentialsAtRead = stored
            let storedChanged = storedFingerprint
                != resolution.storedCredentialFingerprintAtRead
            if storedChanged {
                generationChanged = true
                current.storedAccessTokenAtRead = stored?.accessToken
                current.storedCredentialFingerprintAtRead = storedFingerprint
                // The provider-owned live item wins when both owners changed;
                // otherwise the changed stored generation is the new owner.
                if !resolution.isActiveCLI || !liveGenerationChanged {
                    guard let stored else {
                        throw ClaudeAccountUsageFetchError.rotationDeferred(
                            ClaudeRotationDeferredError(
                                reason: "The saved Claude credential disappeared while Limit Lifeboat waited for the shared lock. Retry after account reconciliation finishes."
                            )
                        )
                    }
                    current.credentials = stored
                }
            }
        }

        if !resolution.isActiveCLI,
           let liveCredentials = liveRecord?.credentials,
           let liveChain = ClaudeRefreshChainFingerprint.make(
               credentials: liveCredentials
           ),
           liveChain == ClaudeRefreshChainFingerprint.make(
               credentials: current.credentials
           ) {
            guard resolution.rotationIntent == .userInitiatedSwitch else {
                throw ClaudeAccountUsageFetchError.accountActiveElsewhere
            }
            // A user-clicked switch may advance a shared target, but the live
            // holder becomes an intended owner of that rotation. The journal
            // and CAS transaction below keep it on the same fresh chain.
            current.liveOwnerMustBeUpdated = true
        }

        return (current, generationChanged)
    }

    private func refreshAndPersistHoldingLease(
        _ resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode,
        lease: ClaudeOAuthRefreshLease
    ) async throws -> ClaudeOAuthCredentials {
        try Self.requireUsableRefreshCredential(resolution.credentials, now: now)
        guard Self.mayRotate(
            accountIsLiveElsewhere: resolution.accountIsLiveElsewhere,
            rotationIntent: resolution.rotationIntent
        ) else {
            throw Self.rotationBlockedError(accountIsLiveElsewhere: resolution.accountIsLiveElsewhere)
        }
        if resolution.liveOwnerMustBeUpdated,
           resolution.liveAccessTokenAtRead == nil {
            // A stored access token may serve usage while the provider-owned
            // item is denied, but its refresh token must never be rotated away
            // from Claude Code unless the live item can be compare-and-swap
            // persisted in the same workflow.
            throw resolution.liveAccessWasDenied
                ? ClaudeAccountUsageFetchError.keychainLocked
                : ClaudeAccountUsageFetchError.interactiveRefreshRequired
        }

        let stale = resolution.credentials
        let staleChainFingerprint = ClaudeRefreshChainFingerprint.make(
            credentials: stale
        )
        var recoveryDestinations = resolution.additionalRecoveryDestinations
        recoveryDestinations.insert(.storedProfile(profile.id))
        if resolution.liveOwnerMustBeUpdated {
            recoveryDestinations.insert(.liveClaudeCode)
        }
        let ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ]
        do {
            ownerGenerationBaselines = try captureOwnerGenerationBaselines(
                for: recoveryDestinations,
                primaryProfileID: profile.id,
                resolution: resolution,
                accessMode: accessMode
            )
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.keychainLocked
        } catch {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude could not pin every intended credential owner before refreshing. Restore credential access, then retry without consuming the refresh chain. \(error.localizedDescription)"
                )
            )
        }

        // Persist the owner map before the irreversible request. Even if the
        // following fresh-secret update is denied, a surviving intended owner
        // can then identify and supply the new generation after relaunch. A
        // persistently unavailable journal defers here with zero token use.
        var recoveryRecord: ClaudeRotationRecoveryRecord?
        var preparedRecoveryRecordIsDurable = false
        var recoveryRecordIsDurable = false
        var recoveryCheckpointError: Error?
        if let recoveryStore,
           let staleChainFingerprint {
            let prepared = ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: staleChainFingerprint,
                freshChainFingerprint: nil,
                oauthJSON: stale.rawClaudeAiOauth,
                pendingDestinations: recoveryDestinations,
                ownerGenerationBaselines: ownerGenerationBaselines,
                phase: .prepared
            )
            do {
                try recoveryStore.save(prepared, accessMode: accessMode)
                recoveryRecord = prepared
                preparedRecoveryRecordIsDurable = true
            } catch {
                throw ClaudeAccountUsageFetchError.rotationDeferred(
                    ClaudeRotationDeferredError(
                        reason: "Claude credential recovery could not prepare its encrypted owner map. Restore Keychain access, then retry; the refresh token was not used."
                    )
                )
            }
        }

        // Owner discovery and the prepared checkpoint can involve several
        // Keychain operations. Revalidate immediately before the irreversible
        // request so a replaced/lost lock never authorizes the exchange.
        do {
            try Task.checkCancellation()
            try lease.validate()
        } catch let leaseError {
            if preparedRecoveryRecordIsDurable,
               let recoveryStore,
               let recordID = recoveryRecord?.id {
                do {
                    _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                    try recoveryStore.delete(id: recordID, accessMode: accessMode)
                    preparedRecoveryRecordIsDurable = false
                    recoveryRecord = nil
                } catch let error as ClaudeOAuthRefreshCoordinatorError {
                    // A replacement lock holder may already be inspecting or
                    // advancing this record. Leave the conservative prepared
                    // checkpoint intact; a stale process must never delete it.
                    throw ClaudeAccountUsageFetchError.rotationDeferred(error)
                } catch {
                    // The request has not started, so the refresh chain is
                    // untouched. Retaining the prepared record is recoverable:
                    // a later explicit action can clear/re-resolve it.
                    throw ClaudeAccountUsageFetchError.rotationDeferred(
                        ClaudeRotationDeferredError(
                            reason: "Claude's credential operation stopped before token exchange, and its prepared recovery record could not be cleared yet. Restore Keychain access, then retry; the refresh token was not used."
                        )
                    )
                }
            }
            throw leaseError
        }
        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await refresher.refresh(stale, now: now)
        } catch let refreshError {
            if preparedRecoveryRecordIsDurable,
               let recoveryStore,
               let recordID = recoveryRecord?.id {
                do {
                    // No usable token response exists, so this transaction did
                    // not produce a replayable fresh generation. Remove its
                    // prepared map under the same lease before allowing retry.
                    _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                    try recoveryStore.delete(id: recordID, accessMode: accessMode)
                    preparedRecoveryRecordIsDurable = false
                    recoveryRecord = nil
                } catch let cleanupError {
                    if let oauthError = refreshError as? ClaudeOAuthError,
                       oauthError.requiresLogin {
                        // An exact terminal OAuth response remains terminal;
                        // the stale prepared record is reconciled when a new
                        // login supersedes this generation.
                        throw ClaudeAccountUsageFetchError.refreshFailed(
                            refreshError
                        )
                    }
                    // A network or malformed-response failure does not prove
                    // the chain was consumed. Keep the durable prepared record
                    // as the recovery checkpoint; the next explicit action
                    // re-resolves or probes it without declaring login lost.
                    throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                        ClaudeCredentialRepairRequiredError(
                            reason: "Claude's token exchange did not yield a usable credential, and its prepared recovery record could not be cleared yet. Restore credential access, then Retry to reconcile the refresh chain. \(cleanupError.localizedDescription)"
                        )
                    )
                }
            }
            throw ClaudeAccountUsageFetchError.refreshFailed(refreshError)
        }

        if let recoveryStore,
           let staleChainFingerprint {
            let record = ClaudeRotationRecoveryRecord(
                id: recoveryRecord?.id ?? UUID(),
                createdAt: recoveryRecord?.createdAt ?? now,
                staleChainFingerprint: staleChainFingerprint,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: refreshed
                ),
                oauthJSON: refreshed.rawClaudeAiOauth,
                pendingDestinations: recoveryDestinations,
                ownerGenerationBaselines: ownerGenerationBaselines,
                phase: .freshGeneration
            )
            recoveryRecord = record
            var checkpointError: Error?
            for _ in 0..<3 where !recoveryRecordIsDurable {
                do {
                    // The token response is already irreversible. This
                    // encrypted checkpoint is deliberately attempted even if
                    // the cross-process lease was lost while the request was
                    // in flight; owner mutations still require a valid lease.
                    try recoveryStore.save(record, accessMode: accessMode)
                    recoveryRecordIsDurable = true
                } catch {
                    checkpointError = error
                }
            }
            if !recoveryRecordIsDurable {
                if try everyRecoveryDestinationAdvancedExternally(
                    recoveryDestinations,
                    ownerGenerationBaselines: ownerGenerationBaselines,
                    accessMode: accessMode
                ) {
                    // Every intended owner moved off its pinned generation
                    // while the request was in flight. Those external logins
                    // supersede the uncheckpointed response, so discarding the
                    // latter cannot strand a stale local owner.
                    if preparedRecoveryRecordIsDurable,
                       let recordID = recoveryRecord?.id {
                        do {
                            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
                            try recoveryStore.delete(
                                id: recordID,
                                accessMode: accessMode
                            )
                        } catch {
                            // Keep the conservative prepared record. The next
                            // explicit action adopts/clears it; never delete it
                            // after losing the lease.
                        }
                    }
                    throw ClaudeAccountUsageFetchError.rotationDeferred(
                        ClaudeRotationDeferredError(
                            reason: "Claude credentials changed to newer external generations during refresh. Those generations were preserved and will be adopted on the next read."
                        )
                    )
                }
                // Without this proof, a later process cannot distinguish an
                // app-issued owner write from an unrelated external login.
                // Do not create that ambiguity: no normal owner is mutated.
                throw ClaudeAccountUsageFetchError.credentialRecoveryFailed(
                    ClaudeCredentialPersistenceFailedError(
                        reason: "Claude issued a fresh credential, but its encrypted recovery checkpoint could not be preserved. No local owner was overwritten; sign in again before retrying. \(checkpointError?.localizedDescription ?? "Credential journal unavailable.")"
                    )
                )
            }
        }

        // For an active explicit Retry, protect the provider-owned live login
        // first. Both writes are compare-and-swap operations; an account or
        // credential change during the network request always wins (the live
        // item is not ours to overwrite blindly).
        var livePersisted = !resolution.liveOwnerMustBeUpdated
        var storedPersisted = false
        var storedWriteError: Error?
        var liveWriteError: Error?
        var liveWriteConflict = false
        var liveSuperseded = false
        var storedSuperseded = false
        var primaryStoredCredentials = refreshed
        if resolution.liveOwnerMustBeUpdated,
           resolution.rotationIntent.allowsCredentialRotation,
           let expectedLiveCredentials = resolution.liveCredentialsAtRead {
            try validateLeaseAfterExchange(
                lease,
                freshGenerationIsDurable: recoveryRecordIsDurable
            )
            do {
                let liveCredentials = resolution.liveCredentialsAtRead?
                    .mergingRotatedTokenFields(from: refreshed) ?? refreshed
                livePersisted = try credentials.replaceLiveClaudeOAuthCredentials(
                    liveCredentials,
                    at: resolution.liveItemLocationAtRead,
                    ifCurrentCredentialsMatch: expectedLiveCredentials,
                    accessMode: accessMode
                )
                if !livePersisted {
                    switch try postExchangeLiveOwnerDisposition(
                        expectedItemLocation: resolution.liveItemLocationAtRead,
                        staleChainFingerprint: staleChainFingerprint,
                        refreshed: refreshed,
                        ownerGenerationBaselines: ownerGenerationBaselines,
                        accessMode: accessMode
                    ) {
                    case .fresh:
                        livePersisted = true
                    case .superseding:
                        liveSuperseded = true
                    case .pending:
                        liveWriteConflict = true
                    }
                }
                if livePersisted || liveSuperseded {
                    removeRecoveryDestination(
                        .liveClaudeCode,
                        recoveryRecord: &recoveryRecord
                    )
                    if let error = checkpointPostExchangeRecoveryRecord(
                        recoveryRecord,
                        isDurable: &recoveryRecordIsDurable,
                        accessMode: accessMode
                    ), recoveryCheckpointError == nil {
                        recoveryCheckpointError = error
                    }
                }
            } catch {
                liveWriteError = error
                AppLog.credentials.error("Could not write the refreshed token back to the live Claude Code item for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // The stored snapshot is ours, and the server has already consumed the
        // old refresh token — the rotated generation is now the only valid one.
        // A dropped write here means a guaranteed invalid_grant next cycle, so
        // Both intended owners gate success. A failed save leaves a repair
        // entry containing the fresh generation, so an explicit action can
        // finish persistence without issuing another token request.
        try validateLeaseAfterExchange(
            lease,
            freshGenerationIsDurable: recoveryRecordIsDurable
                || (resolution.liveOwnerMustBeUpdated
                    && (livePersisted || liveSuperseded))
        )
        do {
            if let storedOwner = resolution.storedCredentialsAtRead {
                guard let merged = storedOwner.mergingRotatedTokenFields(
                    from: refreshed
                ) else {
                    throw ClaudeCredentialRepairRequiredError(
                        reason: "The saved Claude profile could not merge the fresh token generation."
                    )
                }
                primaryStoredCredentials = merged
            }
            if let expectedStoredCredentials = resolution.storedCredentialsAtRead {
                if let storedRecord = resolution.preloadedStoredRecordAtRead {
                    storedPersisted = try credentials.replaceStoredClaudeOAuthCredentials(
                        primaryStoredCredentials,
                        for: profile.id,
                        using: storedRecord,
                        ifCurrentCredentialsMatch: expectedStoredCredentials,
                        accessMode: accessMode
                    ) != nil
                } else {
                    storedPersisted = try credentials.replaceStoredClaudeOAuthCredentials(
                        primaryStoredCredentials,
                        for: profile.id,
                        ifCurrentCredentialsMatch: expectedStoredCredentials,
                        accessMode: accessMode
                    )
                }
                if !storedPersisted {
                    switch try postExchangeStoredOwnerDisposition(
                        for: profile.id,
                        staleChainFingerprint: staleChainFingerprint,
                        refreshed: refreshed,
                        ownerGenerationBaselines: ownerGenerationBaselines,
                        accessMode: accessMode
                    ) {
                    case .fresh(let current):
                        storedPersisted = true
                        primaryStoredCredentials = current
                    case .superseding(let current):
                        storedSuperseded = true
                        primaryStoredCredentials = current
                    case .pending:
                        break
                    }
                }
            } else {
                // An app-owned OAuth owner can appear while the token request
                // is in flight. Adopt it rather than using a blind update to
                // overwrite a concurrent login generation.
                if let current = try credentials.storedClaudeOAuthCredentials(
                    for: profile.id,
                    accessMode: accessMode
                ) {
                    switch postExchangeOwnerDisposition(
                        current,
                        staleChainFingerprint: staleChainFingerprint,
                        refreshed: refreshed,
                        ownerGenerationBaselines: ownerGenerationBaselines,
                        destination: .storedProfile(profile.id)
                    ) {
                    case .fresh(let current):
                        storedPersisted = true
                        primaryStoredCredentials = current
                    case .superseding(let current):
                        storedSuperseded = true
                        primaryStoredCredentials = current
                    case .pending:
                        break
                    }
                } else {
                    try credentials.updateStoredClaudeOAuthCredentials(
                        primaryStoredCredentials,
                        for: profile.id,
                        accessMode: accessMode
                    )
                    storedPersisted = true
                }
            }
        } catch {
            storedWriteError = error
            AppLog.credentials.error("Could not persist the refreshed token for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if storedPersisted || storedSuperseded {
            removeRecoveryDestination(
                .storedProfile(profile.id),
                recoveryRecord: &recoveryRecord
            )
            if let error = checkpointPostExchangeRecoveryRecord(
                recoveryRecord,
                isDurable: &recoveryRecordIsDurable,
                accessMode: accessMode
            ), recoveryCheckpointError == nil {
                recoveryCheckpointError = error
            }
        }

        let additionalRecovery = reconcileAdditionalRecoveryDestinations(
            resolution.additionalRecoveryDestinations,
            excludingStoredProfileID: profile.id,
            liveWasHandledLocally: resolution.liveOwnerMustBeUpdated,
            staleChainFingerprint: staleChainFingerprint,
            refreshed: refreshed,
            ownerGenerationBaselines: ownerGenerationBaselines,
            resolution: resolution,
            accessMode: accessMode,
            lease: lease,
            recoveryRecord: &recoveryRecord,
            recoveryRecordIsDurable: &recoveryRecordIsDurable
        )

        let durableFreshOwnerExists = storedPersisted
            || (resolution.liveOwnerMustBeUpdated && livePersisted)
            || additionalRecovery.freshOwnerExists
        let durableSupersedingOwnerExists = storedSuperseded
            || (resolution.liveOwnerMustBeUpdated && liveSuperseded)
            || additionalRecovery.supersedingOwnerExists
        let hasPendingOwners = !additionalRecovery.pendingDestinations.isEmpty
            || (!storedPersisted && !storedSuperseded)
            || (resolution.liveOwnerMustBeUpdated
                && !livePersisted
                && !liveSuperseded)

        // A failed initial checkpoint gets another opportunity as soon as any
        // owner makes the transaction recoverable. Save the current, reduced
        // pending set before returning a repair outcome so a relaunch never
        // needs to consume the refresh chain again.
        if hasPendingOwners,
           durableFreshOwnerExists || durableSupersedingOwnerExists,
           let error = checkpointPostExchangeRecoveryRecord(
                recoveryRecord,
                isDurable: &recoveryRecordIsDurable,
                accessMode: accessMode
           ), recoveryCheckpointError == nil {
            recoveryCheckpointError = error
        }

        // When every owner committed but the fresh-secret journal update kept
        // failing, remove the still-prepared owner map. A failed deletion is
        // harmless and conservative: the next launch reconstructs the common
        // durable generation and observes every destination as complete.
        if !hasPendingOwners,
           preparedRecoveryRecordIsDurable,
           let recoveryStore,
           let recordID = recoveryRecord?.id {
            do {
                // A stale process must not delete or rewrite journal state
                // after another process acquired a replacement lease.
                try lease.validate()
                try recoveryStore.delete(id: recordID, accessMode: accessMode)
                preparedRecoveryRecordIsDurable = false
                recoveryRecordIsDurable = false
            } catch {
                if recoveryCheckpointError == nil {
                    recoveryCheckpointError = error
                }
            }
        }

        guard recoveryRecordIsDurable
                || durableFreshOwnerExists
                || durableSupersedingOwnerExists else {
            let checkpointDetail = recoveryCheckpointError == nil
                ? "No encrypted recovery checkpoint was available."
                : "The encrypted recovery checkpoint could not be saved."
            throw ClaudeAccountUsageFetchError.credentialRecoveryFailed(
                ClaudeCredentialPersistenceFailedError(
                    reason: "Claude issued a fresh login generation, but no durable credential owner retained it. \(checkpointDetail) Sign in again to establish a new refresh chain."
                )
            )
        }


        if !additionalRecovery.pendingDestinations.isEmpty {
            let detail = additionalRecovery.error?.localizedDescription
                ?? "One or more shared Claude credential owners changed before they could be updated."
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude retained the fresh login generation, but shared saved profiles still need repair. \(detail) Retry to reconcile them without another token exchange."
                )
            )
        }

        if liveWriteError != nil || liveWriteConflict {
            // A false CAS means the live account changed during the request;
            // saving this profile's rotation is still safe. A thrown write,
            // however, leaves Claude Code on the known-stale generation. Keep
            // any stored recovery copy, but never issue a usage request or
            // report the active rotation as successful.
            let reason = "Claude refreshed this login, but the active Claude Code Keychain item still needs repair. Authorize access, then retry."
            if storedPersisted,
               let staleLiveAccessToken = resolution.liveAccessTokenAtRead {
                liveRepairs.record(
                    recoveryFingerprint: rotatedCredentialFingerprint(refreshed),
                    staleLiveAccessTokenFingerprint: accessTokenFingerprint(
                        staleLiveAccessToken
                    ),
                    staleLiveItemFingerprint: itemLocationFingerprint(
                        resolution.liveItemLocationAtRead
                    ),
                    for: profile.id
                )
            }
            if let keychainError = liveWriteError as? ClaudeCodeCredentialsKeychainError,
               keychainError.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                    error: keychainError,
                    item: resolution.liveItemLocationAtRead
                )
            }
            if let liveWriteError {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "\(reason) \(liveWriteError.localizedDescription)"
                    )
                )
            }
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(reason: reason)
            )
        }

        guard storedPersisted || storedSuperseded else {
            let reason = "Claude refreshed this login, but its saved account copy still needs repair. Retry to finish saving it without rotating again."
            storedRepairs.record(
                credentials: primaryStoredCredentials,
                staleStoredAccessTokenFingerprint: resolution.storedAccessTokenAtRead.map(
                    accessTokenFingerprint
                ),
                requiresFreshLiveCredential: resolution.liveOwnerMustBeUpdated
                    && livePersisted,
                for: profile.id,
            )
            if let storedWriteError {
                AppLog.credentials.error("Stored Claude credential repair is pending for account \(profile.id, privacy: .public): \(storedWriteError.localizedDescription, privacy: .public)")
            }
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(reason: reason)
            )
        }

        guard livePersisted || liveSuperseded else {
            throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                ClaudeCredentialRepairRequiredError(
                    reason: "Claude refreshed this login, but the active Claude Code credential still needs repair. Retry after reconciling the active login."
                )
            )
        }

        if liveSuperseded || storedSuperseded {
            throw ClaudeAccountUsageFetchError.rotationDeferred(
                ClaudeRotationDeferredError(
                    reason: "A newer Claude credential generation appeared while the refresh was being committed. It was preserved and adopted; retry using the current generation."
                )
            )
        }

        storedRepairs.clear(for: profile.id)
        if resolution.liveOwnerMustBeUpdated {
            liveRepairs.clear(for: profile.id)
        }
        return primaryStoredCredentials
    }

    private enum PostExchangeOwnerDisposition {
        case fresh(ClaudeOAuthCredentials)
        case superseding(ClaudeOAuthCredentials)
        case pending
    }

    /// Captures exact owner generations immediately before the irreversible
    /// exchange while the shared lease is held. An absent dictionary entry in
    /// this non-optional map means that owner did not exist at the baseline.
    private func captureOwnerGenerationBaselines(
        for destinations: Set<ClaudeRotationRecoveryDestination>,
        primaryProfileID: UUID,
        resolution: CredentialResolution,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeRotationRecoveryDestination: String] {
        var baselines: [ClaudeRotationRecoveryDestination: String] = [:]
        for destination in destinations {
            let owner: ClaudeOAuthCredentials?
            switch destination {
            case .liveClaudeCode:
                owner = resolution.liveCredentialsAtRead
            case .storedProfile(let ownerID) where ownerID == primaryProfileID:
                owner = resolution.storedCredentialsAtRead
            case .storedProfile(let ownerID):
                owner = try credentials.storedClaudeOAuthCredentials(
                    for: ownerID,
                    accessMode: accessMode
                )
            }
            if let owner {
                baselines[destination] = rotatedCredentialFingerprint(owner)
            }
        }
        return baselines
    }

    /// Used only when the mandatory fresh checkpoint failed. No owner write
    /// has happened yet, so an exact change at every intended destination is
    /// proof of external/superseding state. If even one owner remains pinned,
    /// losing the in-memory response would strand that owner and is terminal.
    private func everyRecoveryDestinationAdvancedExternally(
        _ destinations: Set<ClaudeRotationRecoveryDestination>,
        ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ],
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        guard !destinations.isEmpty else { return false }
        for destination in destinations {
            let current: ClaudeOAuthCredentials?
            switch destination {
            case .liveClaudeCode:
                current = try credentials.liveClaudeOAuthCredentialRecord(
                    accessMode: accessMode
                )?.credentials
            case .storedProfile(let profileID):
                current = try credentials.storedClaudeOAuthCredentials(
                    for: profileID,
                    accessMode: accessMode
                )
            }
            guard let current else { return false }
            if let baseline = ownerGenerationBaselines[destination] {
                guard rotatedCredentialFingerprint(current) != baseline else {
                    return false
                }
            }
            // Missing baseline means this owner was absent before exchange;
            // its presence now is itself an external generation change.
        }
        return true
    }

    private func postExchangeOwnerDisposition(
        _ current: ClaudeOAuthCredentials,
        staleChainFingerprint: String?,
        refreshed: ClaudeOAuthCredentials,
        ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ]?,
        destination: ClaudeRotationRecoveryDestination
    ) -> PostExchangeOwnerDisposition {
        if rotatedCredentialFingerprint(current)
            == rotatedCredentialFingerprint(refreshed) {
            return .fresh(current)
        }
        if let staleChainFingerprint,
           let currentChain = ClaudeRefreshChainFingerprint.make(
                credentials: current
           ),
           currentChain != staleChainFingerprint {
            // A different refresh chain is a newer login/rotation. It wins;
            // the just-issued in-memory generation must never overwrite it.
            return .superseding(current)
        }

        if let ownerGenerationBaselines {
            // Replay is safe only over the exact generation captured before
            // the exchange. A missing baseline means the owner appeared
            // concurrently; a mismatch means it advanced, even when Claude
            // omitted refresh_token and the refresh-chain digest is unchanged.
            guard let expected = ownerGenerationBaselines[destination],
                  rotatedCredentialFingerprint(current) == expected else {
                return .superseding(current)
            }
            return .pending
        }

        // Legacy journals did not pin per-owner generations. A rotated refresh
        // token makes the stale chain unambiguously replayable. If Claude kept
        // the same refresh token, fail closed: a different access token may be
        // a newer generation created after the crash.
        if ClaudeRefreshChainFingerprint.make(credentials: refreshed)
            != staleChainFingerprint {
            return .pending
        }
        return .superseding(current)
    }

    private func postExchangeLiveOwnerDisposition(
        expectedItemLocation: ClaudeKeychainItemLocation?,
        staleChainFingerprint: String?,
        refreshed: ClaudeOAuthCredentials,
        ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ]?,
        accessMode: CredentialAccessMode
    ) throws -> PostExchangeOwnerDisposition {
        guard let current = try credentials.liveClaudeOAuthCredentialRecord(
            accessMode: accessMode
        ) else {
            return .pending
        }
        if current.itemLocation != expectedItemLocation {
            return .superseding(current.credentials)
        }
        return postExchangeOwnerDisposition(
            current.credentials,
            staleChainFingerprint: staleChainFingerprint,
            refreshed: refreshed,
            ownerGenerationBaselines: ownerGenerationBaselines,
            destination: .liveClaudeCode
        )
    }

    private func postExchangeStoredOwnerDisposition(
        for profileID: UUID,
        staleChainFingerprint: String?,
        refreshed: ClaudeOAuthCredentials,
        ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ]?,
        accessMode: CredentialAccessMode
    ) throws -> PostExchangeOwnerDisposition {
        guard let current = try credentials.storedClaudeOAuthCredentials(
            for: profileID,
            accessMode: accessMode
        ) else {
            return .pending
        }
        return postExchangeOwnerDisposition(
            current,
            staleChainFingerprint: staleChainFingerprint,
            refreshed: refreshed,
            ownerGenerationBaselines: ownerGenerationBaselines,
            destination: .storedProfile(profileID)
        )
    }

    private func removeRecoveryDestination(
        _ destination: ClaudeRotationRecoveryDestination,
        recoveryRecord: inout ClaudeRotationRecoveryRecord?
    ) {
        recoveryRecord?.pendingDestinations.remove(destination)
    }

    /// Reduces the app-owned encrypted journal after an owner commit. The
    /// initial full fresh-secret checkpoint is allowed immediately after the
    /// irreversible response, but later pending-set reductions require the
    /// original lease: a stale process must never resurrect a destination that
    /// a new lease holder already reconciled or removed. When an update fails,
    /// `isDurable` stays true because the earlier conservative record has a
    /// superset of pending destinations.
    private func checkpointPostExchangeRecoveryRecord(
        _ record: ClaudeRotationRecoveryRecord?,
        isDurable: inout Bool,
        accessMode: CredentialAccessMode
    ) -> Error? {
        guard let recoveryStore, let record else { return nil }
        do {
            _ = try ClaudeOAuthMutationLeaseContext.requireCurrent()
            if record.pendingDestinations.isEmpty {
                if isDurable {
                    try recoveryStore.delete(id: record.id, accessMode: accessMode)
                    isDurable = false
                }
            } else {
                try recoveryStore.save(record, accessMode: accessMode)
                isDurable = true
            }
            return nil
        } catch {
            return error
        }
    }

    private struct AdditionalRecoveryResult {
        var freshOwnerExists = false
        var supersedingOwnerExists = false
        var pendingDestinations: Set<ClaudeRotationRecoveryDestination> = []
        var error: Error?
    }

    /// Completes sibling/live propagation inside the same uninterrupted lease
    /// as the token exchange. Each destination keeps its own unknown OAuth
    /// fields; only the remotely rotated token fields are merged.
    private func reconcileAdditionalRecoveryDestinations(
        _ requestedDestinations: Set<ClaudeRotationRecoveryDestination>,
        excludingStoredProfileID profileID: UUID,
        liveWasHandledLocally: Bool,
        staleChainFingerprint: String?,
        refreshed: ClaudeOAuthCredentials,
        ownerGenerationBaselines: [
            ClaudeRotationRecoveryDestination: String
        ],
        resolution: CredentialResolution,
        accessMode: CredentialAccessMode,
        lease: ClaudeOAuthRefreshLease,
        recoveryRecord: inout ClaudeRotationRecoveryRecord?,
        recoveryRecordIsDurable: inout Bool
    ) -> AdditionalRecoveryResult {
        var destinations = requestedDestinations
        destinations.remove(.storedProfile(profileID))
        if liveWasHandledLocally {
            destinations.remove(.liveClaudeCode)
        }
        let ordered = destinations.sorted { lhs, rhs in
            recoveryDestinationSortKey(lhs) < recoveryDestinationSortKey(rhs)
        }
        var result = AdditionalRecoveryResult()

        for destination in ordered {
            do {
                try validateLeaseAfterExchange(
                    lease,
                    freshGenerationIsDurable: recoveryRecordIsDurable
                        || result.freshOwnerExists
                        || result.supersedingOwnerExists
                )
                var destinationCompleted = false
                switch destination {
                case .liveClaudeCode:
                    guard let owner = resolution.liveCredentialsAtRead else {
                        result.pendingDestinations.insert(destination)
                        continue
                    }
                    switch postExchangeOwnerDisposition(
                        owner,
                        staleChainFingerprint: staleChainFingerprint,
                        refreshed: refreshed,
                        ownerGenerationBaselines: ownerGenerationBaselines,
                        destination: destination
                    ) {
                    case .fresh:
                        result.freshOwnerExists = true
                        destinationCompleted = true
                    case .superseding:
                        result.supersedingOwnerExists = true
                        destinationCompleted = true
                    case .pending:
                        guard let merged = owner.mergingRotatedTokenFields(
                            from: refreshed
                        ) else {
                            throw ClaudeCredentialRepairRequiredError(
                                reason: "The live Claude owner could not merge the fresh token generation."
                            )
                        }
                        if try credentials.replaceLiveClaudeOAuthCredentials(
                            merged,
                            at: resolution.liveItemLocationAtRead,
                            ifCurrentCredentialsMatch: owner,
                            accessMode: accessMode
                        ) {
                            result.freshOwnerExists = true
                            destinationCompleted = true
                        } else {
                            switch try postExchangeLiveOwnerDisposition(
                                expectedItemLocation: resolution.liveItemLocationAtRead,
                                staleChainFingerprint: staleChainFingerprint,
                                refreshed: refreshed,
                                ownerGenerationBaselines: ownerGenerationBaselines,
                                accessMode: accessMode
                            ) {
                            case .fresh:
                                result.freshOwnerExists = true
                                destinationCompleted = true
                            case .superseding:
                                result.supersedingOwnerExists = true
                                destinationCompleted = true
                            case .pending:
                                break
                            }
                        }
                    }

                case .storedProfile(let siblingID):
                    guard let owner = try credentials.storedClaudeOAuthCredentials(
                        for: siblingID,
                        accessMode: accessMode
                    ) else {
                        result.pendingDestinations.insert(destination)
                        continue
                    }
                    switch postExchangeOwnerDisposition(
                        owner,
                        staleChainFingerprint: staleChainFingerprint,
                        refreshed: refreshed,
                        ownerGenerationBaselines: ownerGenerationBaselines,
                        destination: destination
                    ) {
                    case .fresh:
                        result.freshOwnerExists = true
                        destinationCompleted = true
                    case .superseding:
                        result.supersedingOwnerExists = true
                        destinationCompleted = true
                    case .pending:
                        guard let merged = owner.mergingRotatedTokenFields(
                            from: refreshed
                        ) else {
                            throw ClaudeCredentialRepairRequiredError(
                                reason: "A saved Claude sibling could not merge the fresh token generation."
                            )
                        }
                        if try credentials.replaceStoredClaudeOAuthCredentials(
                            merged,
                            for: siblingID,
                            ifCurrentCredentialsMatch: owner,
                            accessMode: accessMode
                        ) {
                            result.freshOwnerExists = true
                            destinationCompleted = true
                        } else {
                            switch try postExchangeStoredOwnerDisposition(
                                for: siblingID,
                                staleChainFingerprint: staleChainFingerprint,
                                refreshed: refreshed,
                                ownerGenerationBaselines: ownerGenerationBaselines,
                                accessMode: accessMode
                            ) {
                            case .fresh:
                                result.freshOwnerExists = true
                                destinationCompleted = true
                            case .superseding:
                                result.supersedingOwnerExists = true
                                destinationCompleted = true
                            case .pending:
                                break
                            }
                        }
                    }
                }

                if destinationCompleted {
                    removeRecoveryDestination(
                        destination,
                        recoveryRecord: &recoveryRecord
                    )
                    if let error = checkpointPostExchangeRecoveryRecord(
                        recoveryRecord,
                        isDurable: &recoveryRecordIsDurable,
                        accessMode: accessMode
                    ), result.error == nil {
                        result.error = error
                    }
                } else {
                    result.pendingDestinations.insert(destination)
                }
            } catch {
                result.pendingDestinations.insert(destination)
                if result.error == nil {
                    result.error = error
                }
            }
        }
        return result
    }

    private func recoveryDestinationSortKey(
        _ destination: ClaudeRotationRecoveryDestination
    ) -> String {
        switch destination {
        case .liveClaudeCode:
            return "0-live"
        case .storedProfile(let id):
            return "1-\(id.uuidString)"
        }
    }

    private func validateLeaseAfterExchange(
        _ lease: ClaudeOAuthRefreshLease,
        freshGenerationIsDurable: Bool
    ) throws {
        do {
            try lease.validate()
        } catch {
            if freshGenerationIsDurable {
                throw ClaudeAccountUsageFetchError.credentialRepairRequired(
                    ClaudeCredentialRepairRequiredError(
                        reason: "Claude issued a fresh login generation, but the shared credential lease was lost before every owner was updated. Retry to repair the durable fresh copy without another exchange."
                    )
                )
            }
            throw ClaudeAccountUsageFetchError.credentialRecoveryFailed(
                ClaudeCredentialPersistenceFailedError(
                    reason: "Claude issued a fresh login generation, but the shared credential lease was lost before it could be saved anywhere. Sign in again to establish a new refresh chain."
                )
            )
        }
    }

    private func credentialFingerprint(_ credentials: ClaudeOAuthCredentials) -> String {
        SHA256.hash(data: credentials.rawClaudeAiOauth)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Recovery must treat an unknown access expiry as usable rather than as
    /// older than an already-expired timestamp. Successful token responses may
    /// omit `expires_in`, in which case refresh deliberately clears `expiresAt`.
    private func credentialIsFresher(
        _ candidate: ClaudeOAuthCredentials,
        than other: ClaudeOAuthCredentials,
        asOf now: Date
    ) -> Bool {
        candidate.isFresher(than: other, asOf: now)
    }

    /// Identity of only the fields advanced by an OAuth rotation. Owner-local
    /// organization/configuration/unknown fields deliberately do not
    /// participate, allowing journal repair to merge rather than replace each
    /// holder's whole OAuth object.
    private func rotatedCredentialFingerprint(
        _ credentials: ClaudeOAuthCredentials
    ) -> String {
        ClaudeOAuthGenerationFingerprint.make(credentials)
    }

    private func accessTokenFingerprint(_ accessToken: String) -> String {
        SHA256.hash(data: Data(accessToken.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func itemLocationFingerprint(
        _ location: ClaudeKeychainItemLocation?
    ) -> String? {
        guard let location else { return nil }
        var data = Data(location.persistentReference)
        data.append(Data(location.keychainPath.utf8))
        data.append(Data(location.serviceName.utf8))
        data.append(Data(location.accountName.utf8))
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class ClaudeLiveRepairRegistry: @unchecked Sendable {
    struct Entry {
        var recoveryFingerprint: String
        var staleLiveAccessTokenFingerprint: String
        var staleLiveItemFingerprint: String?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func entry(for profileID: UUID) -> Entry? {
        lock.withLock { entries[profileID] }
    }

    var hasEntries: Bool {
        lock.withLock { !entries.isEmpty }
    }

    func record(
        recoveryFingerprint: String,
        staleLiveAccessTokenFingerprint: String,
        staleLiveItemFingerprint: String?,
        for profileID: UUID
    ) {
        lock.withLock {
            entries[profileID] = Entry(
                recoveryFingerprint: recoveryFingerprint,
                staleLiveAccessTokenFingerprint: staleLiveAccessTokenFingerprint,
                staleLiveItemFingerprint: staleLiveItemFingerprint
            )
        }
    }

    func clear(for profileID: UUID) {
        _ = lock.withLock { entries.removeValue(forKey: profileID) }
    }
}

/// Holds a newly issued generation only while its app-owned snapshot is
/// incomplete. This is intentionally service-local; the durable recovery
/// journal owns crash recovery, while this registry prevents a second token
/// exchange during the current process lifetime.
private final class ClaudeStoredRepairRegistry: @unchecked Sendable {
    struct Entry {
        var credentials: ClaudeOAuthCredentials
        var staleStoredAccessTokenFingerprint: String?
        var requiresFreshLiveCredential: Bool
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func entry(for profileID: UUID) -> Entry? {
        lock.withLock { entries[profileID] }
    }

    var hasEntries: Bool {
        lock.withLock { !entries.isEmpty }
    }

    func record(
        credentials: ClaudeOAuthCredentials,
        staleStoredAccessTokenFingerprint: String?,
        requiresFreshLiveCredential: Bool,
        for profileID: UUID
    ) {
        lock.withLock {
            entries[profileID] = Entry(
                credentials: credentials,
                staleStoredAccessTokenFingerprint: staleStoredAccessTokenFingerprint,
                requiresFreshLiveCredential: requiresFreshLiveCredential
            )
        }
    }

    func clear(for profileID: UUID) {
        _ = lock.withLock {
            entries.removeValue(forKey: profileID)
        }
    }
}
