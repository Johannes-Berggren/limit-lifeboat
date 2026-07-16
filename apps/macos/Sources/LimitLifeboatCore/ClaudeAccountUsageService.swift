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
    case refreshFailed(Error)
    case unauthorized
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No captured OAuth token for this account yet."
        case .keychainLocked:
            return "The macOS Keychain denied access to this account's saved credentials."
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
        let (active, cameFromLiveItem) = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode
        )

        do {
            let usage = try await fetchUsage(
                with: active,
                for: profile,
                updateLiveItem: cameFromLiveItem,
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
        let (active, _) = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            now: now,
            accessMode: accessMode
        )

        do {
            return try await apiClient.fetchAccountInfo(accessToken: active.accessToken, now: now)
        } catch ClaudeUsageAPIError.unauthorized {
            throw ClaudeAccountUsageFetchError.unauthorized
        } catch let error as ClaudeAccountUsageFetchError {
            throw error
        } catch {
            throw ClaudeAccountUsageFetchError.transport(error)
        }
    }

    /// The active profile prefers the live keychain item — the CLI keeps it
    /// fresh, so a valid live token must never be refreshed out from under
    /// it. Inactive profiles resolve their stored snapshot token. Expired
    /// tokens get one persisted refresh.
    private func resolveCredentials(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> (credentials: ClaudeOAuthCredentials, cameFromLiveItem: Bool) {
        var cameFromLiveItem = false
        var current: ClaudeOAuthCredentials?
        if isActiveCLI {
            do {
                if let live = try credentials.liveClaudeOAuthCredentials(accessMode: accessMode) {
                    current = live
                    cameFromLiveItem = true
                }
            } catch let error as ClaudeCodeCredentialsKeychainError where error.isKeychainAccessDenied {
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                current = nil
            }
        }
        if current == nil {
            do {
                current = try credentials.storedClaudeOAuthCredentials(
                    for: profile.id,
                    accessMode: accessMode
                )
            } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
                // A locked/denied Keychain is not the same as "no credentials":
                // surface it so the UI can prompt to grant access.
                throw ClaudeAccountUsageFetchError.keychainLocked
            } catch {
                // A decode failure or other read error leaves the account with
                // no usable token this cycle; it keeps its last snapshot.
                current = nil
            }
        }

        guard var active = current else {
            throw ClaudeAccountUsageFetchError.noCredentials
        }

        if active.isExpired(asOf: now) {
            active = try await refreshAndPersist(
                active,
                for: profile,
                updateLiveItem: cameFromLiveItem,
                now: now,
                accessMode: accessMode
            )
        }
        return (active, cameFromLiveItem)
    }

    private func fetchUsage(
        with credentials: ClaudeOAuthCredentials,
        for profile: AccountProfile,
        updateLiveItem: Bool,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> ClaudeAPIUsage {
        do {
            return try await apiClient.fetchUsage(accessToken: credentials.accessToken)
        } catch ClaudeUsageAPIError.unauthorized {
            // The token can be revoked before its recorded expiry; one forced
            // refresh is the only retry.
            let refreshed = try await refreshAndPersist(
                credentials,
                for: profile,
                updateLiveItem: updateLiveItem,
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
        _ stale: ClaudeOAuthCredentials,
        for profile: AccountProfile,
        updateLiveItem: Bool,
        now: Date,
        accessMode: CredentialAccessMode
    ) async throws -> ClaudeOAuthCredentials {
        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await refresher.refresh(stale, now: now)
        } catch {
            throw ClaudeAccountUsageFetchError.refreshFailed(error)
        }

        // Persistence is best-effort: a failed write costs one extra refresh
        // on the next cycle, never the reading we just paid for. The live
        // item is only rewritten when the stale token came from it, so a
        // logged-out terminal is never silently logged back in — and only
        // when the live token is still the one we refreshed. Anything else
        // means the item changed owner mid-flight (the user switched
        // accounts during the await), and the old profile's tokens must not
        // overwrite the new live item.
        do {
            _ = try credentials.replaceStoredClaudeOAuthCredentials(
                refreshed,
                for: profile.id,
                ifAccessTokenMatches: stale.accessToken,
                accessMode: accessMode
            )
        } catch {
            AppLog.credentials.info("Could not persist the refreshed token for account \(profile.id, privacy: .public); it will refresh again next cycle: \(error.localizedDescription, privacy: .public)")
        }
        // A scheduled/background usage refresh must never mutate the CLI's
        // live login. Only an explicit user action (Retry, manual switch, or
        // capture workflow) may write refreshed tokens back to Claude Code.
        if updateLiveItem, accessMode == .userInitiated {
            do {
                _ = try credentials.replaceLiveClaudeOAuthCredentials(
                    refreshed,
                    ifAccessTokenMatches: stale.accessToken,
                    accessMode: accessMode
                )
            } catch {
                AppLog.credentials.info("Could not write the refreshed token back to the live Claude Code item: \(error.localizedDescription, privacy: .public)")
            }
        }
        return refreshed
    }
}
