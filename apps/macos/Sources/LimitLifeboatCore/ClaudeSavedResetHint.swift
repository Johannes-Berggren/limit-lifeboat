import Foundation

/// Anthropic hands out saved rate-limit resets that only Claude Code and
/// claude.ai can see (the usage API reports `ineligible_reason: "surface"` to
/// any other client), so the app can't show or spend them. It can still point
/// at the command that does, when it would actually help: the account is out
/// and is the one Claude Code is logged in to.
public enum ClaudeSavedResetHint {
    /// A reset lists the limits it clears; the session and all-models weekly
    /// limits are the ones it reliably covers. Per-model and other scoped
    /// weekly limits may not be, so no hint there rather than a wrong one.
    static let coveredWindowIDs: Set<String> = ["session", "weekly-all"]

    public static func text(provider: Provider, windowID: String, riskLevel: RiskLevel, isActiveCLI: Bool) -> String? {
        guard provider == .claude,
              riskLevel == .depleted,
              isActiveCLI,
              coveredWindowIDs.contains(windowID) else { return nil }
        return "If you have a saved reset, /limit-reset in Claude Code refills this limit."
    }
}
