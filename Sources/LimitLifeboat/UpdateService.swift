import Foundation
import LimitLifeboatCore

enum AppInfo {
    /// "dev" for unbundled `swift run` builds; those never see update prompts.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

struct AvailableUpdate: Equatable {
    var version: String
    var url: URL
}

/// Asks GitHub for the latest release. Deliberately not Sparkle: the release
/// pipeline signs a single binary with no nested code, so the app only tells
/// the user an update exists and links to the release page.
struct UpdateService {
    var releasesURL = URL(string: "https://api.github.com/repos/Johannes-Berggren/limit-lifeboat/releases/latest")!

    func fetchAvailableUpdate(currentVersion: String = AppInfo.version) async -> AvailableUpdate? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
              UpdateChecker.isUpdateAvailable(currentVersion: currentVersion, latestTag: release.tagName) else {
            return nil
        }

        let version = SemanticVersion(release.tagName)?.description ?? release.tagName
        return AvailableUpdate(version: version, url: release.htmlURL)
    }
}
