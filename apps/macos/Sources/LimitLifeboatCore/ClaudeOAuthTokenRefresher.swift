import Foundation

public enum ClaudeOAuthError: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    case missingRefreshToken
    case refreshTokenExpired
    case refreshRejected(status: Int, body: String)
    /// Rotation is deliberately deferred for this credential. This is a
    /// recoverable policy/concurrency outcome, not proof that login expired.
    case refreshSuppressed(reason: String)
    case network(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "The stored Claude credentials have no refresh token; sign in with claude auth login again."
        case .refreshTokenExpired:
            return "The stored Claude login has expired; sign in with claude auth login again."
        case .refreshRejected(let status, let body):
            let detail = body.isEmpty ? "no response body" : "\(body.utf8.count) response bytes"
            return "Claude token refresh was rejected with status \(status) (\(detail))."
        case .refreshSuppressed(let reason):
            return reason
        case .network(let underlying):
            return "Claude token refresh failed to reach the server (\(underlying.localizedDescription))."
        case .malformedResponse:
            return "Claude token refresh returned a response in an unexpected format."
        }
    }

    /// Keep accidental string interpolation and debug logging on the same
    /// redacted path as LocalizedError; refresh rejection bodies can contain
    /// credential material.
    public var description: String {
        errorDescription ?? "Claude OAuth error."
    }

    public var debugDescription: String { description }

    /// Whether retrying the same saved refresh token cannot recover the
    /// account. Network/server/protocol failures remain retryable; only a
    /// missing token or an authentication-specific rejection asks the user to
    /// sign in again.
    public var requiresLogin: Bool {
        switch self {
        case .missingRefreshToken, .refreshTokenExpired:
            return true
        case .refreshRejected(_, let body):
            guard let code = Self.rejectionCode(in: body) else { return false }
            return Self.terminalRejectionCodes.contains(code)
        case .refreshSuppressed, .network, .malformedResponse:
            return false
        }
    }

    /// The OAuth error code returned by the token endpoint, when the body is a
    /// structured OAuth error response. The raw body remains private to the
    /// workflow and is never included in a localized description.
    public var rejectionCode: String? {
        guard case .refreshRejected(_, let body) = self else { return nil }
        return Self.rejectionCode(in: body)
    }

    private static let terminalRejectionCodes: Set<String> = [
        "invalid_grant",
        "invalid_refresh_token",
        "refresh_token_expired",
        "token_invalidated",
        "token_revoked"
    ]

    private static func rejectionCode(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = object["error"] as? String else {
            return nil
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty ? nil : code
    }
}

/// Exchanges a refresh token for a fresh access token at Claude Code's own
/// OAuth endpoint. The result carries an updated `rawClaudeAiOauth` (old JSON
/// with only the token fields replaced) so unknown fields survive the write
/// back to the keychain.
public struct ClaudeOAuthTokenRefresher: Sendable {
    private let httpClient: HTTPClienting

    public init(httpClient: HTTPClienting = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func refresh(_ credentials: ClaudeOAuthCredentials, now: Date = Date()) async throws -> ClaudeOAuthCredentials {
        guard let refreshToken = Self.nonemptyString(credentials.refreshToken) else {
            throw ClaudeOAuthError.missingRefreshToken
        }
        guard !credentials.isLoginExpired(asOf: now) else {
            throw ClaudeOAuthError.refreshTokenExpired
        }

        var request = URLRequest(url: ClaudeOAuthConstants.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": credentials.clientID ?? ClaudeOAuthConstants.clientID
            ],
            options: [.sortedKeys]
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await httpClient.send(request)
        } catch {
            throw ClaudeOAuthError.network(error)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ClaudeOAuthError.refreshRejected(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = Self.nonemptyString(object["access_token"]) else {
            throw ClaudeOAuthError.malformedResponse
        }

        // The endpoint may rotate the refresh token; keep the old one when it
        // does not.
        let rotatedRefreshToken: String
        if object.keys.contains("refresh_token") {
            guard let value = Self.nonemptyString(object["refresh_token"]) else {
                throw ClaudeOAuthError.malformedResponse
            }
            rotatedRefreshToken = value
        } else {
            rotatedRefreshToken = refreshToken
        }

        let expiresAt: Date?
        if object.keys.contains("expires_in") {
            guard let expires = Self.expirationDate(
                after: object["expires_in"],
                now: now
            ) else {
                throw ClaudeOAuthError.malformedResponse
            }
            expiresAt = expires
        } else {
            // A missing lifetime means "unknown", not "reuse the already
            // expired timestamp". Removing it also prevents an immediate
            // second refresh of this newly-issued access token.
            expiresAt = nil
        }

        let refreshTokenExpiresAt: Date?
        if object.keys.contains("refresh_token_expires_in") {
            guard let expires = Self.expirationDate(
                after: object["refresh_token_expires_in"],
                now: now
            ) else {
                throw ClaudeOAuthError.malformedResponse
            }
            refreshTokenExpiresAt = expires
        } else {
            // Claude's fixed login expiry survives responses which do not
            // repeat refresh_token_expires_in.
            refreshTokenExpiresAt = credentials.refreshTokenExpiresAt
        }

        let updatedRaw = updatedRawClaudeAiOauth(
            from: credentials.rawClaudeAiOauth,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        )
        guard let updated = ClaudeOAuthCredentials(claudeAiOauthJSON: updatedRaw) else {
            throw ClaudeOAuthError.malformedResponse
        }
        return updated
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    private static func expirationDate(after value: Any?, now: Date) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let duration = number.doubleValue
        guard duration.isFinite, duration > 0 else { return nil }
        let epochSeconds = now.timeIntervalSince1970 + duration
        let epochMilliseconds = epochSeconds * 1_000
        guard epochSeconds.isFinite,
              epochMilliseconds.isFinite,
              epochMilliseconds >= Double(Int64.min),
              epochMilliseconds < Double(Int64.max) else {
            return nil
        }
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// The old `claudeAiOauth` JSON with only accessToken/refreshToken/
    /// expiresAt (epoch milliseconds) replaced, so fields this app does not
    /// model round-trip untouched.
    private func updatedRawClaudeAiOauth(
        from raw: Data,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?,
        refreshTokenExpiresAt: Date?
    ) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        object["accessToken"] = accessToken
        object["refreshToken"] = refreshToken
        if let expiresAt {
            object["expiresAt"] = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        } else {
            object.removeValue(forKey: "expiresAt")
        }
        if let refreshTokenExpiresAt {
            object["refreshTokenExpiresAt"] = Int64(
                (refreshTokenExpiresAt.timeIntervalSince1970 * 1000).rounded()
            )
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? raw
    }
}
