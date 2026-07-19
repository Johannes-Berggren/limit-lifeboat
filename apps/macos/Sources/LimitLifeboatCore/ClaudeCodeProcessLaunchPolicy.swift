import Foundation

/// Keeps Claude executable discovery free of credentials. The OAuth token is
/// added only to the environment of the final, already-resolved Claude probe.
public enum ClaudeCodeProcessLaunchPolicy {
    public static let oauthEnvironmentKey = "CLAUDE_CODE_OAUTH_TOKEN"

    public static func discoveryEnvironment(
        homeDirectory: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var values = processEnvironment
        values.removeValue(forKey: oauthEnvironmentKey)
        let fallbackPath = "\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = values["PATH"], !existingPath.isEmpty {
            values["PATH"] = "\(fallbackPath):\(existingPath)"
        } else {
            values["PATH"] = fallbackPath
        }
        values["NO_COLOR"] = "1"
        values["TERM"] = "xterm-256color"
        return values
    }

    public static func credentialedEnvironment(
        homeDirectory: URL,
        oauthToken: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String]? {
        guard ClaudeCodeUsageLaunchGate.isValid(oauthToken) else { return nil }
        var values = discoveryEnvironment(
            homeDirectory: homeDirectory,
            processEnvironment: processEnvironment
        )
        values[oauthEnvironmentKey] = oauthToken
        return values
    }

    public static func executableCandidates(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        let preferred = [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        var seen: Set<String> = []
        return (preferred + pathCandidates).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }
}
