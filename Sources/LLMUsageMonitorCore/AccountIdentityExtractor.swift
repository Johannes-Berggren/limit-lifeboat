import Foundation

public struct AccountIdentityExtractor: Sendable {
    public init() {}

    public func extractFromDashboardText(_ rawText: String, now: Date = Date()) -> AccountIdentity? {
        let text = rawText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        let email = firstMatch(
            #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
            in: text
        )
        let organization = cleanedOrganization(firstCapture(
            #"(?i)\b(?:organization|workspace|team)\s*[:\-]?\s*([A-Za-z0-9][A-Za-z0-9 ._@&+\-]{1,80})"#,
            in: text
        ))
        let name = firstCapture(
            #"(?i)\b(?:name|profile)\s*[:\-]?\s*([A-Z][A-Za-z .'\-]{2,80})"#,
            in: text
        )

        guard email != nil || organization != nil || name != nil else {
            return nil
        }

        let identity = AccountIdentity(
            email: email,
            displayName: name,
            organization: organization,
            source: .dashboard,
            updatedAt: now
        )
        guard identity.isLikelyValid else {
            return nil
        }

        return identity
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        return (text as NSString).substring(with: match.range)
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (text as NSString)
            .substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedOrganization(_ value: String?) -> String? {
        guard var value else {
            return nil
        }
        let stopWords = [
            " settings",
            " usage",
            " billing",
            " members",
            " profile"
        ]
        let lowerBeforeStop = value.lowercased()
        for stopWord in stopWords {
            if let range = lowerBeforeStop.range(of: stopWord) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        let invalidFragments = [
            "try claude",
            "individual team",
            "team and enterprise",
            "free ",
            "pricing",
            "log in",
            "sign up"
        ]
        guard value.count <= 50, !invalidFragments.contains(where: lower.contains) else {
            return nil
        }
        return value
    }
}

public struct CodexIdentityReader {
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func readIdentity(now: Date = Date()) -> AccountIdentity? {
        let authURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else {
            return nil
        }

        let accountID = tokens["account_id"] as? String
        let payload = (tokens["id_token"] as? String).flatMap(decodeJWTPayload)
        let email = payload?["email"] as? String
        let name = payload?["name"] as? String
        let defaultOrganization = self.defaultOrganization(from: payload)
        let organization = (payload?["organization"] as? String)
            ?? (payload?["org"] as? String)
            ?? (payload?["workspace"] as? String)
            ?? defaultOrganization?.title

        guard email != nil || name != nil || organization != nil || accountID != nil else {
            return nil
        }

        return AccountIdentity(
            email: email,
            displayName: name,
            organization: organization,
            organizationID: defaultOrganization?.id,
            accountID: accountID,
            source: .codexIDToken,
            updatedAt: now
        )
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func defaultOrganization(from payload: [String: Any]?) -> (title: String?, id: String?)? {
        guard let auth = payload?["https://api.openai.com/auth"] as? [String: Any],
              let organizations = auth["organizations"] as? [[String: Any]] else {
            return nil
        }

        let defaultOrganization = organizations.first { organization in
            (organization["is_default"] as? Bool) == true
        }
        guard let organization = defaultOrganization ?? organizations.first else {
            return nil
        }

        return (organization["title"] as? String, organization["id"] as? String)
    }
}

public struct ClaudeIdentityReader {
    private let fileManager: FileManager
    private let homeDirectory: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func readIdentity(now: Date = Date()) -> AccountIdentity? {
        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else {
            return nil
        }

        let email = account["emailAddress"] as? String
        let displayName = account["displayName"] as? String
        let organization = account["organizationName"] as? String
        let organizationID = account["organizationUuid"] as? String
        let accountID = account["accountUuid"] as? String

        guard email != nil || displayName != nil || organization != nil || accountID != nil else {
            return nil
        }

        return AccountIdentity(
            email: email,
            displayName: displayName,
            organization: organization,
            organizationID: organizationID,
            accountID: accountID,
            source: .claudeCodeUsage,
            updatedAt: now
        )
    }
}
