import Foundation

/// Endpoints and client constants for Claude Code's OAuth flow, verified
/// against the Claude Code 2.1.202 binary and live calls.
public enum ClaudeOAuthConstants {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
}

/// The `claudeAiOauth` object inside the "Claude Code-credentials" keychain
/// item. `rawClaudeAiOauth` keeps the whole object as JSON so writing back to
/// the keychain never drops fields this struct does not model.
public struct ClaudeOAuthCredentials: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// The item stores `expiresAt` in epoch milliseconds; this is the same
    /// instant as a `Date`.
    public var expiresAt: Date?
    /// The fixed lifetime of the login created by `/login`, also stored in
    /// epoch milliseconds. Refreshing the access token does not extend it;
    /// the user must renew the login before this instant.
    public var refreshTokenExpiresAt: Date?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?
    /// Present only when the item carries its own client id; refresh calls
    /// fall back to `ClaudeOAuthConstants.clientID` otherwise.
    public var clientID: String?
    /// The `claudeAiOauth` object re-serialized verbatim, for lossless
    /// round-trips through refresh and keychain writes.
    public var rawClaudeAiOauth: Data

    public init?(claudeAiOauthJSON: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: claudeAiOauthJSON) as? [String: Any],
              let accessToken = object["accessToken"] as? String,
              !accessToken.isEmpty,
              let raw = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }

        self.accessToken = accessToken
        self.refreshToken = object["refreshToken"] as? String
        self.expiresAt = (object["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        self.refreshTokenExpiresAt = (object["refreshTokenExpiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        self.scopes = object["scopes"] as? [String] ?? []
        self.subscriptionType = object["subscriptionType"] as? String
        self.rateLimitTier = object["rateLimitTier"] as? String
        self.clientID = (object["clientId"] as? String) ?? (object["client_id"] as? String)
        self.rawClaudeAiOauth = raw
    }

    /// Pulls the credentials out of the full keychain item JSON, leaving the
    /// machine-level `mcpOAuth` sibling behind.
    public static func extract(fromKeychainItemJSON data: Data) -> ClaudeOAuthCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let claudeAiOauth = object["claudeAiOauth"] as? [String: Any],
              let json = try? JSONSerialization.data(withJSONObject: claudeAiOauth, options: [.sortedKeys]) else {
            return nil
        }
        return ClaudeOAuthCredentials(claudeAiOauthJSON: json)
    }

    /// True when the access token has expired or is about to. Items without
    /// an expiry never count as expired; the API rejects them if they are.
    public func isExpired(asOf now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else {
            return false
        }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    public func isLoginExpired(asOf now: Date = Date()) -> Bool {
        guard let refreshTokenExpiresAt else {
            return false
        }
        return now >= refreshTokenExpiresAt
    }

    /// Orders two captures from the same account without inspecting their
    /// secret bytes. A renewed login wins first, then a later access-token
    /// generation. This lets reconciliation keep a rotated stored credential
    /// instead of replacing it with an older live Keychain value.
    func isFresher(than other: ClaudeOAuthCredentials) -> Bool {
        let ownLoginExpiry = refreshTokenExpiresAt ?? .distantPast
        let otherLoginExpiry = other.refreshTokenExpiresAt ?? .distantPast
        if ownLoginExpiry != otherLoginExpiry {
            return ownLoginExpiry > otherLoginExpiry
        }

        let ownAccessExpiry = expiresAt ?? .distantPast
        let otherAccessExpiry = other.expiresAt ?? .distantPast
        return ownAccessExpiry > otherAccessExpiry
    }
}
