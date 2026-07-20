import Foundation

/// What the app should do with the account currently logged into a provider's CLI.
public enum CLIAccountSyncAction: Equatable, Sendable {
    /// The CLI identity matched this existing profile; mark it active.
    case activate(UUID)
    /// No identity match, but this identity-less profile of the same provider
    /// can take on the CLI identity.
    case adopt(UUID)
    /// No candidate profile exists; register a new one for this identity.
    case create
    /// No CLI login is present for this provider.
    case deactivateAll
}

/// Pure decision logic mapping the current CLI login onto the profile list.
/// Deliberately has no fallback guessing: an identity either matches a
/// profile, adopts a placeholder, or gets a new profile — usage is never
/// attributed to an account it might not belong to.
public struct CLIAccountSyncPlanner: Sendable {
    public init() {}

    public func plan(
        provider: Provider,
        currentIdentity: AccountIdentity?,
        profiles: [AccountProfile],
        liveCredentialFingerprint: String? = nil,
        storedCredentialFingerprints: [UUID: String] = [:],
        profilesWithStoredCredentials: Set<UUID> = []
    ) -> CLIAccountSyncAction {
        guard currentIdentity != nil || liveCredentialFingerprint != nil else {
            return .deactivateAll
        }

        let providerProfiles = profiles.filter { $0.provider == provider }

        if let liveCredentialFingerprint {
            // Two profiles can share one Anthropic account (same accountID under
            // different organizations) and therefore hold byte-identical stored
            // chains. A blind `.first` fingerprint match could activate the
            // wrong sibling and cross-write its chain. Prefer the sibling whose
            // identity matches the live login (org-aware), then the one already
            // marked active, before falling back to declaration order.
            let fingerprintMatches = providerProfiles.filter {
                storedCredentialFingerprints[$0.id] == liveCredentialFingerprint
            }
            let identityMatch = fingerprintMatches.first { candidate in
                guard let currentIdentity else { return false }
                return candidate.identity?.matches(currentIdentity) == true
            }
            if let chosen = identityMatch
                ?? fingerprintMatches.first(where: { $0.isActiveCLI })
                ?? fingerprintMatches.first {
                return .activate(chosen.id)
            }
        }

        if let currentIdentity,
           let match = providerProfiles.first(where: { $0.identity?.matches(currentIdentity) == true }) {
            return .activate(match.id)
        }

        if let placeholder = providerProfiles.first(where: {
            $0.identity == nil && !profilesWithStoredCredentials.contains($0.id)
        }) {
            return .adopt(placeholder.id)
        }

        return .create
    }
}
