import Foundation
import LimitLifeboatCore

enum AppInfo {
    /// "dev" for unbundled `swift run` builds; those never see update prompts.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

/// Asks GitHub for the latest release. Deliberately not Sparkle: the release
/// pipeline signs a single binary with no nested code, so the app only tells
/// the user an update exists and links to the release page.
struct UpdateService {
    private let checker = GitHubUpdateChecker()

    func checkForUpdates(currentVersion: String = AppInfo.version) async -> UpdateCheckResult {
        await checker.check(currentVersion: currentVersion)
    }
}
