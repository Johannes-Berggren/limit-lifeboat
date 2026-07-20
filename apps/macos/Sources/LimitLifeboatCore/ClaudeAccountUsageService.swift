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
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> Bool
    func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeOAuthCredentials?
    func updateStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws
    @discardableResult
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> Bool
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord?
}

public extension ClaudeOAuthCredentialProviding {
    /// Compatibility path for lightweight providers. CLISwitcher overrides
    /// this requirement with its revisioned, read-free credential-store CAS.
    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        guard try replaceStoredClaudeOAuthCredentials(
            credentials,
            for: profileID,
            ifAccessTokenMatches: expectedAccessToken,
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
                claudeRefreshTokenExpiresAt: credentials.refreshTokenExpiresAt
            ),
            storeRevision: storedRecord.storeRevision
        )
    }
}

extension CLISwitcher: ClaudeOAuthCredentialProviding {}

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
    /// Duplicate, malformed, ambiguous, or otherwise unsafe provider-owned
    /// credential state. This is deliberately not an authorization failure and
    /// must never trigger a CLI fallback.
    case credentialUnavailable(Error)
    case refreshFailed(Error)
    case unauthorized
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
        case .credentialUnavailable(let underlying):
            return "The shared Claude credential could not be used safely (\(underlying.localizedDescription))."
        case .refreshFailed(let underlying):
            return "Could not refresh the access token (\(underlying.localizedDescription))."
        case .unauthorized:
            return "The Anthropic usage API rejected the account's tokens."
        case .transport(let underlying):
            return underlying.localizedDescription
        }
    }
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
    private let terminalRefreshes: ClaudeTerminalRefreshRegistry
    private let liveRepairs: ClaudeLiveRepairRegistry

    public init(
        apiClient: ClaudeUsageAPIClient = ClaudeUsageAPIClient(),
        refresher: ClaudeOAuthTokenRefresher = ClaudeOAuthTokenRefresher(),
        credentials: ClaudeOAuthCredentialProviding
    ) {
        self.apiClient = apiClient
        self.refresher = refresher
        self.credentials = credentials
        self.terminalRefreshes = ClaudeTerminalRefreshRegistry()
        self.liveRepairs = ClaudeLiveRepairRegistry()
    }

    public func fetchSnapshot(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        userExplicitlyRequestedRefresh: Bool = false,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy = .read,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)? = nil,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)? = nil
    ) async throws -> UsageSnapshot {
        try await fetchSnapshotResult(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode,
            userExplicitlyRequestedRefresh: userExplicitlyRequestedRefresh,
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
        userExplicitlyRequestedRefresh: Bool = false,
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
                now: now,
                accessMode: accessMode,
                userExplicitlyRequestedRefresh: userExplicitlyRequestedRefresh,
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
        now: Date,
        accessMode: CredentialAccessMode,
        userExplicitlyRequestedRefresh: Bool,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?,
        storedCredentialSource: StoredCredentialSource,
        credentialDidPersist: ((ClaudeOAuthCredentials) -> Void)?,
        credentialDidResolve: ((ClaudeOAuthCredentials) -> Void)?
    ) async throws -> ClaudeAccountUsageFetchResult {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode,
            userExplicitlyRequestedRefresh: userExplicitlyRequestedRefresh,
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
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode,
        userExplicitlyRequestedRefresh: Bool = false,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy = .read,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)? = nil
    ) async throws -> ClaudeAPIAccountInfo {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode,
            userExplicitlyRequestedRefresh: userExplicitlyRequestedRefresh,
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
            }
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
        } catch {
            throw ClaudeAccountUsageFetchError.transport(error)
        }
    }

    private struct CredentialResolution {
        var credentials: ClaudeOAuthCredentials
        var liveAccessTokenAtRead: String?
        var liveItemLocationAtRead: ClaudeKeychainItemLocation?
        var storedAccessTokenAtRead: String?
        var preloadedStoredRecordAtRead: StoredCredentialRecord?
        var liveAccessWasDenied: Bool
        var isActiveCLI: Bool
        var wasRefreshed: Bool
        var allowsActiveCredentialRefresh: Bool
    }

    private enum StoredCredentialSource {
        case provider
        case preloaded(StoredCredentialRecord)
    }

    /// Active profiles consider both copies and use the credential generation
    /// with the later login/access expiry. Reading a newer stored generation
    /// is safe; rotating either active copy in the background is not. Inactive
    /// snapshots have a single owner and continue to refresh normally.
    private func resolveCredentials(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        now: Date,
        accessMode: CredentialAccessMode,
        userExplicitlyRequestedRefresh: Bool,
        liveCredentialReadPolicy: ClaudeLiveCredentialReadPolicy,
        liveCredentialAccessDenied: ((CredentialAccessDisposition) -> Void)?,
        storedCredentialSource: StoredCredentialSource
    ) async throws -> CredentialResolution {
        let allowsActiveCredentialRefresh = userExplicitlyRequestedRefresh
            || accessMode == .userInitiated
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
                // A decode failure leaves the account with no usable stored token
                // this cycle, but a readable live credential can still be used.
                stored = nil
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
            let storedFingerprint = stored.map(credentialFingerprint)
            if storedFingerprint != repair.recoveryFingerprint {
                // The saved generation changed independently, so this old
                // repair marker must not suppress the new credential.
                liveRepairs.clear(for: profile.id)
            } else if let stored {
                guard let currentLive = live else {
                    throw ClaudeAccountUsageFetchError.keychainLocked
                }
                let liveTokenStillStale = accessTokenFingerprint(
                    currentLive.accessToken
                ) == repair.staleLiveAccessTokenFingerprint
                if itemLocationFingerprint(liveRecord?.itemLocation)
                    != repair.staleLiveItemFingerprint,
                   liveTokenStillStale,
                   !allowsActiveCredentialRefresh {
                    // A replacement item is a new authorization context. Do
                    // not copy a recovery token into it during scheduled work,
                    // even when Claude preserved the same token string. Once
                    // the replacement is explicitly authorized, Retry may
                    // repair the freshly pinned location below.
                    throw ClaudeAccountUsageFetchError.keychainLocked
                }
                let liveFingerprint = credentialFingerprint(currentLive)
                if liveFingerprint == repair.recoveryFingerprint {
                    liveRepairs.clear(for: profile.id)
                    terminalRefreshes.clear(for: profile.id)
                } else if accessTokenFingerprint(currentLive.accessToken)
                            != repair.staleLiveAccessTokenFingerprint {
                    // Claude or the user replaced the live generation after
                    // the failed write. That external change wins.
                    liveRepairs.clear(for: profile.id)
                } else {
                    guard allowsActiveCredentialRefresh else {
                        // A valid stored recovery token may serve usage only
                        // when no failed active rotation is outstanding. Keep
                        // the visible remediation state until an explicit
                        // retry repairs the provider-owned item.
                        throw ClaudeAccountUsageFetchError.keychainLocked
                    }
                    do {
                        guard try credentials.replaceLiveClaudeOAuthCredentials(
                            stored,
                            at: liveRecord?.itemLocation,
                            ifAccessTokenMatches: currentLive.accessToken,
                            accessMode: accessMode
                        ) else {
                            throw ClaudeOAuthError.refreshSuppressed(
                                reason: "The active Claude credential changed while its saved recovery copy was being restored. Retry after reconciliation finishes."
                            )
                        }
                    } catch let error as ClaudeCodeCredentialsKeychainError
                        where error.isKeychainAccessDenied {
                        throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                            error: error,
                            item: liveRecord?.itemLocation
                        )
                    } catch {
                        throw ClaudeAccountUsageFetchError.refreshFailed(error)
                    }
                    liveRepairs.clear(for: profile.id)
                    terminalRefreshes.clear(for: profile.id)
                    live = stored
                }
            }
        }

        let selected: ClaudeOAuthCredentials?
        if isActiveCLI, let live, let stored {
            selected = stored.isFresher(than: live) ? stored : live
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

        if active.isExpired(asOf: now) {
            if isActiveCLI, live == nil {
                throw liveAccessDenied
                    ? ClaudeAccountUsageFetchError.keychainLocked
                    : ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            guard !isActiveCLI || allowsActiveCredentialRefresh else {
                throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            active = try await refreshAndPersist(
                CredentialResolution(
                    credentials: active,
                    liveAccessTokenAtRead: live?.accessToken,
                    liveItemLocationAtRead: liveRecord?.itemLocation,
                    storedAccessTokenAtRead: stored?.accessToken,
                    preloadedStoredRecordAtRead: preloadedStoredRecord,
                    liveAccessWasDenied: liveAccessDenied,
                    isActiveCLI: isActiveCLI,
                    wasRefreshed: false,
                    allowsActiveCredentialRefresh: allowsActiveCredentialRefresh
                ),
                for: profile,
                now: now,
                accessMode: accessMode
            )
            wasRefreshed = true
            effectiveStoredAccessToken = active.accessToken
            if isActiveCLI, allowsActiveCredentialRefresh, live != nil {
                effectiveLiveAccessToken = active.accessToken
            }
        } else if isActiveCLI,
                  let liveAccessToken = live?.accessToken,
                  liveAccessToken != active.accessToken {
            // An earlier build may have saved a rotated generation without
            // repairing the live item. Never hide that split with a successful
            // scheduled usage read; an explicit Retry heals it without
            // spending the fresh refresh token again, including after relaunch.
            guard allowsActiveCredentialRefresh else {
                throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            do {
                guard try credentials.replaceLiveClaudeOAuthCredentials(
                    active,
                    at: liveRecord?.itemLocation,
                    ifAccessTokenMatches: liveAccessToken,
                    accessMode: accessMode
                ) else {
                    throw ClaudeOAuthError.refreshSuppressed(
                        reason: "The active Claude credential changed while its saved generation was being restored. Retry after reconciliation finishes."
                    )
                }
                effectiveLiveAccessToken = active.accessToken
            } catch let error as ClaudeCodeCredentialsKeychainError
                where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.liveCredentialAccessDenied(
                    error: error,
                    item: liveRecord?.itemLocation
                )
            } catch {
                throw ClaudeAccountUsageFetchError.refreshFailed(error)
            }
        }

        return CredentialResolution(
            credentials: active,
            liveAccessTokenAtRead: effectiveLiveAccessToken,
            liveItemLocationAtRead: liveRecord?.itemLocation,
            storedAccessTokenAtRead: effectiveStoredAccessToken,
            preloadedStoredRecordAtRead: preloadedStoredRecord,
            liveAccessWasDenied: liveAccessDenied,
            isActiveCLI: isActiveCLI,
            wasRefreshed: wasRefreshed,
            allowsActiveCredentialRefresh: allowsActiveCredentialRefresh
        )
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
            }
        }
    }

    private func refreshAndPersist(
        _ resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> ClaudeOAuthCredentials {
        guard !resolution.isActiveCLI || resolution.allowsActiveCredentialRefresh else {
            throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
        }
        if resolution.isActiveCLI, resolution.liveAccessTokenAtRead == nil {
            // A stored access token may serve usage while the provider-owned
            // item is denied, but its refresh token must never be rotated away
            // from Claude Code unless the live item can be compare-and-swap
            // persisted in the same workflow.
            throw resolution.liveAccessWasDenied
                ? ClaudeAccountUsageFetchError.keychainLocked
                : ClaudeAccountUsageFetchError.interactiveRefreshRequired
        }

        let stale = resolution.credentials
        let staleFingerprint = credentialFingerprint(stale)
        if !resolution.allowsActiveCredentialRefresh,
           let reason = terminalRefreshes.reason(
               for: profile.id,
               credentialFingerprint: staleFingerprint
           ) {
            throw ClaudeAccountUsageFetchError.refreshFailed(
                ClaudeOAuthError.refreshSuppressed(reason: reason)
            )
        }

        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await refresher.refresh(stale, now: now)
        } catch let error as ClaudeOAuthError where error.requiresLogin {
            terminalRefreshes.record(
                reason: error.localizedDescription,
                for: profile.id,
                credentialFingerprint: staleFingerprint
            )
            throw ClaudeAccountUsageFetchError.refreshFailed(error)
        } catch {
            throw ClaudeAccountUsageFetchError.refreshFailed(error)
        }

        // For an active explicit Retry, protect the provider-owned live login
        // first. Both writes are compare-and-swap operations; an account or
        // credential change during the network request always wins.
        var persisted = false
        var storedPersisted = false
        var liveWriteError: Error?
        var liveWriteConflict = false
        if resolution.isActiveCLI,
           resolution.allowsActiveCredentialRefresh,
            let expectedLiveAccessToken = resolution.liveAccessTokenAtRead {
            do {
                let livePersisted = try credentials.replaceLiveClaudeOAuthCredentials(
                    refreshed,
                    at: resolution.liveItemLocationAtRead,
                    ifAccessTokenMatches: expectedLiveAccessToken,
                    accessMode: accessMode
                )
                liveWriteConflict = !livePersisted
                persisted = livePersisted || persisted
            } catch {
                liveWriteError = error
                AppLog.credentials.info("Could not write the refreshed token back to the live Claude Code item: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            if let expectedStoredAccessToken = resolution.storedAccessTokenAtRead {
                if let storedRecord = resolution.preloadedStoredRecordAtRead {
                    storedPersisted = try credentials.replaceStoredClaudeOAuthCredentials(
                        refreshed,
                        for: profile.id,
                        using: storedRecord,
                        ifAccessTokenMatches: expectedStoredAccessToken,
                        accessMode: accessMode
                    ) != nil
                } else {
                    storedPersisted = try credentials.replaceStoredClaudeOAuthCredentials(
                        refreshed,
                        for: profile.id,
                        ifAccessTokenMatches: expectedStoredAccessToken,
                        accessMode: accessMode
                    )
                }
                persisted = storedPersisted || persisted
            } else {
                try credentials.updateStoredClaudeOAuthCredentials(
                    refreshed,
                    for: profile.id,
                    accessMode: accessMode
                )
                storedPersisted = true
                persisted = true
            }
        } catch {
            AppLog.credentials.info("Could not persist the refreshed token for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if liveWriteError != nil || liveWriteConflict {
            // A false CAS means the live account changed during the request;
            // saving this profile's rotation is still safe. A thrown write,
            // however, leaves Claude Code on the known-stale generation. Keep
            // any stored recovery copy, but never issue a usage request or
            // report the active rotation as successful.
            let reason = "Claude refreshed this login, but the active Claude Code Keychain item could not be updated. Authorize access or sign in again before retrying."
            terminalRefreshes.record(
                reason: reason,
                for: profile.id,
                credentialFingerprint: staleFingerprint
            )
            if storedPersisted,
               let staleLiveAccessToken = resolution.liveAccessTokenAtRead {
                liveRepairs.record(
                    recoveryFingerprint: credentialFingerprint(refreshed),
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
                throw ClaudeAccountUsageFetchError.refreshFailed(liveWriteError)
            }
            throw ClaudeAccountUsageFetchError.refreshFailed(
                ClaudeOAuthError.refreshSuppressed(reason: reason)
            )
        }

        guard persisted else {
            let reason = "Claude refreshed this login, but Limit Lifeboat could not safely save the rotated credential. Sign in again before retrying."
            terminalRefreshes.record(
                reason: reason,
                for: profile.id,
                credentialFingerprint: staleFingerprint
            )
            throw ClaudeAccountUsageFetchError.refreshFailed(
                ClaudeOAuthError.refreshSuppressed(reason: reason)
            )
        }

        terminalRefreshes.clear(for: profile.id)
        if resolution.isActiveCLI {
            liveRepairs.clear(for: profile.id)
        }
        return refreshed
    }

    private func credentialFingerprint(_ credentials: ClaudeOAuthCredentials) -> String {
        SHA256.hash(data: credentials.rawClaudeAiOauth)
            .map { String(format: "%02x", $0) }
            .joined()
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

/// A service instance survives scheduled refresh cycles. Remembering only a
/// digest and a user-safe reason prevents repeated `invalid_grant` requests
/// without retaining another copy of the credential in memory.
private final class ClaudeTerminalRefreshRegistry: @unchecked Sendable {
    private struct Entry {
        var credentialFingerprint: String
        var reason: String
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func reason(for profileID: UUID, credentialFingerprint: String) -> String? {
        lock.withLock {
            guard entries[profileID]?.credentialFingerprint == credentialFingerprint else {
                return nil
            }
            return entries[profileID]?.reason
        }
    }

    func record(reason: String, for profileID: UUID, credentialFingerprint: String) {
        lock.withLock {
            entries[profileID] = Entry(
                credentialFingerprint: credentialFingerprint,
                reason: reason
            )
        }
    }

    func clear(for profileID: UUID) {
        _ = lock.withLock {
            entries.removeValue(forKey: profileID)
        }
    }
}
