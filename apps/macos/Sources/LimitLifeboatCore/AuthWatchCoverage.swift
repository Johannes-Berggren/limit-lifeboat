import Foundation

/// Chooses the closest existing directory that can observe each credential
/// file's parent being created or replaced. The home directory is always kept
/// as a fallback so first-run creation of `.codex` or Claude's support
/// directory cannot leave filesystem monitoring permanently unarmed.
public enum AuthWatchCoverage {
    public static func directories(
        for targets: [URL],
        homeDirectory: URL,
        directoryExists: (URL) -> Bool
    ) -> Set<URL> {
        let home = homeDirectory.standardizedFileURL
        var result: Set<URL> = directoryExists(home) ? [home] : []

        for target in targets {
            var candidate = target.deletingLastPathComponent().standardizedFileURL
            while candidate.path != home.path,
                  candidate.path.hasPrefix(home.path + "/"),
                  !directoryExists(candidate) {
                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                guard parent != candidate else { break }
                candidate = parent
            }
            if directoryExists(candidate) {
                result.insert(candidate)
            }
        }
        return result
    }
}
