import Foundation

/// Anthropic hands out saved rate-limit resets that only Claude Code and
/// claude.ai can see (the usage API reports `ineligible_reason: "surface"` to
/// any other client), so the app can't show or spend them. It can still point
/// at the command that does, when it would actually help: the account is out
/// and is the one Claude Code is logged in to.
public enum ClaudeSavedResetHint {
    public static func text(provider: Provider, riskLevel: RiskLevel, isActiveCLI: Bool) -> String? {
        guard provider == .claude, riskLevel == .depleted, isActiveCLI else { return nil }
        return "If you have a saved reset, /limit-reset in Claude Code uses it."
    }
}
