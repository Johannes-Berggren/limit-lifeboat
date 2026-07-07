import Foundation
import XCTest
@testable import LLMUsageMonitorCore

final class ClaudeAccountUsageServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testActiveProfileUsesLiveTokenWithoutRefreshing() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(accessToken: "live-token", expiresAt: now.addingTimeInterval(3600))
        store.stored[profile.id] = makeCredentials(accessToken: "stored-token", expiresAt: now.addingTimeInterval(3600))
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        let snapshot = try await service.fetchSnapshot(for: profile, isActiveCLI: true, now: now)

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer live-token")
        XCTAssertEqual(snapshot.windows.first?.id, "session")
        XCTAssertEqual(snapshot.source, "Anthropic usage API")
    }

    func testInactiveProfileUsesStoredToken() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(accessToken: "live-token", expiresAt: now.addingTimeInterval(3600))
        store.stored[profile.id] = makeCredentials(accessToken: "stored-token", expiresAt: now.addingTimeInterval(3600))
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)

        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stored-token")
    }

    func testExpiredTokenIsRefreshedAndPersisted() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].url, ClaudeOAuthConstants.tokenEndpoint)
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertNil(store.live, "An inactive profile's refresh must not touch the live keychain item")
    }

    func testActiveProfileRefreshWritesBackToLiveItem() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(for: profile, isActiveCLI: true, now: now)

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
    }

    func testUnauthorizedTriggersExactlyOneRefreshRetry() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "revoked",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [
            (Data("{}".utf8), 401),
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)

        XCTAssertEqual(http.requests.count, 3)
        XCTAssertEqual(http.requests[1].url, ClaudeOAuthConstants.tokenEndpoint)
        XCTAssertEqual(http.requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testUnauthorizedAfterRetryThrowsUnauthorized() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "revoked",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [
            (Data("{}".utf8), 401),
            (refreshJSON(accessToken: "still-bad"), 200),
            (Data("{}".utf8), 401)
        ])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected unauthorized")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .unauthorized = error else {
                return XCTFail("Expected unauthorized, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRefreshFailureSurfacesAsRefreshFailed() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [(Data("nope".utf8), 400)])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected refreshFailed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMissingCredentialsThrowsNoCredentials() async {
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: FakeCredentialProvider())
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected noCredentials")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .noCredentials = error else {
                return XCTFail("Expected noCredentials, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Fixtures

    private let profile = AccountProfile(provider: .claude, label: "Claude")

    private var usageJSON: Data {
        Data(#"""
        {
          "limits": [
            {"kind": "session", "group": "session", "percent": 53, "severity": "normal", "resets_at": "2026-07-08T00:49:59.940321+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 8, "severity": "normal", "resets_at": "2026-07-14T15:59:59.940343+00:00", "scope": null, "is_active": false}
          ]
        }
        """#.utf8)
    }

    private func refreshJSON(accessToken: String) -> Data {
        Data(#"{"access_token":"\#(accessToken)","refresh_token":"refresh-2","expires_in":28800}"#.utf8)
    }

    private func makeCredentials(
        accessToken: String,
        refreshToken: String = "refresh-token",
        expiresAt: Date
    ) -> ClaudeOAuthCredentials {
        let json = Data(
            #"{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)","expiresAt":\#(Int(expiresAt.timeIntervalSince1970 * 1000))}"#.utf8
        )
        return ClaudeOAuthCredentials(claudeAiOauthJSON: json)!
    }

    private func makeService(http: ScriptedHTTPClient, credentials: FakeCredentialProvider) -> ClaudeAccountUsageService {
        ClaudeAccountUsageService(
            apiClient: ClaudeUsageAPIClient(httpClient: http),
            refresher: ClaudeOAuthTokenRefresher(httpClient: http),
            credentials: credentials
        )
    }
}

private final class FakeCredentialProvider: ClaudeOAuthCredentialProviding, @unchecked Sendable {
    var live: ClaudeOAuthCredentials?
    var stored: [UUID: ClaudeOAuthCredentials] = [:]

    func liveClaudeOAuthCredentials() -> ClaudeOAuthCredentials? {
        live
    }

    func writeLiveClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials) throws {
        live = credentials
    }

    func storedClaudeOAuthCredentials(for profileID: UUID) throws -> ClaudeOAuthCredentials? {
        stored[profileID]
    }

    func updateStoredClaudeOAuthCredentials(_ credentials: ClaudeOAuthCredentials, for profileID: UUID) throws {
        stored[profileID] = credentials
    }
}

/// Replays queued (body, status) pairs in order and records every request.
private final class ScriptedHTTPClient: HTTPClienting, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, Int)]

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
