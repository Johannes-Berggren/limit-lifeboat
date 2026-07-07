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
