import Foundation
import Security
import XCTest
@testable import LimitLifeboatCore

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

    func testPreloadedStoredRecordSkipsCredentialProviderRead() async throws {
        let store = FakeCredentialProvider()
        store.storedError = CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        let preloaded = makeCredentials(
            accessToken: "preloaded-token",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let result = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            storedRecord: makeStoredRecord(credentials: preloaded),
            now: now,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(store.storedReadCount, 0)
        XCTAssertEqual(
            http.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer preloaded-token"
        )
        XCTAssertEqual(result.credentials.accessToken, "preloaded-token")
        XCTAssertEqual(result.snapshot.windows.first?.id, "session")
    }

    func testPreloadedStoredRecordReturnsPersistedRotatedGenerationWithoutReloading() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        // The fake compare-and-swap owner contains the same generation, but
        // the service must not call its read API during resolution.
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let result = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            storedRecord: makeStoredRecord(credentials: stale),
            now: now,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(store.storedReadCount, 0)
        XCTAssertEqual(store.preloadedStoredReplaceCount, 1)
        XCTAssertEqual(result.credentials.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 2)
    }

    func testPreloadedFailureCarriesPersistedRotationForSwitchCache() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (Data("{}".utf8), 200)
        ])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                storedRecord: makeStoredRecord(credentials: stale),
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Expected malformed usage to fail after rotation")
        } catch let error as ClaudeAccountUsagePreflightError {
            guard case .transport = error.underlying else {
                return XCTFail("Expected transport failure, got \(error.underlying)")
            }
            XCTAssertEqual(error.latestPersistedCredentials?.accessToken, "fresh")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.storedReadCount, 0)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 2)
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

    func testActiveLiveWriteFailureCannotBeHiddenByStoredPersistence() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.liveLocation = keychainLocation(reference: "failed-write-original")
        store.stored[profile.id] = stale
        store.liveReplaceError = ClaudeCodeCredentialsKeychainError.keychainError(
            errSecInteractionNotAllowed
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        let service = makeService(http: http, credentials: store)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Expected the live write failure to abort active refresh")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .liveCredentialAccessDenied(
                error: let underlying,
                item: let item
            ) = error else {
                return XCTFail("Expected a typed live-item access denial, got \(error)")
            }
            XCTAssertEqual(underlying.credentialAccessDisposition, .interactionRequired)
            XCTAssertEqual(item, store.liveLocation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(http.requests.count, 1, "Usage must not run after the live write throws")
        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(
            store.stored[profile.id]?.accessToken,
            "fresh",
            "The safely written recovery copy should remain available for an explicit repair"
        )

        store.liveReplaceError = nil
        store.liveLocation = keychainLocation(reference: "authorized-replacement")
        store.storedError = CredentialStoreError.keychainError(
            errSecInteractionNotAllowed
        )
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("A transient stored denial must retain the repair marker")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        store.storedError = nil
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Scheduled usage must stay blocked until the live item is repaired")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(http.requests.count, 1)

        _ = try? await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .userInitiated
        )
        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 2, "The explicit repair may resume usage once")
    }

    func testBackgroundActiveExpiredTokenDefersWithoutNetworkOrMutation() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Expected background rotation to be deferred")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .interactiveRefreshRequired = error else {
                return XCTFail("Expected interactiveRefreshRequired, got \(error)")
            }
        }

        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testBackgroundActiveUnauthorizedDoesNotSpendRefreshToken() async throws {
        let store = FakeCredentialProvider()
        let current = makeCredentials(
            accessToken: "rejected",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600)
        )
        store.live = current
        store.stored[profile.id] = current
        let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 401)])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Expected background refresh to require explicit Retry")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .interactiveRefreshRequired = error else {
                return XCTFail("Expected interactiveRefreshRequired, got \(error)")
            }
        }

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(store.live?.refreshToken, "refresh-1")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "refresh-1")
    }

    func testUserInitiatedActiveRetryRepairsLiveFromFresherStoredCredential() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "stale-live",
            refreshToken: "stale-refresh",
            expiresAt: now.addingTimeInterval(3600)
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "fresh-stored",
            refreshToken: "fresh-refresh",
            expiresAt: now.addingTimeInterval(7200)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .userInitiated
        )

        XCTAssertEqual(
            http.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-stored"
        )
        XCTAssertEqual(store.live?.accessToken, "fresh-stored")
        XCTAssertEqual(store.live?.refreshToken, "fresh-refresh")
        XCTAssertEqual(http.requests.count, 1, "Repairing a valid stored generation must not rotate again")
    }

    func testAccessibleLiveStoredSplitRequiresExplicitRepairAfterRelaunch() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "stale-live",
            refreshToken: "stale-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "fresh-recovery",
            refreshToken: "fresh-refresh",
            expiresAt: now.addingTimeInterval(7_200)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        let service = makeService(http: http, credentials: store)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Scheduled usage must not hide an accessible live/stored split")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .interactiveRefreshRequired = error else {
                return XCTFail("Expected interactiveRefreshRequired, got \(error)")
            }
        }
        XCTAssertTrue(http.requests.isEmpty)

        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .userInitiated
        )
        XCTAssertEqual(store.live?.accessToken, "fresh-recovery")
        XCTAssertEqual(http.requests.count, 1)
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

    func testLiveItemChangedDuringRefreshIsNotOverwritten() async {
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
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("A live CAS conflict must abort the refreshed usage request")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(
            store.live?.accessToken, "other-account",
            "The old profile's refreshed tokens must not overwrite the new owner's live item"
        )
        XCTAssertEqual(
            store.stored[profile.id]?.accessToken, "fresh",
            "The refreshed tokens still belong in the profile's stored snapshot"
        )
        XCTAssertEqual(http.requests.count, 1)
    }

    func testSameTokenItemReplacementDuringRefreshIsNeverMutated() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let originalLocation = keychainLocation(reference: "original")
        let replacementLocation = keychainLocation(reference: "replacement")
        store.live = stale
        store.liveLocation = originalLocation
        store.stored[profile.id] = stale
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.liveLocation = replacementLocation
            }
        }

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Expected replacement of the pinned item to fail closed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.liveLocation, replacementLocation)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testFalseLiveCASWithStaleTokenCannotReportUsageSuccess() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.liveReplaceResultOverride = false
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Expected false live CAS to abort")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 1)
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

    func testActiveLiveKeychainDeniedUsesValidStoredCredentialWithoutLiveMutation() async throws {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(errSecInteractionNotAllowed)
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(
            http.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer stored-token"
        )
        XCTAssertEqual(store.liveReadCount, 1)
        XCTAssertEqual(store.storedReadCount, 1)
        XCTAssertEqual(store.liveReplaceCount, 0)
    }

    func testLiveDenialIsReportedOnceWhileStoredCredentialServesUsage() async throws {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(
            errSecInteractionNotAllowed
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        var dispositions: [CredentialAccessDisposition] = []

        _ = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive,
            liveCredentialAccessDenied: { dispositions.append($0) }
        )

        XCTAssertEqual(dispositions, [.interactionRequired])
        XCTAssertEqual(store.liveReadCount, 1)
        XCTAssertEqual(store.liveReplaceCount, 0)
    }

    func testKnownDeniedPolicySkipsLiveReadAndUsesStoredCredential() async throws {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(
            errSecInteractionNotAllowed
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        var callbackCount = 0

        _ = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive,
            liveCredentialReadPolicy: .knownDenied,
            liveCredentialAccessDenied: { _ in callbackCount += 1 }
        )

        XCTAssertEqual(store.liveReadCount, 0)
        XCTAssertEqual(store.storedReadCount, 1)
        XCTAssertEqual(store.liveReplaceCount, 0)
        XCTAssertEqual(callbackCount, 0)
        XCTAssertEqual(
            http.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer stored-token"
        )
    }

    func testPreloadedLiveRecordSkipsProviderRead() async throws {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(
            errSecInteractionNotAllowed
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "older-stored-token",
            expiresAt: now.addingTimeInterval(1_800)
        )
        let preloaded = LiveClaudeOAuthCredentialRecord(
            credentials: makeCredentials(
                accessToken: "preloaded-live-token",
                expiresAt: now.addingTimeInterval(3_600)
            ),
            itemLocation: keychainLocation(reference: "preloaded")
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive,
            liveCredentialReadPolicy: .preloaded(preloaded)
        )

        XCTAssertEqual(store.liveReadCount, 0)
        XCTAssertEqual(store.liveReplaceCount, 0)
        XCTAssertEqual(
            http.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer preloaded-live-token"
        )
    }

    func testResolvedCredentialIsAvailableToPromptFreeFallbackAfterTransportFailure() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [(Data("server error".utf8), 500)])
        var resolved: ClaudeOAuthCredentials?

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .nonInteractive,
                credentialDidResolve: { resolved = $0 }
            )
            XCTFail("Expected transport failure")
        } catch {
            XCTAssertEqual(resolved?.accessToken, "stored-token")
            XCTAssertEqual(store.storedReadCount, 1)
            XCTAssertEqual(store.liveReadCount, 0)
        }
    }

    func testDuplicateLiveItemsNeverFallBackToValidStoredCredential() async {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.duplicateLiveItems([
            keychainLocation(reference: "duplicate-a"),
            keychainLocation(reference: "duplicate-b")
        ])
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Duplicate live items must fail closed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialUnavailable = error else {
                return XCTFail("Expected credentialUnavailable, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.storedReadCount, 0)
    }

    func testExplicitRetryDoesNotRotateExpiredStoredCredentialWhenActiveLiveItemIsDenied() async {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(errSecInteractionNotAllowed)
        store.stored[profile.id] = makeCredentials(
            accessToken: "expired-stored",
            refreshToken: "must-not-be-spent",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive,
                userExplicitlyRequestedRefresh: true
            )
            XCTFail("Expected denied live item to block rotation")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "must-not-be-spent")
        XCTAssertEqual(store.liveReplaceCount, 0)
    }

    func testExplicitRetryDoesNotRotateRejectedStoredCredentialWhenActiveLiveItemIsDenied() async {
        let store = FakeCredentialProvider()
        store.liveError = ClaudeCodeCredentialsKeychainError.keychainError(errSecInteractionNotAllowed)
        store.stored[profile.id] = makeCredentials(
            accessToken: "rejected-stored",
            refreshToken: "must-not-be-spent",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 401)])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive,
                userExplicitlyRequestedRefresh: true
            )
            XCTFail("Expected denied live item to block rotation")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .keychainLocked = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, ClaudeOAuthConstants.usageEndpoint)
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "must-not-be-spent")
        XCTAssertEqual(store.liveReplaceCount, 0)
    }

    func testActiveStoredKeychainDeniedUsesValidLiveCredential() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "live-token",
            expiresAt: now.addingTimeInterval(3600)
        )
        store.storedError = CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(
            http.requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer live-token"
        )
        XCTAssertEqual(store.liveReadCount, 1)
        XCTAssertEqual(store.storedReadCount, 1)
    }

    func testRotatedCredentialMustBePersistedBeforeUsageReportsSuccess() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.storedReplaceResultOverride = false
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected the failed persistence to fail the refresh")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed(let underlying) = error,
                  let oauthError = underlying as? ClaudeOAuthError,
                  oauthError.requiresLogin else {
                return XCTFail("Expected a terminal refresh persistence failure, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(http.requests.count, 1, "Usage must not be fetched with an unsaved rotated token")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")

        // The old refresh token may have been consumed. A scheduled cycle
        // must not spend it again after persistence failed.
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected the exact credential to remain suppressed")
        } catch {
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testTerminalRefreshFailureIsSuppressedUntilExplicitRetry() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "invalid-refresh",
            expiresAt: now.addingTimeInterval(-60)
        )
        let rejected = Data(#"{"error":"invalid_grant"}"#.utf8)
        let http = ScriptedHTTPClient(responses: [(rejected, 400), (rejected, 400)])
        let service = makeService(http: http, credentials: store)

        for _ in 0..<2 {
            do {
                _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
                XCTFail("Expected refresh failure")
            } catch {
                // Both the original failure and its suppressed replay are
                // visible, but only the first is allowed onto the network.
            }
        }
        XCTAssertEqual(http.requests.count, 1)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Expected explicit retry to reach the scripted rejection")
        } catch {
            XCTAssertEqual(http.requests.count, 2)
        }
    }

    func testChangedCredentialClearsTerminalRefreshSuppressionKey() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale-1",
            refreshToken: "invalid-refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let rejected = Data(#"{"error":"invalid_grant"}"#.utf8)
        let http = ScriptedHTTPClient(responses: [(rejected, 400), (rejected, 400)])
        let service = makeService(http: http, credentials: store)

        _ = try? await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale-2",
            refreshToken: "invalid-refresh-2",
            expiresAt: now.addingTimeInterval(-60)
        )
        _ = try? await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)

        XCTAssertEqual(http.requests.count, 2)
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

    private func makeStoredRecord(
        credentials: ClaudeOAuthCredentials
    ) -> StoredCredentialRecord {
        let snapshot = CredentialSnapshot(
            provider: .claude,
            capturedAt: now,
            items: [
                CredentialSnapshotItem(
                    relativePath: "keychain/Claude Code-credentials",
                    kind: .keychainJSONFields,
                    contents: credentials.rawClaudeAiOauth,
                    posixPermissions: nil
                )
            ]
        )
        return StoredCredentialRecord(
            snapshot: snapshot,
            summary: StoredCredentialSummary(
                provider: .claude,
                fingerprint: CredentialFingerprint.make(for: snapshot),
                isRestorable: true,
                claudeRefreshTokenExpiresAt: credentials.refreshTokenExpiresAt
            )
        )
    }

    private func keychainLocation(reference: String) -> ClaudeKeychainItemLocation {
        ClaudeKeychainItemLocation(
            serviceName: ClaudeCodeCredentialsKeychain.serviceName,
            accountName: "test",
            keychainPath: "/tmp/disposable.keychain-db",
            persistentReference: Data(reference.utf8),
            creationDate: now,
            modificationDate: now
        )
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
    var liveLocation: ClaudeKeychainItemLocation?
    var liveError: Error?
    var stored: [UUID: ClaudeOAuthCredentials] = [:]
    /// When set, `storedClaudeOAuthCredentials` throws it — used to simulate a
    /// locked/denied Keychain or an unreadable snapshot.
    var storedError: Error?
    var storedReplaceResultOverride: Bool?
    var liveReplaceError: Error?
    var liveReplaceResultOverride: Bool?
    private(set) var accessModes: [CredentialAccessMode] = []
    private(set) var liveReadCount = 0
    private(set) var storedReadCount = 0
    private(set) var preloadedStoredReplaceCount = 0
    private(set) var liveReplaceCount = 0

    func liveClaudeOAuthCredentialRecord(
        accessMode: CredentialAccessMode
    ) throws -> LiveClaudeOAuthCredentialRecord? {
        accessModes.append(accessMode)
        liveReadCount += 1
        if let liveError {
            throw liveError
        }
        return live.map {
            LiveClaudeOAuthCredentialRecord(
                credentials: $0,
                itemLocation: liveLocation
            )
        }
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
        at expectedItemLocation: ClaudeKeychainItemLocation?,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        liveReplaceCount += 1
        if let liveReplaceError {
            throw liveReplaceError
        }
        guard expectedItemLocation == liveLocation else { return false }
        guard live?.accessToken == expectedAccessToken else { return false }
        if let liveReplaceResultOverride {
            return liveReplaceResultOverride
        }
        live = credentials
        return true
    }

    func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeOAuthCredentials? {
        accessModes.append(accessMode)
        storedReadCount += 1
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
        if let storedReplaceResultOverride {
            return storedReplaceResultOverride
        }
        stored[profileID] = credentials
        return true
    }

    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifAccessTokenMatches expectedAccessToken: String,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        accessModes.append(accessMode)
        preloadedStoredReplaceCount += 1
        guard stored[profileID]?.accessToken == expectedAccessToken else { return nil }
        if let storedReplaceResultOverride, !storedReplaceResultOverride {
            return nil
        }
        stored[profileID] = credentials
        var snapshot = storedRecord.snapshot
        guard let index = snapshot.items.firstIndex(where: { $0.kind == .keychainJSONFields }) else {
            return nil
        }
        snapshot.items[index].contents = credentials.rawClaudeAiOauth
        return StoredCredentialRecord(
            snapshot: snapshot,
            summary: StoredCredentialSummary(
                provider: .claude,
                fingerprint: CredentialFingerprint.make(for: snapshot),
                isRestorable: true,
                claudeRefreshTokenExpiresAt: credentials.refreshTokenExpiresAt
            ),
            storeRevision: storedRecord.storeRevision
        )
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
