import Foundation

/// Human text for Codex's `rate_limit_reached_type`. Codex 0.15x added
/// workspace-level states next to the plain per-account limit; those come from
/// a Business/Enterprise workspace running out of credits or hitting its own
/// cap, which no earned reset can clear.
enum CodexRateLimitReachedType {
    static func statusText(_ raw: String) -> String {
        switch normalized(raw) {
        case "ratelimitreached":
            return "Rate limit reached."
        case "workspaceownercreditsdepleted":
            return "Workspace credits are used up; add credits in the workspace settings."
        case "workspacemembercreditsdepleted":
            return "Workspace credits are used up; ask a workspace owner to add more."
        case "workspaceownerusagelimitreached":
            return "The workspace usage limit is reached; raise it in the workspace settings."
        case "workspacememberusagelimitreached":
            return "The workspace usage limit is reached; ask a workspace owner to raise it."
        default:
            return "Rate limit reached: \(raw)."
        }
    }

    /// Accepts snake_case and PascalCase spellings of the same value.
    private static func normalized(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "_", with: "")
    }
}
