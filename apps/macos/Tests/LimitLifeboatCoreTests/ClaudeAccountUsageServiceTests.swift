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

    func testPreloadedStoredRecordRevalidatesThenReturnsPersistedRotatedGeneration() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        // Resolution consumes the preloaded value. Immediately before the
        // token exchange, the leased workflow revalidates its current owner.
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
            accessMode: .nonInteractive,
            rotationIntent: .userInitiatedSwitch
        )

        XCTAssertEqual(store.storedReadCount, 1)
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
                accessMode: .nonInteractive,
                rotationIntent: .userInitiatedSwitch
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

        XCTAssertEqual(store.storedReadCount, 1)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 2)
    }

    func testPreloadedSwitchTargetChangeIsDetectedBeforeTokenExchange() async {
        let store = FakeCredentialProvider()
        let preloaded = makeCredentials(
            accessToken: "stale",
            refreshToken: "must-not-be-spent",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "newer-owner",
            refreshToken: "newer-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                storedRecord: makeStoredRecord(credentials: preloaded),
                now: now,
                rotationIntent: .userInitiatedSwitch
            )
            XCTFail("Expected the stale switch record to be deferred")
        } catch let error as ClaudeAccountUsagePreflightError {
            guard case .rotationDeferred = error.underlying else {
                return XCTFail("Expected rotationDeferred, got \(error.underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "newer-owner")
    }

    func testSameAccessTokenExternalLiveGenerationWinsBeforeExchange() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "same-access-token",
            refreshToken: "stale-refresh-chain",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: [
                "refreshTokenExpiresAt": Int(
                    now.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000
                )
            ]
        )
        let external = makeCredentials(
            accessToken: "same-access-token",
            refreshToken: "external-refresh-chain",
            expiresAt: now.addingTimeInterval(3_600),
            additionalFields: [
                "refreshTokenExpiresAt": Int(
                    now.addingTimeInterval(5 * 86_400).timeIntervalSince1970 * 1_000
                )
            ]
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.onLiveRead = { count in
            if count == 2 {
                store.live = external
            }
        }
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(http: http, credentials: store).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.live?.refreshToken, "external-refresh-chain")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "stale-refresh-chain")
        XCTAssertEqual(store.liveReplaceCount, 0)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            0,
            "A same-access-token external generation must win without another exchange"
        )
    }

    func testInactiveRetryRereadsLiveChainAndRequiresSwitchBeforeExchange() async {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "live",
            refreshToken: "shared-chain",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale-target",
            refreshToken: "shared-chain",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the live shared chain to require switching")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .accountActiveElsewhere = error else {
                return XCTFail("Expected accountActiveElsewhere, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.liveReadCount, 1)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.liveReplaceCount, 0)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale-target")
    }

    func testSharedChainUserSwitchJournalsAndMergesLiveOwner() async throws {
        let store = FakeCredentialProvider()
        let live = makeCredentials(
            accessToken: "live-stale",
            refreshToken: "shared-chain",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: ["ownerMarker": "live-owner"]
        )
        let target = makeCredentials(
            accessToken: "target-stale",
            refreshToken: "shared-chain",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: ["ownerMarker": "target-owner"]
        )
        store.live = live
        store.stored[profile.id] = target
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            storedRecord: makeStoredRecord(credentials: target),
            now: now,
            rotationIntent: .userInitiatedSwitch
        )

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(jsonStringField("ownerMarker", in: store.live), "live-owner")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[profile.id]),
            "target-owner"
        )
        XCTAssertEqual(
            recoveryStore.saveHistory.first?.pendingDestinations,
            [.liveClaudeCode, .storedProfile(profile.id)]
        )
        XCTAssertEqual(store.liveReplaceCount, 1)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
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
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            accessMode: .userInitiated,
            rotationIntent: .userRetry
        )

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
            accessMode: .userInitiated,
            rotationIntent: .userRetry
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
                accessMode: .userInitiated,
                rotationIntent: .userRetry
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
            accessMode: .userInitiated,
            rotationIntent: .userRetry
        )
        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 2, "The explicit repair may resume usage once")
    }

    func testActiveStoredWriteFailureCannotBeHiddenAndRetryDoesNotRotateAgain() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.storedReplaceResultOverride = false
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let service = makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        )
        XCTAssertFalse(service.hasPendingCredentialRepair)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("A partial active commit must not report success")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertTrue(service.hasPendingCredentialRepair)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [.storedProfile(profile.id)]
        )

        store.storedReplaceResultOverride = nil
        // Simulate a relaunch: only the encrypted journal, not the service's
        // in-memory repair registry, survives.
        let relaunchedService = makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        )
        do {
            _ = try await relaunchedService.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .scheduledReadOnly
            )
            XCTFail("Scheduled work must surface the durable-owner split")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        }
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")

        _ = try await relaunchedService.fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1,
            "Repairing the stored owner must not consume the refresh chain again"
        )
    }

    func testPersistentFreshCheckpointFailureDoesNotCreateAmbiguousOwnerWrites() async {
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
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.saveErrorAfterSuccessfulSaves = 1
        let service = makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        )

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected loss of the uncheckpointed response to require login")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRecoveryFailed = error else {
                return XCTFail("Expected credentialRecoveryFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
    }

    func testLeaseLossAfterExchangeStillCheckpointsFreshGeneration() async {
        let lockHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-LostLeaseCheckpoint-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockHome) }

        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        http.onRequest = { request in
            guard request.url == ClaudeOAuthConstants.tokenEndpoint else { return }
            let lock = lockHome
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
            let displaced = lockHome.appendingPathComponent(
                "displaced-oauth-lock",
                isDirectory: true
            )
            try? FileManager.default.moveItem(at: lock, to: displaced)
            try? FileManager.default.createDirectory(
                at: lock,
                withIntermediateDirectories: false
            )
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore,
                lockHome: lockHome
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the lost lease to defer owner persistence")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected durable repair, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [.storedProfile(profile.id)]
        )
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testLeaseLossAfterOwnerWriteDoesNotPublishStaleJournalReduction() async {
        let lockHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-LostLeaseReduction-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockHome) }

        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.onLiveReplaceCommitted = {
            store.onLiveReplaceCommitted = nil
            let lock = lockHome.appendingPathComponent(
                ClaudeOAuthLockKind.claude.fileName,
                isDirectory: true
            )
            let displaced = lockHome.appendingPathComponent(
                "displaced-claude-lock",
                isDirectory: true
            )
            try? FileManager.default.moveItem(at: lock, to: displaced)
            try? FileManager.default.createDirectory(
                at: lock,
                withIntermediateDirectories: false
            )
        }
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore,
                lockHome: lockHome
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected durable repair after the lease replacement")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(recoveryStore.saveHistory.count, 2)
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [.liveClaudeCode, .storedProfile(profile.id)],
            "The stale process must leave the conservative full checkpoint intact"
        )
    }

    func testLeaseLossAfterPreparedCheckpointPreservesRecordForNewLeaseHolder() async {
        let lockHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-LostPreparedLease-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockHome) }

        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.onSave = { record in
            guard record.phase == .prepared else { return }
            recoveryStore.onSave = nil
            let lock = lockHome
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
            let displaced = lockHome.appendingPathComponent(
                "displaced-prepared-lock",
                isDirectory: true
            )
            try? FileManager.default.moveItem(at: lock, to: displaced)
            try? FileManager.default.createDirectory(
                at: lock,
                withIntermediateDirectories: false
            )
        }
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore,
                lockHome: lockHome
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the replaced lease to defer")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
        XCTAssertEqual(recoveryStore.deleteCount, 0)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
    }

    func testLeaseLossAfterMalformedResponsePreservesPreparedRecord() async {
        let lockHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-LostCleanupLease-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockHome) }

        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (Data(#"{"expires_in":3600}"#.utf8), 200)
        ])
        http.onRequest = { request in
            guard request.url == ClaudeOAuthConstants.tokenEndpoint else { return }
            http.onRequest = nil
            let lock = lockHome
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent(".oauth_refresh.lock", isDirectory: true)
            let displaced = lockHome.appendingPathComponent(
                "displaced-cleanup-lock",
                isDirectory: true
            )
            try? FileManager.default.moveItem(at: lock, to: displaced)
            try? FileManager.default.createDirectory(
                at: lock,
                withIntermediateDirectories: false
            )
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore,
                lockHome: lockHome
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected retained recovery state after losing the lease")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
        XCTAssertEqual(recoveryStore.deleteCount, 0)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testCancellationAfterPreparedCheckpointCleansRecordBeforeTokenRequest() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.onSave = { record in
            guard record.phase == .prepared else { return }
            recoveryStore.onSave = nil
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cleanup completed before cancellation propagated.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
    }

    func testPreparedCleanupFailureBeforeTokenRequestRemainsDeferred() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.deleteError = CredentialStoreError.keychainError(
            errSecInteractionNotAllowed
        )
        recoveryStore.onSave = { record in
            guard record.phase == .prepared else { return }
            recoveryStore.onSave = nil
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let http = ScriptedHTTPClient(responses: [])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected cleanup failure to defer the operation")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
    }

    func testTransientFreshCheckpointFailureRetriesBeforeOwnerWrites() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.storedReplaceResultOverride = false
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        // Attempt 1 is the prepared map; attempt 2 is the first fresh-secret
        // checkpoint. The service retries that checkpoint before any owner CAS.
        recoveryStore.saveFailureAttempts = [2]
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        let service = makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        )

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the stored owner to remain pending")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        }

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [.storedProfile(profile.id)]
        )
        XCTAssertEqual(recoveryStore.records.first?.phase, .freshGeneration)

        store.storedReplaceResultOverride = nil
        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1,
            "Durable-journal repair must not exchange the refresh token again"
        )
    }

    func testFreshJournalRepairsEveryPartialOwnerPersistenceCombinationAfterRelaunch() async throws {
        let siblingID = UUID()
        // Bits: live = 1, primary stored = 2, sibling stored = 4. The encrypted
        // fresh checkpoint is authoritative for all eight owner-write crash
        // combinations, including no surviving owner write at all.
        for survivors in 0...7 {
            let staleLive = makeCredentials(
                accessToken: "live-stale",
                refreshToken: "refresh-1",
                expiresAt: now.addingTimeInterval(-60),
                additionalFields: ["ownerMarker": "live"]
            )
            let stalePrimary = makeCredentials(
                accessToken: "primary-stale",
                refreshToken: "refresh-1",
                expiresAt: now.addingTimeInterval(-60),
                additionalFields: ["ownerMarker": "primary"]
            )
            let staleSibling = makeCredentials(
                accessToken: "sibling-stale",
                refreshToken: "refresh-1",
                expiresAt: now.addingTimeInterval(600),
                additionalFields: ["ownerMarker": "sibling"]
            )
            let issued = makeCredentials(
                accessToken: "fresh",
                refreshToken: "refresh-2",
                expiresAt: now.addingTimeInterval(3_600)
            )
            let freshLive = try XCTUnwrap(
                staleLive.mergingRotatedTokenFields(from: issued)
            )
            let freshPrimary = try XCTUnwrap(
                stalePrimary.mergingRotatedTokenFields(from: issued)
            )
            let freshSibling = try XCTUnwrap(
                staleSibling.mergingRotatedTokenFields(from: issued)
            )

            let store = FakeCredentialProvider()
            store.live = survivors & 1 == 0 ? staleLive : freshLive
            store.stored[profile.id] = survivors & 2 == 0
                ? stalePrimary : freshPrimary
            store.stored[siblingID] = survivors & 4 == 0
                ? staleSibling : freshSibling

            let liveDestination = ClaudeRotationRecoveryDestination.liveClaudeCode
            let primaryDestination = ClaudeRotationRecoveryDestination.storedProfile(
                profile.id
            )
            let siblingDestination = ClaudeRotationRecoveryDestination.storedProfile(
                siblingID
            )
            let recoveryStore = FakeClaudeRotationRecoveryStore()
            try recoveryStore.save(
                ClaudeRotationRecoveryRecord(
                    createdAt: now,
                    staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                        credentials: stalePrimary
                    )!,
                    freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                        credentials: issued
                    ),
                    oauthJSON: issued.rawClaudeAiOauth,
                    pendingDestinations: [
                        liveDestination,
                        primaryDestination,
                        siblingDestination
                    ],
                    ownerGenerationBaselines: [
                        liveDestination: ClaudeOAuthGenerationFingerprint.make(staleLive),
                        primaryDestination: ClaudeOAuthGenerationFingerprint.make(stalePrimary),
                        siblingDestination: ClaudeOAuthGenerationFingerprint.make(staleSibling)
                    ],
                    phase: .freshGeneration
                ),
                accessMode: .nonInteractive
            )
            let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )

            XCTAssertEqual(store.live?.accessToken, "fresh", "subset \(survivors)")
            XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh", "subset \(survivors)")
            XCTAssertEqual(store.stored[siblingID]?.accessToken, "fresh", "subset \(survivors)")
            XCTAssertEqual(jsonStringField("ownerMarker", in: store.live), "live")
            XCTAssertEqual(jsonStringField("ownerMarker", in: store.stored[profile.id]), "primary")
            XCTAssertEqual(jsonStringField("ownerMarker", in: store.stored[siblingID]), "sibling")
            XCTAssertTrue(recoveryStore.records.isEmpty, "subset \(survivors)")
            XCTAssertTrue(
                http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.isEmpty,
                "subset \(survivors) must repair without another exchange"
            )
        }
    }

    func testPreparedJournalWithNoFreshSurvivorRetriesOnlyToConfirmTerminalRejection() async {
        let siblingID = UUID()
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.live = stale
        store.stored[profile.id] = stale
        store.stored[siblingID] = stale
        store.liveReplaceResultOverride = false
        store.storedReplaceResultOverride = false
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.saveErrorAfterSuccessfulSaves = 1
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (Data(#"{"error":"invalid_grant"}"#.utf8), 400)
        ])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry,
                additionalRecoveryDestinations: [.storedProfile(siblingID)]
            )
            XCTFail("The in-process exchange must fail without a fresh survivor")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRecoveryFailed = error else {
                return XCTFail("Expected credentialRecoveryFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        recoveryStore.saveErrorAfterSuccessfulSaves = nil
        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry,
                additionalRecoveryDestinations: [.storedProfile(siblingID)]
            )
            XCTFail("The provider must confirm that the indeterminate chain was consumed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed(let underlying) = error,
                  let oauth = underlying as? ClaudeOAuthError,
                  oauth.requiresLogin else {
                return XCTFail("Expected terminal refresh rejection, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(store.stored[siblingID]?.accessToken, "stale")
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            2,
            "Exactly one explicit probe resolves the crash ambiguity"
        )
    }

    func testCrashAfterPreparedCheckpointBeforeRequestRemainsRecoverable() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.stored[profile.id] = stale
        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                staleChainFingerprint: try XCTUnwrap(
                    ClaudeRefreshChainFingerprint.make(credentials: stale)
                ),
                freshChainFingerprint: nil,
                oauthJSON: stale.rawClaudeAiOauth,
                pendingDestinations: [destination],
                ownerGenerationBaselines: [
                    destination: ClaudeOAuthGenerationFingerprint.make(stale)
                ],
                phase: .prepared
            ),
            accessMode: .nonInteractive
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        let service = makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        )

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .scheduledReadOnly
            )
            XCTFail("Scheduled work must leave the ambiguous prepared request untouched")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        }
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)

        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testPreparedJournalAdoptsDivergentSupersedingGenerationsWithoutPropagation() async throws {
        let siblingID = UUID()
        let stalePrimary = makeCredentials(
            accessToken: "primary-stale",
            refreshToken: "shared-stale",
            expiresAt: now.addingTimeInterval(-60)
        )
        let staleSibling = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "shared-stale",
            expiresAt: now.addingTimeInterval(600)
        )
        let newerPrimary = makeCredentials(
            accessToken: "primary-new-login",
            refreshToken: "primary-chain",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let newerSibling = makeCredentials(
            accessToken: "sibling-new-login",
            refreshToken: "sibling-chain",
            expiresAt: now.addingTimeInterval(7_200)
        )
        let primaryDestination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let siblingDestination = ClaudeRotationRecoveryDestination.storedProfile(
            siblingID
        )
        let store = FakeCredentialProvider()
        store.stored[profile.id] = newerPrimary
        store.stored[siblingID] = newerSibling
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: stalePrimary
                )!,
                freshChainFingerprint: nil,
                oauthJSON: stalePrimary.rawClaudeAiOauth,
                pendingDestinations: [primaryDestination, siblingDestination],
                ownerGenerationBaselines: [
                    primaryDestination: ClaudeOAuthGenerationFingerprint.make(
                        stalePrimary
                    ),
                    siblingDestination: ClaudeOAuthGenerationFingerprint.make(
                        staleSibling
                    )
                ],
                phase: .prepared
            ),
            accessMode: .nonInteractive
        )

        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id], newerPrimary)
        XCTAssertEqual(store.stored[siblingID], newerSibling)
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertTrue(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.isEmpty
        )
    }

    func testProfileRemovalMaterializesSoleFreshOwnerBeforeSnapshotDeletion() async throws {
        let siblingID = UUID()
        let siblingProfile = AccountProfile(
            id: siblingID,
            provider: .claude,
            label: "Sibling"
        )
        let stalePrimary = makeCredentials(
            accessToken: "primary-stale",
            refreshToken: "shared-stale",
            expiresAt: now.addingTimeInterval(-60)
        )
        let staleSibling = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "shared-stale",
            expiresAt: now.addingTimeInterval(600),
            additionalFields: ["ownerMarker": "sibling"]
        )
        let freshPrimary = makeCredentials(
            accessToken: "fresh",
            refreshToken: "fresh-chain",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let primaryDestination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let siblingDestination = ClaudeRotationRecoveryDestination.storedProfile(
            siblingID
        )
        let store = FakeCredentialProvider()
        store.stored[profile.id] = freshPrimary
        store.stored[siblingID] = staleSibling
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: stalePrimary
                )!,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: freshPrimary
                ),
                oauthJSON: freshPrimary.rawClaudeAiOauth,
                pendingDestinations: [primaryDestination, siblingDestination],
                ownerGenerationBaselines: [
                    primaryDestination: ClaudeOAuthGenerationFingerprint.make(
                        stalePrimary
                    ),
                    siblingDestination: ClaudeOAuthGenerationFingerprint.make(
                        staleSibling
                    )
                ],
                phase: .freshGeneration
            ),
            accessMode: .nonInteractive
        )

        let lockHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LimitLifeboat-RemovalRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: lockHome) }
        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: lockHome,
            configuration: ClaudeOAuthRefreshCoordinatorConfiguration(retryCount: 0),
            environment: [:]
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        let service = ClaudeAccountUsageService(
            apiClient: ClaudeUsageAPIClient(httpClient: http),
            refresher: ClaudeOAuthTokenRefresher(httpClient: http),
            credentials: store,
            refreshCoordinator: coordinator,
            recoveryStore: recoveryStore
        )

        // A failed snapshot deletion must retain both the encrypted fresh copy
        // and its profile destination. The user can safely retry removal.
        do {
            try await coordinator.withLease { _ in
                try service.performStoredProfileRemoval(
                    profile.id,
                    accessMode: .nonInteractive
                ) {
                    throw URLError(.cannotRemoveFile)
                }
            }
            XCTFail("Expected the injected snapshot deletion to fail")
        } catch {
            // Expected.
        }
        XCTAssertEqual(recoveryStore.records.first?.phase, .freshGeneration)
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [primaryDestination, siblingDestination]
        )
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")

        try await coordinator.withLease { _ in
            try service.performStoredProfileRemoval(
                profile.id,
                accessMode: .nonInteractive
            ) {
                store.stored[profile.id] = nil
            }
        }

        XCTAssertEqual(recoveryStore.records.first?.phase, .freshGeneration)
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [siblingDestination]
        )
        XCTAssertEqual(recoveryStore.records.first?.credentials?.accessToken, "fresh")

        _ = try await service.fetchSnapshot(
            for: siblingProfile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[siblingID]?.accessToken, "fresh")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[siblingID]),
            "sibling"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertTrue(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.isEmpty
        )
    }

    func testPrimaryStoredCommitMergesOwnerLocalFields() async throws {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "live-stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: ["ownerMarker": "live"]
        )
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: ["ownerMarker": "stored"]
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        _ = try await makeService(
            http: http,
            credentials: store
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: true,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.live?.accessToken, "fresh")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(jsonStringField("ownerMarker", in: store.live), "live")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[profile.id]),
            "stored"
        )
    }

    func testStoredCASConflictAdoptsNewerChainWhenCheckpointUnavailable() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let newer = makeCredentials(
            accessToken: "external-newer",
            refreshToken: "external-chain",
            expiresAt: now.addingTimeInterval(7_200)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.saveErrorAfterSuccessfulSaves = 1
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.stored[self.profile.id] = newer
            }
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the concurrent generation to defer this workflow")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "external-newer")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testStoredCASConflictDetectsNewGenerationWithSameAccessToken() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "same-access",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let external = makeCredentials(
            accessToken: "same-access",
            refreshToken: "external-chain",
            expiresAt: now.addingTimeInterval(7_200),
            additionalFields: ["ownerMarker": "external"]
        )
        store.stored[profile.id] = stale
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.stored[self.profile.id] = external
            }
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the exact-generation CAS to defer")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "same-access")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "external-chain")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[profile.id]),
            "external"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testLiveCASConflictPreservesAndAdoptsNewerChain() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let newer = makeCredentials(
            accessToken: "external-newer",
            refreshToken: "external-chain",
            expiresAt: now.addingTimeInterval(7_200)
        )
        store.live = stale
        store.liveLocation = keychainLocation(reference: "stable-location")
        store.stored[profile.id] = stale
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.live = newer
            }
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the concurrent live generation to defer this workflow")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "external-newer")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testLiveCASConflictDetectsNewGenerationWithSameAccessToken() async {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "same-access",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let external = makeCredentials(
            accessToken: "same-access",
            refreshToken: "external-chain",
            expiresAt: now.addingTimeInterval(7_200),
            additionalFields: ["ownerMarker": "external"]
        )
        store.live = stale
        store.liveLocation = keychainLocation(reference: "stable-location")
        store.stored[profile.id] = stale
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.live = external
            }
        }

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the exact-generation CAS to defer")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "same-access")
        XCTAssertEqual(store.live?.refreshToken, "external-chain")
        XCTAssertEqual(jsonStringField("ownerMarker", in: store.live), "external")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testPersistentPreparedCheckpointFailureDefersBeforeTokenExchange() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        store.storedReplaceResultOverride = false
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.saveError = CredentialStoreError.keychainError(
            errSecInteractionNotAllowed
        )

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected recovery preparation to defer")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            0,
            "An unavailable prepared checkpoint must fail before consuming the chain"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
    }

    func testRotationUpdatesAdditionalSiblingBeforeReturning() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let siblingID = UUID()
        store.stored[siblingID] = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3_600),
            additionalFields: ["ownerMarker": "sibling"]
        )
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        let recoveryStore = FakeClaudeRotationRecoveryStore()

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry,
            additionalRecoveryDestinations: [.storedProfile(siblingID)]
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(store.stored[siblingID]?.accessToken, "fresh")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[siblingID]),
            "sibling"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
    }

    func testSiblingPersistenceConflictLeavesJournaledRepair() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let siblingID = UUID()
        store.stored[siblingID] = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.storedReplaceResultOverrides[siblingID] = false
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200)
        ])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry,
                additionalRecoveryDestinations: [.storedProfile(siblingID)]
            )
            XCTFail("Expected sibling persistence to require repair")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(store.stored[siblingID]?.accessToken, "sibling-stale")
        XCTAssertEqual(
            recoveryStore.records.first?.pendingDestinations,
            [.storedProfile(siblingID)]
        )
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testScheduledReadDoesNotMutateResolvedRecoveryJournalEntry() async throws {
        let store = FakeCredentialProvider()
        let fresh = makeCredentials(
            accessToken: "fresh",
            refreshToken: "refresh-2",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.stored[profile.id] = fresh
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    refreshToken: "refresh-1"
                )!,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: fresh
                ),
                oauthJSON: fresh.rawClaudeAiOauth,
                pendingDestinations: [.storedProfile(profile.id)]
            ),
            accessMode: .nonInteractive
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .scheduledReadOnly
        )

        XCTAssertEqual(recoveryStore.saveCount, 1)
        XCTAssertEqual(recoveryStore.deleteCount, 0)
        XCTAssertEqual(recoveryStore.records.count, 1)
    }

    func testExplicitRetryReconcilesPendingSiblingTransactionWide() async throws {
        let store = FakeCredentialProvider()
        let fresh = makeCredentials(
            accessToken: "fresh",
            refreshToken: "refresh-2",
            expiresAt: now.addingTimeInterval(3_600),
            additionalFields: ["ownerMarker": "initiator"]
        )
        store.stored[profile.id] = fresh
        let siblingID = UUID()
        store.stored[siblingID] = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(600),
            additionalFields: ["ownerMarker": "sibling"]
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    refreshToken: "refresh-1"
                )!,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: fresh
                ),
                oauthJSON: fresh.rawClaudeAiOauth,
                pendingDestinations: [.storedProfile(siblingID)]
            ),
            accessMode: .nonInteractive
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[siblingID]?.accessToken, "fresh")
        XCTAssertEqual(store.stored[siblingID]?.refreshToken, "refresh-2")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[siblingID]),
            "sibling"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            0,
            "Journal reconciliation must not consume another refresh token"
        )
    }

    func testRecoveryJournalAdoptsNewerSameChainGenerationAfterCrash() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(-60)
        )
        let journalFresh = makeCredentials(
            accessToken: "journal-fresh",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let externalNewer = makeCredentials(
            accessToken: "external-newer",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(7_200)
        )
        store.stored[profile.id] = externalNewer
        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: stale
                )!,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: journalFresh
                ),
                oauthJSON: journalFresh.rawClaudeAiOauth,
                pendingDestinations: [destination],
                ownerGenerationBaselines: [
                    destination: ClaudeOAuthGenerationFingerprint.make(stale)
                ]
            ),
            accessMode: .nonInteractive
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "external-newer")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            0,
            "Adopting a newer same-chain owner must not replay or exchange a token"
        )
    }

    func testRecoveryJournalRepairsExactBaselineWhenRefreshTokenWasOmitted() async throws {
        let store = FakeCredentialProvider()
        let stale = makeCredentials(
            accessToken: "stale",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(-60),
            additionalFields: ["ownerMarker": "stored"]
        )
        let journalFresh = makeCredentials(
            accessToken: "journal-fresh",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.stored[profile.id] = stale
        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        try recoveryStore.save(
            ClaudeRotationRecoveryRecord(
                createdAt: now,
                staleChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: stale
                )!,
                freshChainFingerprint: ClaudeRefreshChainFingerprint.make(
                    credentials: journalFresh
                ),
                oauthJSON: journalFresh.rawClaudeAiOauth,
                pendingDestinations: [destination],
                ownerGenerationBaselines: [
                    destination: ClaudeOAuthGenerationFingerprint.make(stale)
                ]
            ),
            accessMode: .nonInteractive
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "journal-fresh")
        XCTAssertEqual(
            jsonStringField("ownerMarker", in: store.stored[profile.id]),
            "stored"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            0
        )
    }

    func testRecoveryRecordGenerationBaselinesRoundTripAndRemainBackwardCompatible() throws {
        let destination = ClaudeRotationRecoveryDestination.storedProfile(
            profile.id
        )
        let record = ClaudeRotationRecoveryRecord(
            createdAt: now,
            staleChainFingerprint: "stale-chain",
            freshChainFingerprint: "fresh-chain",
            oauthJSON: Data(#"{"accessToken":"fresh"}"#.utf8),
            pendingDestinations: [destination],
            ownerGenerationBaselines: [destination: "stale-generation"]
        )

        let encoded = try JSONEncoder.appEncoder.encode(record)
        let decoded = try JSONDecoder.appDecoder.decode(
            ClaudeRotationRecoveryRecord.self,
            from: encoded
        )
        XCTAssertEqual(decoded, record)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "ownerGenerationBaselines")
        legacyObject.removeValue(forKey: "phase")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder.appDecoder.decode(
            ClaudeRotationRecoveryRecord.self,
            from: legacyData
        )
        XCTAssertNil(legacy.ownerGenerationBaselines)
        XCTAssertNil(legacy.phase)
    }

    func testSiblingAdvancingOnSameChainDuringExchangeIsNotOverwritten() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "primary-stale",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(-60)
        )
        let siblingID = UUID()
        store.stored[siblingID] = makeCredentials(
            accessToken: "sibling-stale",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(600)
        )
        let externalNewer = makeCredentials(
            accessToken: "sibling-external-newer",
            refreshToken: "shared-refresh",
            expiresAt: now.addingTimeInterval(7_200)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let responseWithoutRotatedRefreshToken = Data(
            #"{"access_token":"primary-fresh","expires_in":3600}"#.utf8
        )
        let http = ScriptedHTTPClient(responses: [
            (responseWithoutRotatedRefreshToken, 200),
            (usageJSON, 200)
        ])
        http.onRequest = { request in
            if request.url == ClaudeOAuthConstants.tokenEndpoint {
                store.stored[siblingID] = externalNewer
            }
        }

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry,
            additionalRecoveryDestinations: [.storedProfile(siblingID)]
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "primary-fresh")
        XCTAssertEqual(
            store.stored[siblingID]?.accessToken,
            "sibling-external-newer"
        )
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
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

    func testCustomClaudeConfigurationFailsScheduledReadBeforeCredentialAccess() async {
        let store = FakeCredentialProvider()
        store.live = makeCredentials(
            accessToken: "live-token",
            expiresAt: now.addingTimeInterval(3_600)
        )
        store.stored[profile.id] = store.live
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])
        let service = makeService(
            http: http,
            credentials: store,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"]
        )

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: true,
                now: now,
                accessMode: .nonInteractive,
                rotationIntent: .scheduledReadOnly
            )
            XCTFail("Expected a custom Claude configuration to fail closed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred(let underlying) = error,
                  case .ambiguousConfiguration = underlying
                    as? ClaudeOAuthRefreshCoordinatorError else {
                return XCTFail("Expected ambiguous configuration, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.liveReadCount, 0)
        XCTAssertEqual(store.storedReadCount, 0)
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

    func testReadOnlyIntentsNeverRotateExpiredActiveOrInactiveCredentials() async {
        for intent in [
            ClaudeRotationIntent.scheduledReadOnly,
            .automaticSwitch
        ] {
            for isActiveCLI in [false, true] {
                let store = FakeCredentialProvider()
                let stale = makeCredentials(
                    accessToken: "stale",
                    refreshToken: "must-not-be-spent",
                    expiresAt: now.addingTimeInterval(-60)
                )
                store.stored[profile.id] = stale
                if isActiveCLI {
                    store.live = stale
                }
                let http = ScriptedHTTPClient(responses: [])

                do {
                    _ = try await makeService(
                        http: http,
                        credentials: store
                    ).fetchSnapshot(
                        for: profile,
                        isActiveCLI: isActiveCLI,
                        now: now,
                        accessMode: .userInitiated,
                        rotationIntent: intent
                    )
                    XCTFail("Expected \(intent) to defer rotation")
                } catch let error as ClaudeAccountUsageFetchError {
                    guard case .interactiveRefreshRequired = error else {
                        return XCTFail("Expected interactiveRefreshRequired, got \(error)")
                    }
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }

                XCTAssertTrue(http.requests.isEmpty)
                XCTAssertEqual(store.live?.accessToken, isActiveCLI ? "stale" : nil)
                XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
                XCTAssertEqual(store.liveReplaceCount, 0)
            }
        }
    }

    func testScheduledRotationNeedWithMissingRefreshCredentialRequiresLoginForActiveAndInactive() async {
        for (isActiveCLI, refreshToken) in [(false, nil), (true, "   ")] as [(Bool, String?)] {
            let store = FakeCredentialProvider()
            let stale = makeCredentials(
                accessToken: "stale",
                refreshToken: refreshToken,
                expiresAt: now.addingTimeInterval(-60)
            )
            store.stored[profile.id] = stale
            if isActiveCLI {
                store.live = stale
            }
            let http = ScriptedHTTPClient(responses: [])

            do {
                _ = try await makeService(
                    http: http,
                    credentials: store
                ).fetchSnapshot(
                    for: profile,
                    isActiveCLI: isActiveCLI,
                    now: now,
                    rotationIntent: .scheduledReadOnly
                )
                XCTFail("Expected missing refresh credentials to require login")
            } catch let error as ClaudeAccountUsageFetchError {
                guard case .refreshFailed(let underlying) = error,
                      case .missingRefreshToken = underlying as? ClaudeOAuthError else {
                    return XCTFail("Expected missingRefreshToken, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(store.liveReplaceCount, 0)
            XCTAssertEqual(store.storedMutationCount, 0)
        }
    }

    func testScheduledRotationNeedWithKnownLoginExpiryRequiresLoginWithoutRequest() async {
        for isActiveCLI in [false, true] {
            let store = FakeCredentialProvider()
            let stale = makeCredentials(
                accessToken: "stale",
                expiresAt: now.addingTimeInterval(-60),
                additionalFields: [
                    "refreshTokenExpiresAt": Int(now.timeIntervalSince1970 * 1_000)
                ]
            )
            store.stored[profile.id] = stale
            if isActiveCLI {
                store.live = stale
            }
            let http = ScriptedHTTPClient(responses: [])

            do {
                _ = try await makeService(
                    http: http,
                    credentials: store
                ).fetchSnapshot(
                    for: profile,
                    isActiveCLI: isActiveCLI,
                    now: now,
                    rotationIntent: .scheduledReadOnly
                )
                XCTFail("Expected the fixed login expiry to require login")
            } catch let error as ClaudeAccountUsageFetchError {
                guard case .refreshFailed(let underlying) = error,
                      case .refreshTokenExpired = underlying as? ClaudeOAuthError else {
                    return XCTFail("Expected refreshTokenExpired, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(store.liveReplaceCount, 0)
            XCTAssertEqual(store.storedMutationCount, 0)
        }
    }

    func testScheduledUsageMayUseValidAccessTokenAfterFixedLoginExpiryUntilRejected() async throws {
        for isActiveCLI in [false, true] {
            let store = FakeCredentialProvider()
            let current = makeCredentials(
                accessToken: "still-valid",
                expiresAt: now.addingTimeInterval(3_600),
                additionalFields: [
                    "refreshTokenExpiresAt": Int(now.timeIntervalSince1970 * 1_000)
                ]
            )
            store.stored[profile.id] = current
            if isActiveCLI {
                store.live = current
            }
            let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

            _ = try await makeService(
                http: http,
                credentials: store
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: isActiveCLI,
                now: now,
                rotationIntent: .scheduledReadOnly
            )

            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(http.requests[0].url, ClaudeOAuthConstants.usageEndpoint)
            XCTAssertEqual(store.liveReplaceCount, 0)
            XCTAssertEqual(store.storedMutationCount, 0)
        }
    }

    func testReadOnlyIntentsNeverRotateRejectedActiveOrInactiveCredentials() async {
        for intent in [
            ClaudeRotationIntent.scheduledReadOnly,
            .automaticSwitch
        ] {
            for isActiveCLI in [false, true] {
                let store = FakeCredentialProvider()
                let current = makeCredentials(
                    accessToken: "rejected",
                    refreshToken: "must-not-be-spent",
                    expiresAt: now.addingTimeInterval(3_600)
                )
                store.stored[profile.id] = current
                if isActiveCLI {
                    store.live = current
                }
                let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 401)])

                do {
                    _ = try await makeService(
                        http: http,
                        credentials: store
                    ).fetchSnapshot(
                        for: profile,
                        isActiveCLI: isActiveCLI,
                        now: now,
                        accessMode: .userInitiated,
                        rotationIntent: intent
                    )
                    XCTFail("Expected \(intent) to defer the 401 recovery")
                } catch let error as ClaudeAccountUsageFetchError {
                    guard case .interactiveRefreshRequired = error else {
                        return XCTFail("Expected interactiveRefreshRequired, got \(error)")
                    }
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }

                XCTAssertEqual(http.requests.count, 1)
                XCTAssertEqual(http.requests.first?.url, ClaudeOAuthConstants.usageEndpoint)
                XCTAssertEqual(store.live?.accessToken, isActiveCLI ? "rejected" : nil)
                XCTAssertEqual(store.stored[profile.id]?.accessToken, "rejected")
                XCTAssertEqual(store.liveReplaceCount, 0)
            }
        }
    }

    func testReadOnly401RecoveryDoesNotAttemptSharedLockAcquisition() async {
        for intent in [
            ClaudeRotationIntent.scheduledReadOnly,
            .automaticSwitch
        ] {
            let lockHome = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "LimitLifeboat-ReadOnly-NoLock-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: lockHome,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: lockHome) }

            let store = FakeCredentialProvider()
            store.stored[profile.id] = makeCredentials(
                accessToken: "rejected",
                refreshToken: "must-not-be-spent",
                expiresAt: now.addingTimeInterval(3_600)
            )
            let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 401)])

            do {
                _ = try await makeService(
                    http: http,
                    credentials: store,
                    lockHome: lockHome
                ).fetchSnapshot(
                    for: profile,
                    isActiveCLI: false,
                    now: now,
                    rotationIntent: intent
                )
                XCTFail("Expected read-only 401 recovery to defer")
            } catch let error as ClaudeAccountUsageFetchError {
                guard case .interactiveRefreshRequired = error else {
                    return XCTFail("Expected interactiveRefreshRequired, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: lockHome.appendingPathComponent(".claude").path
                ),
                "A read-only 401 must return before the coordinator prepares lock paths"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: lockHome.appendingPathComponent(".claude.lock").path
                )
            )
            XCTAssertEqual(http.requests.count, 1)
        }
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
            accessMode: .userInitiated,
            rotationIntent: .userRetry
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
            accessMode: .userInitiated,
            rotationIntent: .userRetry
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
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            accessMode: .userInitiated,
            rotationIntent: .userRetry
        )

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
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected unauthorized")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .unauthorized = error else {
                return XCTFail("Expected unauthorized, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testForbiddenDoesNotConsumeRefreshTokenEvenOnUserRetry() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "forbidden",
            refreshToken: "must-not-be-spent",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 403)])

        do {
            _ = try await makeService(http: http, credentials: store).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected forbidden")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .forbidden = error else {
                return XCTFail("Expected forbidden, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.url, ClaudeOAuthConstants.usageEndpoint)
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "must-not-be-spent")
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
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected refreshFailed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testNetworkRefreshFailureClearsPreparedRecordBeforeRelaunchRetry() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])
        http.nextError = URLError(.networkConnectionLost)

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the first network attempt to fail")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        }

        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            2
        )
    }

    func testFailedPreparedCleanupAfterNetworkFailureRemainsRepairable() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.deleteError = CredentialStoreError.keychainError(
            errSecInteractionNotAllowed
        )
        let http = ScriptedHTTPClient(responses: [])
        http.nextError = URLError(.networkConnectionLost)

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the retained checkpoint to require repair")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testMalformedRefreshClearsPreparedRecordBeforeRelaunchRetry() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        let http = ScriptedHTTPClient(responses: [
            (Data(#"{"expires_in":3600}"#.utf8), 200),
            (refreshJSON(accessToken: "fresh"), 200),
            (usageJSON, 200)
        ])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the malformed token response to fail")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .refreshFailed = error else {
                return XCTFail("Expected refreshFailed, got \(error)")
            }
        }

        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")

        _ = try await makeService(
            http: http,
            credentials: store,
            recoveryStore: recoveryStore
        ).fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertTrue(recoveryStore.records.isEmpty)
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            2
        )
    }

    func testFailedPreparedCleanupAfterMalformedRefreshRemainsRepairable() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let recoveryStore = FakeClaudeRotationRecoveryStore()
        recoveryStore.deleteError = CredentialStoreError.keychainError(
            errSecInteractionNotAllowed
        )
        let http = ScriptedHTTPClient(responses: [
            (Data(#"{"expires_in":3600}"#.utf8), 200)
        ])

        do {
            _ = try await makeService(
                http: http,
                credentials: store,
                recoveryStore: recoveryStore
            ).fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the retained checkpoint to require repair")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recoveryStore.records.first?.phase, .prepared)
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")
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
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("A live CAS conflict must abort the refreshed usage request")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
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
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected replacement of the pinned item to fail closed")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .rotationDeferred = error else {
                return XCTFail("Expected rotationDeferred, got \(error)")
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
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected false live CAS to abort")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.live?.accessToken, "stale")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(http.requests.count, 1)
    }

    // MARK: - Shared-account rotation protection

    func testSharedAccountInactiveExpiredDoesNotRotateInBackground() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                accountIsLiveElsewhere: true,
                now: now,
                accessMode: .nonInteractive
            )
            XCTFail("Expected a shared-account profile to defer rotation")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .accountActiveElsewhere = error else {
                return XCTFail("Expected accountActiveElsewhere, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty, "The shared chain must not be rotated")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "refresh-1")
    }

    func testSharedAccountInactiveDoesNotRotateEvenOnUserInitiated() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                accountIsLiveElsewhere: true,
                now: now,
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected a shared-account profile to refuse rotation even on Retry")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .accountActiveElsewhere = error else {
                return XCTFail("Expected accountActiveElsewhere, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "refresh-1")
    }

    func testSharedAccountValidTokenStillFetchesUsage() async throws {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [(usageJSON, 200)])

        let service = makeService(http: http, credentials: store)
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            accountIsLiveElsewhere: true,
            now: now
        )

        XCTAssertEqual(http.requests.count, 1, "A valid shared-account token needs no refresh")
        XCTAssertEqual(http.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer stored-token")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "refresh-1")
    }

    func testSharedAccountUnauthorizedDoesNotSpendRefreshToken() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stored-token",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(3600)
        )
        let http = ScriptedHTTPClient(responses: [(Data("{}".utf8), 401)])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                accountIsLiveElsewhere: true,
                now: now
            )
            XCTFail("Expected the 401 retry to be blocked for a shared account")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .accountActiveElsewhere = error else {
                return XCTFail("Expected accountActiveElsewhere, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(http.requests.count, 1, "Only the usage call — no forced refresh")
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "refresh-1")
    }

    func testNormalInactiveRefreshesOnUserActionWhenNotShared() async throws {
        // A non-shared inactive account still rotates on a user action (Retry
        // or switch preflight) — only background cycles defer.
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
        _ = try await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            accountIsLiveElsewhere: false,
            now: now,
            accessMode: .userInitiated,
            rotationIntent: .userRetry
        )

        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
    }

    func testSharedAccountSiblingBlockedEvenOnExplicitRequest() async {
        // An explicit request does not override the shared-account guard:
        // rotating a sibling's chain would still strand the active login.
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])

        let service = makeService(http: http, credentials: store)
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                accountIsLiveElsewhere: true,
                now: now,
                accessMode: .nonInteractive,
                rotationIntent: .userRetry
            )
            XCTFail("Expected a shared-account sibling to stay protected")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .accountActiveElsewhere = error else {
                return XCTFail("Expected accountActiveElsewhere, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertTrue(http.requests.isEmpty)
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
                rotationIntent: .userRetry
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
                rotationIntent: .userRetry
            )
            XCTFail("Expected denied live item to block rotation")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .liveCredentialAccessDenied = error else {
                return XCTFail("Expected liveCredentialAccessDenied, got \(error)")
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

        let service = makeService(
            http: http,
            credentials: store,
            recoveryStore: FakeClaudeRotationRecoveryStore()
        )
        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                rotationIntent: .userRetry
            )
            XCTFail("Expected the failed persistence to fail the refresh")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected a repairable persistence failure, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertEqual(http.requests.count, 1, "Usage must not be fetched with an unsaved rotated token")
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "stale")

        // Scheduled work reports the pending repair without spending the old
        // refresh token again.
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected the exact credential to remain pending repair")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialRepairRequired = error else {
                return XCTFail("Expected credentialRepairRequired, got \(error)")
            }
            XCTAssertEqual(http.requests.count, 1)
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        store.storedReplaceResultOverride = nil
        _ = try? await service.fetchSnapshot(
            for: profile,
            isActiveCLI: false,
            now: now,
            rotationIntent: .userRetry
        )
        XCTAssertEqual(store.stored[profile.id]?.accessToken, "fresh")
        XCTAssertEqual(
            http.requests.filter { $0.url == ClaudeOAuthConstants.tokenEndpoint }.count,
            1
        )
    }

    func testTerminalRefreshFailureIsNeverAttemptedByScheduledWork() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "invalid-refresh",
            expiresAt: now.addingTimeInterval(-60)
        )
        let rejected = Data(#"{"error":"invalid_grant"}"#.utf8)
        let http = ScriptedHTTPClient(responses: [(rejected, 400)])
        let service = makeService(http: http, credentials: store)

        for _ in 0..<2 {
            do {
                _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
                XCTFail("Expected scheduled rotation to be deferred")
            } catch let error as ClaudeAccountUsageFetchError {
                guard case .interactiveRefreshRequired = error else {
                    return XCTFail("Expected interactiveRefreshRequired, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertTrue(http.requests.isEmpty)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated,
                rotationIntent: .userRetry
            )
            XCTFail("Expected explicit retry to reach the scripted rejection")
        } catch {
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testUserInitiatedCredentialAccessModeAloneDoesNotPermitRotation() async {
        let store = FakeCredentialProvider()
        store.stored[profile.id] = makeCredentials(
            accessToken: "stale",
            refreshToken: "must-not-be-spent",
            expiresAt: now.addingTimeInterval(-60)
        )
        let http = ScriptedHTTPClient(responses: [])
        let service = makeService(http: http, credentials: store)

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                isActiveCLI: false,
                now: now,
                accessMode: .userInitiated
            )
            XCTFail("Keychain prompt permission must not imply OAuth rotation permission")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .interactiveRefreshRequired = error else {
                return XCTFail("Expected interactiveRefreshRequired, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(store.stored[profile.id]?.refreshToken, "must-not-be-spent")
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

    /// A decode failure is neither a missing login nor a terminal credential;
    /// keep it typed as an unreadable/recoverable credential failure.
    func testKeychainDecodeErrorFailsClosedAsCredentialUnavailable() async {
        let store = FakeCredentialProvider()
        store.storedError = CredentialStoreError.decodeFailed(underlying: nil)
        let service = makeService(http: ScriptedHTTPClient(responses: []), credentials: store)
        do {
            _ = try await service.fetchSnapshot(for: profile, isActiveCLI: false, now: now)
            XCTFail("Expected credentialUnavailable")
        } catch let error as ClaudeAccountUsageFetchError {
            guard case .credentialUnavailable = error else {
                return XCTFail("Expected credentialUnavailable, got \(error)")
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
        refreshToken: String? = "refresh-token",
        expiresAt: Date,
        additionalFields: [String: Any] = [:]
    ) -> ClaudeOAuthCredentials {
        var object: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1_000)
        ]
        if let refreshToken {
            object["refreshToken"] = refreshToken
        }
        for (key, value) in additionalFields {
            object[key] = value
        }
        let json = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
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

    private func jsonStringField(
        _ key: String,
        in credentials: ClaudeOAuthCredentials?
    ) -> String? {
        guard let credentials,
              let object = try? JSONSerialization.jsonObject(
                  with: credentials.rawClaudeAiOauth
              ) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
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

    private func makeService(
        http: ScriptedHTTPClient,
        credentials: FakeCredentialProvider,
        recoveryStore: (any ClaudeRotationRecoveryStoring)? = nil,
        lockHome: URL? = nil,
        environment: [String: String] = [:]
    ) -> ClaudeAccountUsageService {
        let lockHome = lockHome ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-ClaudeAccountUsageServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: lockHome,
            withIntermediateDirectories: true
        )
        return ClaudeAccountUsageService(
            apiClient: ClaudeUsageAPIClient(httpClient: http),
            refresher: ClaudeOAuthTokenRefresher(httpClient: http),
            credentials: credentials,
            refreshCoordinator: ClaudeOAuthRefreshCoordinator(
                homeDirectory: lockHome,
                configuration: ClaudeOAuthRefreshCoordinatorConfiguration(
                    retryCount: 0
                ),
                environment: environment
            ),
            recoveryStore: recoveryStore
        )
    }
}

private final class FakeClaudeRotationRecoveryStore: ClaudeRotationRecoveryStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: ClaudeRotationRecoveryRecord] = [:]
    private var saveHistoryStorage: [ClaudeRotationRecoveryRecord] = []
    var saveError: Error?
    var saveFailuresRemaining = 0
    var saveFailureAttempts: Set<Int> = []
    var saveErrorAfterSuccessfulSaves: Int?
    var deleteError: Error?
    var onSave: ((ClaudeRotationRecoveryRecord) -> Void)?
    private(set) var saveCount = 0
    private(set) var saveAttemptCount = 0
    private(set) var deleteCount = 0

    var records: [ClaudeRotationRecoveryRecord] {
        lock.withLock { storage.values.sorted { $0.createdAt < $1.createdAt } }
    }

    var saveHistory: [ClaudeRotationRecoveryRecord] {
        lock.withLock { saveHistoryStorage }
    }

    func save(
        _ record: ClaudeRotationRecoveryRecord,
        accessMode: CredentialAccessMode
    ) throws {
        saveAttemptCount += 1
        if saveFailureAttempts.remove(saveAttemptCount) != nil {
            throw CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        }
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        }
        if let threshold = saveErrorAfterSuccessfulSaves,
           saveCount >= threshold {
            throw CredentialStoreError.keychainError(errSecInteractionNotAllowed)
        }
        if let saveError { throw saveError }
        lock.withLock {
            saveCount += 1
            saveHistoryStorage.append(record)
            storage[record.id] = record
        }
        onSave?(record)
    }

    func loadAll(
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeRotationRecoveryRecord] {
        records
    }

    func delete(id: UUID, accessMode: CredentialAccessMode) throws {
        if let deleteError { throw deleteError }
        _ = lock.withLock {
            deleteCount += 1
            return storage.removeValue(forKey: id)
        }
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
    var storedReplaceResultOverrides: [UUID: Bool] = [:]
    var liveReplaceError: Error?
    var liveReplaceResultOverride: Bool?
    var onLiveRead: ((Int) -> Void)?
    var onStoredRead: ((Int) -> Void)?
    var onLiveReplaceCommitted: (() -> Void)?
    private(set) var accessModes: [CredentialAccessMode] = []
    private(set) var liveReadCount = 0
    private(set) var storedReadCount = 0
    private(set) var storedMutationCount = 0
    private(set) var preloadedStoredReplaceCount = 0
    private(set) var liveReplaceCount = 0

    func liveClaudeOAuthCredentialRecord(
        accessMode: CredentialAccessMode
    ) throws -> LiveClaudeOAuthCredentialRecord? {
        accessModes.append(accessMode)
        liveReadCount += 1
        onLiveRead?(liveReadCount)
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
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        liveReplaceCount += 1
        if let liveReplaceError {
            throw liveReplaceError
        }
        guard expectedItemLocation == liveLocation else { return false }
        guard live?.rawClaudeAiOauth == expectedCredentials.rawClaudeAiOauth else {
            return false
        }
        if let liveReplaceResultOverride {
            return liveReplaceResultOverride
        }
        live = credentials
        onLiveReplaceCommitted?()
        return true
    }

    func storedClaudeOAuthCredentials(
        for profileID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> ClaudeOAuthCredentials? {
        accessModes.append(accessMode)
        storedReadCount += 1
        onStoredRead?(storedReadCount)
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
        storedMutationCount += 1
        stored[profileID] = credentials
    }

    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        accessModes.append(accessMode)
        storedMutationCount += 1
        guard stored[profileID]?.rawClaudeAiOauth
                == expectedCredentials.rawClaudeAiOauth else { return false }
        if storedReplaceResultOverrides[profileID] == false {
            return false
        }
        if storedReplaceResultOverride == false {
            return false
        }
        stored[profileID] = credentials
        return true
    }

    func replaceStoredClaudeOAuthCredentials(
        _ credentials: ClaudeOAuthCredentials,
        for profileID: UUID,
        using storedRecord: StoredCredentialRecord,
        ifCurrentCredentialsMatch expectedCredentials: ClaudeOAuthCredentials,
        accessMode: CredentialAccessMode
    ) throws -> StoredCredentialRecord? {
        accessModes.append(accessMode)
        storedMutationCount += 1
        preloadedStoredReplaceCount += 1
        guard stored[profileID]?.rawClaudeAiOauth
                == expectedCredentials.rawClaudeAiOauth else { return nil }
        if let profileOverride = storedReplaceResultOverrides[profileID],
           !profileOverride {
            return nil
        }
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
    var nextError: Error?

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        onRequest?(request)
        if let nextError {
            self.nextError = nil
            throw nextError
        }
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
