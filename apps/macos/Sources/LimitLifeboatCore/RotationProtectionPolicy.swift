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
    /// True when `profile` is not the active login itself but shares its
    /// underlying Claude login with the active profile (same `accountID`) or
    /// with another holder the app can see (a stored credential fingerprint
    /// that also appears elsewhere — another profile's snapshot or the live
    /// keychain item). Such a profile must never be background-rotated; the
    /// safe way to refresh it is to switch the CLI to it first.
    public static func accountIsLiveElsewhere(
        profile: AccountProfile,
        among profiles: [AccountProfile],
        storedFingerprint: String?,
        duplicatedStoredFingerprints: Set<String>
    ) -> Bool {
        // The active login owns the live item and heals it on an explicit
        // Retry; it is never "live elsewhere".
        if profile.isActiveCLI {
            return false
        }
        // A different, active same-provider profile shares this account.
        if let accountID = profile.identity?.accountID {
            let sharedWithActive = profiles.contains { other in
                guard other.id != profile.id,
                      other.provider == profile.provider,
                      other.isActiveCLI else {
                    return false
                }
                return other.identity?.accountID == accountID
            }
            if sharedWithActive {
                return true
            }
        }
        // The stored chain is byte-identical to another holder's (another
        // profile's snapshot or the live keychain item). Rotating it would
        // strand that holder even when the identities don't reveal the sharing.
        if let storedFingerprint,
           duplicatedStoredFingerprints.contains(storedFingerprint) {
            return true
        }
        return false
    }
}
