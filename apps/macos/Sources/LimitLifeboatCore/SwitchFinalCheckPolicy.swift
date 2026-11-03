import Foundation

/// A Claude switch checks its target before taking the shared credential lock
/// and again once it holds it, seconds apart, which is often enough for the
/// usage API to throttle the second check. That second check may continue only
/// if the first one really verified this target and the saved login is still
/// exactly what it verified; a login that changed in between is unverified.
public enum SwitchFinalCheckPolicy {
    public static func mayContinueAfterRateLimit(
        targetVerifiedBeforeLease: Bool,
        fingerprintBeforeLease: String?,
        currentFingerprint: String?
    ) -> Bool {
        guard targetVerifiedBeforeLease, let fingerprintBeforeLease else { return false }
        return fingerprintBeforeLease == currentFingerprint
    }
}
