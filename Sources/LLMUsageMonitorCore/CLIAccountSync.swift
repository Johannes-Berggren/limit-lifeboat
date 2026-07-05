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
        profiles: [AccountProfile]
    ) -> CLIAccountSyncAction {
        guard let currentIdentity else {
            return .deactivateAll
        }

        let providerProfiles = profiles.filter { $0.provider == provider }

        if let match = providerProfiles.first(where: { $0.identity?.matches(currentIdentity) == true }) {
            return .activate(match.id)
        }

        if let placeholder = providerProfiles.first(where: { $0.identity == nil }) {
            return .adopt(placeholder.id)
        }

        return .create
    }
}
