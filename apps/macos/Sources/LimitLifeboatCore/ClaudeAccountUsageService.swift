import Foundation
import os

/// The credential surface `ClaudeAccountUsageService` needs; `CLISwitcher`
/// is the production implementation, tests use an in-memory fake.
public protocol ClaudeOAuthCredentialProviding: AnyObject {
    func liveClaudeOAuthCredentials(accessMode: CredentialAccessMode) throws -> ClaudeOAuthCredentials?
    func writeLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws
    @discardableResult
    func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
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
    /// The active CLI credential needs rotation, but a background task must
    /// not consume its refresh token out from under Claude Code.
    case interactiveRefreshRequired
    case refreshFailed(Error)
    case unauthorized
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No captured OAuth token for this account yet."
        case .keychainLocked:
            return "The macOS Keychain denied access to this account's saved credentials."
        case .interactiveRefreshRequired:
            return "The active Claude login needs an explicit Retry before its access token can be refreshed."
        case .refreshFailed(let underlying):
            return "Could not refresh the access token (\(underlying.localizedDescription))."
        case .unauthorized:
            return "The Anthropic usage API rejected the account's tokens."
        case .transport(let underlying):
            return underlying.localizedDescription
        }
    }
}

/// Fetches an exact, account-wide usage snapshot for one Claude profile via
/// the OAuth usage API — active or inactive, no CLI launch. Callers should
/// process profiles sequentially so concurrent token refreshes cannot race.
public struct ClaudeAccountUsageService {
    private let apiClient: ClaudeUsageAPIClient
    private let refresher: ClaudeOAuthTokenRefresher
    private let credentials: ClaudeOAuthCredentialProviding

    public init(
        apiClient: ClaudeUsageAPIClient = ClaudeUsageAPIClient(),
        refresher: ClaudeOAuthTokenRefresher = ClaudeOAuthTokenRefresher(),
        credentials: ClaudeOAuthCredentialProviding
    ) {
        self.apiClient = apiClient
        self.refresher = refresher
        self.credentials = credentials
    }

    public func fetchSnapshot(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) async throws -> UsageSnapshot {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode
        )

        do {
            let usage = try await fetchUsage(
                with: resolution,
                for: profile,
                now: now,
                accessMode: accessMode
            )
            // A 2xx body with no recognizable windows must fail the fetch:
            // a parseConfidence-.none snapshot would overwrite the last good
            // one and bypass AppState's CLI fallback.
            guard !usage.windows.isEmpty else {
                throw ClaudeAccountUsageFetchError.transport(ClaudeUsageAPIError.malformedResponse)
            }
            return apiClient.makeSnapshot(for: profile, usage: usage, now: now)
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
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) async throws -> ClaudeAPIAccountInfo {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode
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

    private struct CredentialResolution {
        var credentials: ClaudeOAuthCredentials
        var liveAccessTokenAtRead: String?
        var storedAccessTokenAtRead: String?
        var isActiveCLI: Bool
        var wasRefreshed: Bool
    }

    /// Active profiles consider both copies and use the credential generation
    /// with the later login/access expiry. Reading a newer stored generation
    /// is safe; rotating either active copy in the background is not. Inactive
    /// snapshots have a single owner and continue to refresh normally.
    private func resolveCredentials(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> CredentialResolution {
        var live: ClaudeOAuthCredentials?
        if isActiveCLI {
            do {
                live = try credentials.liveClaudeOAuthCredentials(accessMode: accessMode)
            } catch let error as ClaudeCodeCredentialsKeychainError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                live = nil
            }
        }

        let stored: ClaudeOAuthCredentials?
        do {
            stored = try credentials.storedClaudeOAuthCredentials(
                for: profile.id,
                accessMode: accessMode
            )
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            if live == nil {
                throw ClaudeAccountUsageFetchError.keychainLocked
            }
            stored = nil
        } catch {
            // A decode failure leaves the account with no usable stored token
            // this cycle, but a readable live credential can still be used.
            stored = nil
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
            throw ClaudeAccountUsageFetchError.noCredentials
        }
        var effectiveLiveAccessToken = live?.accessToken
        var effectiveStoredAccessToken = stored?.accessToken
        var wasRefreshed = false

        if active.isExpired(asOf: now) {
            guard !isActiveCLI || accessMode == .userInitiated else {
                throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
            }
            active = try await refreshAndPersist(
                CredentialResolution(
                    credentials: active,
                    liveAccessTokenAtRead: live?.accessToken,
                    storedAccessTokenAtRead: stored?.accessToken,
                    isActiveCLI: isActiveCLI,
                    wasRefreshed: false
                ),
                for: profile,
                now: now,
                accessMode: accessMode
            )
            wasRefreshed = true
            effectiveStoredAccessToken = active.accessToken
            if isActiveCLI, accessMode == .userInitiated, live != nil {
                effectiveLiveAccessToken = active.accessToken
            }
        } else if isActiveCLI,
                  accessMode == .userInitiated,
                  let liveAccessToken = live?.accessToken,
                  liveAccessToken != active.accessToken {
            // An earlier build may have saved a rotated generation without
            // repairing the live item. An explicit Retry heals that split
            // without spending the fresh refresh token again.
            do {
                if try credentials.replaceLiveClaudeOAuthCredentials(
                    active,
                    ifAccessTokenMatches: liveAccessToken,
                    accessMode: accessMode
                ) {
                    effectiveLiveAccessToken = active.accessToken
                }
            } catch {
                AppLog.credentials.info("Could not repair the active Claude Code credential from the fresher saved snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }

        return CredentialResolution(
            credentials: active,
            liveAccessTokenAtRead: effectiveLiveAccessToken,
            storedAccessTokenAtRead: effectiveStoredAccessToken,
            isActiveCLI: isActiveCLI,
            wasRefreshed: wasRefreshed
        )
    }

    private func fetchUsage(
        with resolution: CredentialResolution,
        for profile: AccountProfile,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> ClaudeAPIUsage {
        do {
            return try await apiClient.fetchUsage(accessToken: resolution.credentials.accessToken)
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
            do {
                return try await apiClient.fetchUsage(accessToken: refreshed.accessToken)
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
        guard !resolution.isActiveCLI || accessMode == .userInitiated else {
            throw ClaudeAccountUsageFetchError.interactiveRefreshRequired
        }

        let stale = resolution.credentials
        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await refresher.refresh(stale, now: now)
        } catch {
            throw ClaudeAccountUsageFetchError.refreshFailed(error)
        }

        // For an active explicit Retry, protect the provider-owned live login
        // first. Both writes are compare-and-swap operations; an account or
        // credential change during the network request always wins.
        if resolution.isActiveCLI,
           accessMode == .userInitiated,
           let expectedLiveAccessToken = resolution.liveAccessTokenAtRead {
            do {
                _ = try credentials.replaceLiveClaudeOAuthCredentials(
                    refreshed,
                    ifAccessTokenMatches: expectedLiveAccessToken,
                    accessMode: accessMode
                )
            } catch {
                AppLog.credentials.info("Could not write the refreshed token back to the live Claude Code item: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            if let expectedStoredAccessToken = resolution.storedAccessTokenAtRead {
                _ = try credentials.replaceStoredClaudeOAuthCredentials(
                    refreshed,
                    for: profile.id,
                    ifAccessTokenMatches: expectedStoredAccessToken,
                    accessMode: accessMode
                )
            } else {
                try credentials.updateStoredClaudeOAuthCredentials(
                    refreshed,
                    for: profile.id,
                    accessMode: accessMode
                )
            }
        } catch {
            AppLog.credentials.info("Could not persist the refreshed token for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return refreshed
    }
}
