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

/// Who a Codex login belongs to plus its plan tier, decoded from
/// `~/.codex/auth.json` — mirrors `ClaudeAPIAccountInfo` so the app treats
/// both providers' account info the same way.
public struct CodexAccountInfo: Equatable, Sendable {
    public var identity: AccountIdentity?
    /// Short human tier ("Pro", "Plus", "Team"…); nil when no plan signal.
    public var planLabel: String?

    public init(identity: AccountIdentity? = nil, planLabel: String? = nil) {
        self.identity = identity
        self.planLabel = planLabel
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
        accountInfo(now: now)?.identity
    }

    /// The live account info from the CLI's current `~/.codex/auth.json`.
    public func accountInfo(now: Date = Date()) -> CodexAccountInfo? {
        let authURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path),
              let data = try? Data(contentsOf: authURL) else {
            return nil
        }
        return Self.accountInfo(fromAuthJSON: data, now: now)
    }

    /// Decodes identity + plan tier from an `auth.json` blob. Static and pure so
    /// it works equally on the live file and on the copy captured into an
    /// inactive account's stored snapshot (no CLI launch, no network).
    public static func accountInfo(fromAuthJSON data: Data, now: Date = Date()) -> CodexAccountInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else {
            return nil
        }

        let accountID = tokens["account_id"] as? String
        let payload = (tokens["id_token"] as? String).flatMap(decodeJWTPayload)
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let email = payload?["email"] as? String
        let name = payload?["name"] as? String
        let organization = (payload?["organization"] as? String)
            ?? (payload?["org"] as? String)
            ?? (payload?["workspace"] as? String)
            ?? defaultOrganizationTitle(from: auth)
        let planLabel = planLabel(
            forPlanType: (auth?["chatgpt_plan_type"] as? String) ?? (tokens["plan_type"] as? String)
        )

        var identity: AccountIdentity?
        if email != nil || name != nil || organization != nil || accountID != nil {
            identity = AccountIdentity(
                email: email,
                displayName: name,
                organization: organization,
                accountID: accountID,
                source: .codexIDToken,
                updatedAt: now
            )
        }

        guard identity != nil || planLabel != nil else {
            return nil
        }
        return CodexAccountInfo(identity: identity, planLabel: planLabel)
    }

    /// Normalizes ChatGPT's `chatgpt_plan_type` onto a short human tier label,
    /// mirroring `ClaudeUsageAPIClient.planLabel`. Pure and directly testable.
    public static func planLabel(forPlanType raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "free":
            return "Free"
        case "go":
            return "Go"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "prolite":
            return "Pro Lite"
        case "team":
            return "Team"
        case "business", "self_serve_business_usage_based":
            return "Business"
        case "enterprise", "enterprise_cbp_usage_based":
            return "Enterprise"
        case "edu":
            return "Edu"
        case "unknown":
            return nil
        default:
            return raw.capitalized
        }
    }

    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
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

    private static func defaultOrganizationTitle(from auth: [String: Any]?) -> String? {
        guard let organizations = auth?["organizations"] as? [[String: Any]] else {
            return nil
        }

        let defaultOrganization = organizations.first { organization in
            (organization["is_default"] as? Bool) == true
        }
        let organization = defaultOrganization ?? organizations.first

        return organization?["title"] as? String
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
              let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return Self.identity(fromClaudeJSON: data, now: now)
    }

    public static func identity(fromClaudeJSON data: Data, now: Date = Date()) -> AccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }

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
