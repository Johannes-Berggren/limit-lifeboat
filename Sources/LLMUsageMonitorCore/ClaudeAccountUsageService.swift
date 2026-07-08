import Foundation

/// The credential surface `ClaudeAccountUsageService` needs; `CLISwitcher`
/// is the production implementation, tests use an in-memory fake.
public protocol ClaudeOAuthCredentialProviding: AnyObject {
    func liveClaudeOAuthCredentials() -> ClaudeOAuthCredentials?
    func writeLiveClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials) throws
    func storedClaudeOAuthCredentials(for profileID: UUID) throws -> ClaudeOAuthCredentials?
    func updateStoredClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials, for profileID: UUID) throws
}

extension CLISwitcher: ClaudeOAuthCredentialProviding {}

public enum ClaudeAccountUsageFetchError: Error, LocalizedError {
    /// The profile has no captured OAuth token yet (it becomes pollable
    /// after being the active CLI login once).
    case noCredentials
    case refreshFailed(Error)
    case unauthorized
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No captured OAuth token for this account yet."
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
        now: Date = Date()
    ) async throws -> UsageSnapshot {
        // The active profile prefers the live keychain item — the CLI keeps
        // it fresh, so a valid live token must never be refreshed out from
        // under it. Inactive profiles poll with their stored snapshot token.
        var cameFromLiveItem = false
        var current: ClaudeOAuthCredentials?
        if isActiveCLI, let live = credentials.liveClaudeOAuthCredentials() {
            current = live
            cameFromLiveItem = true
        } else {
            current = try? credentials.storedClaudeOAuthCredentials(for: profile.id)
        }

        guard var active = current else {
            throw ClaudeAccountUsageFetchError.noCredentials
        }

        if active.isExpired(asOf: now) {
            active = try await refreshAndPersist(active, for: profile, updateLiveItem: cameFromLiveItem, now: now)
        }

        do {
            let usage = try await fetchUsage(with: active, for: profile, updateLiveItem: cameFromLiveItem, now: now)
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
        now: Date = Date()
    ) async throws -> ClaudeAPIAccountInfo {
        var cameFromLiveItem = false
        var current: ClaudeOAuthCredentials?
        if isActiveCLI, let live = credentials.liveClaudeOAuthCredentials() {
            current = live
            cameFromLiveItem = true
        } else {
            current = try? credentials.storedClaudeOAuthCredentials(for: profile.id)
        }

        guard var active = current else {
            throw ClaudeAccountUsageFetchError.noCredentials
        }

        if active.isExpired(asOf: now) {
            active = try await refreshAndPersist(active, for: profile, updateLiveItem: cameFromLiveItem, now: now)
        }

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

    private func fetchUsage(
        with credentials: ClaudeOAuthCredentials,
        for profile: AccountProfile,
        updateLiveItem: Bool,
        now: Date
    ) async throws -> ClaudeAPIUsage {
        do {
            return try await apiClient.fetchUsage(accessToken: credentials.accessToken)
        } catch ClaudeUsageAPIError.unauthorized {
            // The token can be revoked before its recorded expiry; one forced
            // refresh is the only retry.
            let refreshed = try await refreshAndPersist(credentials, for: profile, updateLiveItem: updateLiveItem, now: now)
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
        now: Date
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
        try? credentials.updateStoredClaudeOAuthCredentials(refreshed, for: profile.id)
        if updateLiveItem,
           credentials.liveClaudeOAuthCredentials()?.accessToken == stale.accessToken {
            try? credentials.writeLiveClaudeOAuthCredentials(refreshed)
        }
        return refreshed
    }
}
