import Foundation

/// Decides whether refreshing a profile's OAuth token in the background could
/// invalidate a single-use refresh-token chain another holder still relies on.
///
/// Claude OAuth rotates refresh tokens: whoever refreshes gets a new one and
/// the old one dies. `ClaudeAccountUsageService` already refuses to rotate the
/// profile that owns the live CLI login (keyed on `isActiveCLI`). But two
/// profiles can map to ONE Anthropic account — e.g. the same `accountID` under
/// two organizations, or two profiles that captured the same chain — in which
/// case the "inactive" sibling shares the live login's chain and must not be
/// rotated either. This pure policy detects that so the guard can protect the
/// whole account, not just the one active profile.
public enum RotationProtectionPolicy {
    /// Uses the refresh-token chain itself as the authoritative signal. When
    /// both digests are readable, different values prove that the grants are
    /// independent even if they belong to the same Anthropic account. Account
    /// identity is only a fail-closed fallback when a digest is unavailable.
    public static func accountIsLiveElsewhere(
        profile: AccountProfile,
        among profiles: [AccountProfile],
        storedChainFingerprint: String?,
        liveChainFingerprint: String?
    ) -> Bool {
        guard !profile.isActiveCLI else { return false }

        if let storedChainFingerprint, let liveChainFingerprint {
            return storedChainFingerprint == liveChainFingerprint
        }

        guard let accountID = profile.identity?.accountID else { return false }
        return profiles.contains { other in
            other.id != profile.id
                && other.provider == profile.provider
                && other.isActiveCLI
                && other.identity?.accountID == accountID
        }
    }
}
