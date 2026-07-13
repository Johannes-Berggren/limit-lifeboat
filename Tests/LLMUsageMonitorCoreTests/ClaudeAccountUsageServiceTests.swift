import Foundation
import Security
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

    func testUserInitiatedActiveRefreshWritesBackToLiveItem() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .userInitiated
        )

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
    }

    func testBackgroundActiveRefreshNeverMutatesLiveLogin() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(store.live?.accessToken, "stale")
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

    func testLiveItemChangedDuringRefreshIsNotOverwritten() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        // The user switches accounts while the token refresh is in flight:
        // the live item now belongs to another profile.
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.live = self.makeCredentials(
                    accessToken: "other-account",
                    expiresAt: self.now.addingTimeInterval(3600)
                )
            }
        }

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .userInitiated
        )

        XCTAssertEqual(
            store.live?.accessToken, "other-account",
            "The old profile's refreshed tokens must not overwrite the new owner's live item"
        )
        XCTAssertEqual(
            store.stored[profile.id]?.accessToken, "fresh",
            "The refreshed tokens still belong in the profile's stored snapshot"
        )
    }

    func testEmptyWindowsResponseThrowsInsteadOfOverwritingSnapshot() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(accessToken: "token", expiresAt: now.addingTimeInterval(3600))
        let http = ScriptedHTTPClient(responses: [(Data(#"{"limits":[]}"#.utf8), 200)])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected transport error for a 2xx body without windows")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .transport = error else {
                return XCTFail("Expected transport, got \(error)")
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

    func testKeychainDeniedSurfacesAsKeychainLocked() async {
        let store = FakeCredentialProvider()
        store.storedError = CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected keychainLocked")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testActiveLiveKeychainDeniedSurfacesAsKeychainLocked() async {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(errSecInteractionNotAllowed)
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: true, now: now)
            XCTFail("Expected keychainLocked")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testCredentialAccessModePropagatesToCredentialProvider() async {
        let store = FakeCredentialProvider()
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: store)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Expected noCredentials")
        } catch {
            XCTAssertEqual(store.accessModes, [.userInitiated])
        }
    }

    /// A decode failure (not a denial) is not a locked keychain — it leaves the
    /// account with no usable token this cycle, surfacing as noCredentials.
    func testKeychainDecodeErrorFallsBackToNoCredentials() async {
        let store = FakeCredentialProvider()
        store.storedError = CredentialStoreError.decodeFailed(underlying: nil)
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: store)
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
    var liveError: Error?
    var stored: [UUID: ClaudeOAuthCredentials] = [:]
    /// When set, `storedClaudeOAuthCredentials` throws it — used to simulate a
    /// locked/denied Keychain or an unreadable snapshot.
    var storedError: Error?
    private(set) var accessModes: [CredentialAccessMode] = []

    func liveClaudeOAuthCredentials(accessMode: CredentialAccessMode) throws -> ClaudeOAuthCredentials? {
        accessModes.append(accessMode)
        if let liveError {
            throw liveError
        }
        return live
    }

    func writeLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws {
        accessModes.append(accessMode)
        live = credentials
    }

    func replaceLiveClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        guard live?.accessToken == expectedAccessToken else { return false }
        live = credentials
        return true
    }

    func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeOAuthCredentials? {
        accessModes.append(accessMode)
        if let storedError {
            throw storedError
        }
        return stored[profileID]
    }

    func updateStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws {
        accessModes.append(accessMode)
        stored[profileID] = credentials
    }

    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        guard stored[profileID]?.accessToken == expectedAccessToken else { return false }
        stored[profileID] = credentials
        return true
    }
}

/// Replays queued (body, status) pairs in order and records every request.
/// `onRequest` lets a test mutate state "while a request is in flight".
private final class ScriptedHTTPClient: HTTPClienting, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, Int)]
    var onRequest: ((URLRequest) -> Void)?

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onRequest?(request)
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
