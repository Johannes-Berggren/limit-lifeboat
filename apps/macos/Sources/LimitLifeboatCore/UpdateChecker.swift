import Foundation

public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts "1.2.3", "v1.2.3", "1.2", and ignores pre-release/build
    /// suffixes ("1.2.0-beta.1"). Anything non-numeric resolves to nil.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        guard let core = trimmed.split(separator: "-", maxSplits: 1).first else {
            return nil
        }
        let parts = core.split(separator: ".")
        guard !parts.isEmpty, parts.count <= 3 else {
            return nil
        }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else {
                return nil
            }
            numbers.append(value)
        }
        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }
}

/// The subset of GitHub's `releases/latest` payload the app needs.
public struct LatestRelease: Equatable, Sendable, Decodable {
    public var tagName: String
    public var htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(tagName: String, htmlURL: URL) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    public var url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case updateAvailable(AvailableUpdate)
    case upToDate
    case failed(message: String)
}

/// Fetches and classifies GitHub's latest-release response. Keeping transport
/// and decoding in Core makes every network and API outcome deterministic in
/// tests; the app target only decides how to present and schedule the result.
public struct GitHubUpdateChecker: Sendable {
    public static let defaultReleasesURL = URL(
        string: "https://api.github.com/repos/Johannes-Berggren/limit-lifeboat/releases/latest"
    )!

    private let releasesURL: URL
    private let httpClient: HTTPClienting

    public init(
        releasesURL: URL = Self.defaultReleasesURL,
        httpClient: HTTPClienting = URLSessionHTTPClient()
    ) {
        self.releasesURL = releasesURL
        self.httpClient = httpClient
    }

    public func check(currentVersion: String) async -> UpdateCheckResult {
        var request = URLRequest(url: releasesURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LimitLifeboat", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.send(request)
        } catch {
            return .failed(message: "Couldn’t check for updates. \(error.localizedDescription)")
        }

        guard response.statusCode == 200 else {
            return .failed(
                message: "Couldn’t check for updates because GitHub returned HTTP \(response.statusCode)."
            )
        }
        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
            return .failed(message: "Couldn’t check for updates because GitHub returned an invalid release response.")
        }
        guard let current = SemanticVersion(currentVersion) else {
            return .failed(message: "This app build does not have a valid version number.")
        }
        guard let latest = SemanticVersion(release.tagName) else {
            return .failed(message: "GitHub’s latest release has an invalid version tag.")
        }

        if latest > current {
            return .updateAvailable(
                AvailableUpdate(version: latest.description, url: release.htmlURL)
            )
        }
        return .upToDate
    }
}

public enum UpdateCheckSchedule {
    public static let successfulCheckInterval: TimeInterval = 24 * 60 * 60
    public static let failedCheckRetryInterval: TimeInterval = 60 * 60

    public static func shouldCheck(
        lastSuccessfulCheck: Date?,
        lastFailedCheck: Date?,
        now: Date = Date()
    ) -> Bool {
        if let lastSuccessfulCheck,
           lastSuccessfulCheck > now.addingTimeInterval(-successfulCheckInterval) {
            return false
        }
        if let lastFailedCheck,
           lastFailedCheck > now.addingTimeInterval(-failedCheckRetryInterval) {
            return false
        }
        return true
    }
}

public enum UpdateChecker {
    /// False whenever either version is unparseable — dev builds ("dev") and
    /// malformed tags never nag.
    public static func isUpdateAvailable(currentVersion: String, latestTag: String) -> Bool {
        guard let current = SemanticVersion(currentVersion),
              let latest = SemanticVersion(latestTag) else {
            return false
        }
        return latest > current
    }
}
