import Foundation

public enum ClaudeOAuthError: Error, LocalizedError {
    case missingRefreshToken
    case refreshRejected(status: Int, body: String)
    case network(Error)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "The stored Claude credentials have no refresh token; sign in with claude auth login again."
        case .refreshRejected(let status, let body):
            let detail = body.isEmpty ? "no response body" : body
            return "Claude token refresh was rejected with status \(status) (\(detail))."
        case .network(let underlying):
            return "Claude token refresh failed to reach the server (\(underlying.localizedDescription))."
        case .malformedResponse:
            return "Claude token refresh returned a response in an unexpected format."
        }
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
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeOAuthError.missingRefreshToken
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
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty else {
            throw ClaudeOAuthError.malformedResponse
        }

        // The endpoint may rotate the refresh token; keep the old one when it
        // does not.
        let rotatedRefreshToken = (object["refresh_token"] as? String) ?? refreshToken
        let expiresAt = (object["expires_in"] as? NSNumber).map {
            now.addingTimeInterval($0.doubleValue)
        }

        let updatedRaw = updatedRawClaudeAiOauth(
            from: credentials.rawClaudeAiOauth,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: expiresAt
        )
        guard let updated = ClaudeOAuthCredentials(claudeAiOauthJSON: updatedRaw) else {
            throw ClaudeOAuthError.malformedResponse
        }
        return updated
    }

    /// The old `claudeAiOauth` JSON with only accessToken/refreshToken/
    /// expiresAt (epoch milliseconds) replaced, so fields this app does not
    /// model round-trip untouched.
    private func updatedRawClaudeAiOauth(
        from raw: Data,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?
    ) -> Data {
        var object = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        object["accessToken"] = accessToken
        object["refreshToken"] = refreshToken
        if let expiresAt {
            object["expiresAt"] = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? raw
    }
}
