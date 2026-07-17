/// The permanent Apple Developer Team ID for every public Limit Lifeboat
/// release. release.sh refuses to ship when TEAM_ID differs.
enum DistributionIdentity {
    static let appleTeamIdentifier = "3DQ7YC2YH2"

    /// Anthropic's Developer ID team, which owns the `Claude Code-credentials`
    /// keychain item. Its partition list must trust both this team and ours.
    static let claudeCodeTeamIdentifier = "Q6L2SF6YDW"

    /// The partition-list entries the `Claude Code-credentials` item must trust
    /// so neither Claude Code nor this app is re-prompted on every read. Mirrors
    /// REQUIRED_PARTITIONS in scripts/fix-keychain-prompts.sh.
    static let requiredClaudeKeychainPartitions = [
        "apple-tool:",
        "apple:",
        "teamid:\(appleTeamIdentifier)",
        "teamid:\(claudeCodeTeamIdentifier)"
    ]
}
