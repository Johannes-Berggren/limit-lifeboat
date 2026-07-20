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
    /// A different profile owns the live CLI login for this same Claude account
    /// (e.g. the same account under another organization). Rotating this copy's
    /// refresh token would invalidate the active login's single-use chain, so
    /// it is never rotated — the account must be switched to instead.
    case accountActiveElsewhere
    /// An inactive account's access token expired, but a background cycle
    /// deliberately does not rotate it: refreshing an inactive account every
    /// cycle churns the single-use refresh chain (each rotation invalidates the
    /// copy every other session/Mac holds). Rotation is deferred to an explicit
    /// switch or Retry. The row keeps its last snapshot until then.
    case rotationDeferred
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
        case .accountActiveElsewhere:
            return "This account shares its Claude login with the active CLI account; switch to it to refresh."
        case .rotationDeferred:
            return "This inactive account's token expired; it refreshes when you switch the CLI to it."
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
        accountIsLiveElsewhere: Bool = false,
        permitRotation: Bool = false,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) async throws -> UsageSnapshot {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            permitRotation: permitRotation,
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
        accountIsLiveElsewhere: Bool = false,
        permitRotation: Bool = false,
        now: Date = Date(),
        accessMode: CredentialAccessMode = CredentialAccess.currentMode
    ) async throws -> ClaudeAPIAccountInfo {
        let resolution = try await resolveCredentials(
            for: profile,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            permitRotation: permitRotation,
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
        /// A sibling profile owns the live CLI login for this same account —
        /// this copy shares the active login's single-use chain and must never
        /// be rotated in any mode.
        var accountIsLiveElsewhere: Bool
        /// The caller explicitly wants this account activated/validated (a
        /// switch preflight), so rotation is allowed even in a background
        /// (non-`userInitiated`) auto-switch.
        var permitRotation: Bool
        var wasRefreshed: Bool
    }

    /// The single rotation gate both guard sites share. A refresh token is
    /// rotated only on an explicit account action — a Retry (`.userInitiated`)
    /// or a switch preflight (`permitRotation`, so an unattended auto-switch can
    /// still activate its target). Background polling never rotates: not a
    /// shared-account sibling (it would strand the live login), not the active
    /// login (it must not race Claude Code's own refresh), and not inactive
    /// accounts (rotating them every cycle churns the single-use chain that
    /// other sessions/Macs hold copies of).
    private static func mayRotate(
        accountIsLiveElsewhere: Bool,
        permitRotation: Bool,
        accessMode: CredentialAccessMode
    ) -> Bool {
        if accountIsLiveElsewhere {
            return false
        }
        return permitRotation || accessMode == .userInitiated
    }

    private static func rotationBlockedError(
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool
    ) -> ClaudeAccountUsageFetchError {
        if accountIsLiveElsewhere {
            return .accountActiveElsewhere
        }
        return isActiveCLI ? .interactiveRefreshRequired : .rotationDeferred
    }

    /// Active profiles consider both copies and use the credential generation
    /// with the later login/access expiry. Reading a newer stored generation
    /// is safe; rotating either active copy in the background is not. Inactive
    /// snapshots have a single owner and continue to refresh normally.
    private func resolveCredentials(
        for profile: AccountProfile,
        isActiveCLI: Bool,
        accountIsLiveElsewhere: Bool,
        permitRotation: Bool,
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
            guard Self.mayRotate(
                accountIsLiveElsewhere: accountIsLiveElsewhere,
                permitRotation: permitRotation,
                accessMode: accessMode
            ) else {
                throw Self.rotationBlockedError(
                    isActiveCLI: isActiveCLI,
                    accountIsLiveElsewhere: accountIsLiveElsewhere
                )
            }
            active = try await refreshAndPersist(
                CredentialResolution(
                    credentials: active,
                    liveAccessTokenAtRead: live?.accessToken,
                    storedAccessTokenAtRead: stored?.accessToken,
                    isActiveCLI: isActiveCLI,
                    accountIsLiveElsewhere: accountIsLiveElsewhere,
                    permitRotation: permitRotation,
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
                AppLog.credentials.error("Could not repair the active Claude Code credential from the fresher saved snapshot for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return CredentialResolution(
            credentials: active,
            liveAccessTokenAtRead: effectiveLiveAccessToken,
            storedAccessTokenAtRead: effectiveStoredAccessToken,
            isActiveCLI: isActiveCLI,
            accountIsLiveElsewhere: accountIsLiveElsewhere,
            permitRotation: permitRotation,
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
        guard Self.mayRotate(
            accountIsLiveElsewhere: resolution.accountIsLiveElsewhere,
            permitRotation: resolution.permitRotation,
            accessMode: accessMode
        ) else {
            throw Self.rotationBlockedError(
                isActiveCLI: resolution.isActiveCLI,
                accountIsLiveElsewhere: resolution.accountIsLiveElsewhere
            )
        }

        let stale = resolution.credentials
        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await refresher.refresh(stale, now: now)
        } catch {
            throw ClaudeAccountUsageFetchError.refreshFailed(error)
        }

        // For an active explicit Retry, protect the provider-owned live login
        // first. This write stays compare-and-swap: an account or credential
        // change during the network request (e.g. Claude Code's own rotation)
        // must win, since the live item is not ours to overwrite blindly.
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
                AppLog.credentials.error("Could not write the refreshed token back to the live Claude Code item for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // The stored snapshot is ours, and the server has already consumed the
        // old refresh token — the rotated generation is now the ONLY valid one.
        // A dropped write here means a guaranteed invalid_grant next cycle, so
        // this must not be best-effort: on a CAS miss, re-read and last-writer-
        // wins, yielding only to an already-fresher concurrent rotation.
        do {
            try persistRotatedStoredCredentials(
                refreshed,
                for: profile,
                storedAccessTokenAtRead: resolution.storedAccessTokenAtRead,
                accessMode: accessMode
            )
        } catch let error as CredentialStoreError where error.isKeychainAccessDenied {
            throw ClaudeAccountUsageFetchError.keychainLocked
        } catch {
            AppLog.credentials.error("Could not persist the refreshed token for account \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return refreshed
    }

    /// Writes the rotated credential into the profile's stored snapshot so the
    /// only valid refresh token survives. A plain CAS can lose to a concurrent
    /// writer (a switch capture, reconcile, or another poll) between the read
    /// and this write; when it does, re-read and force the rotated generation
    /// in unless the current stored copy is already fresher (a rotation that
    /// advanced the chain past ours).
    private func persistRotatedStoredCredentials(
        _ refreshed: ClaudeOAuthCredentials,
        for profile: AccountProfile,
        storedAccessTokenAtRead: String?,
        accessMode: CredentialAccessMode
    ) throws {
        if let expectedStoredAccessToken = storedAccessTokenAtRead,
           try credentials.replaceStoredClaudeOAuthCredentials(
               refreshed,
               for: profile.id,
               ifAccessTokenMatches: expectedStoredAccessToken,
               accessMode: accessMode
           ) {
            return
        }
        if let current = try credentials.storedClaudeOAuthCredentials(
            for: profile.id,
            accessMode: accessMode
        ), current.isFresher(than: refreshed) {
            return
        }
        try credentials.updateStoredClaudeOAuthCredentials(
            refreshed,
            for: profile.id,
            accessMode: accessMode
        )
    }
}
