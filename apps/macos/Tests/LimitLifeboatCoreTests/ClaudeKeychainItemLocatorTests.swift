import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import LimitLifeboatCore

final class ClaudeKeychainItemLocatorTests: XCTestCase {
    private let service = "Claude Code-credentials"
    private let account = "test-user"

    func testDiscoveryQuerySearchesEntireSearchListWithoutRequestingSecretData() {
        let query = ClaudeKeychainQuery.discovery(
            serviceName: service,
            accountName: account,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account)
        XCTAssertNil(query[kSecMatchSearchList as String], "Omitting a search list searches the user's configured list")
        XCTAssertNil(query[kSecReturnData as String], "Metadata polling must not decrypt the secret")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnPersistentRef as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnRef as String] as? Bool, true)
        XCTAssertTrue(cfEqual(query[kSecMatchLimit as String], kSecMatchLimitAll))
        XCTAssertEqual(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed,
            true
        )
    }

    func testPinnedQueryUsesOnlyPersistentItemReference() throws {
        let location = makeLocation(path: "/tmp/custom.keychain-db", reference: Data("exact".utf8))
        let query = ClaudeKeychainQuery.pinned(to: location, accessMode: .nonInteractive)

        XCTAssertEqual(
            try XCTUnwrap(query[kSecMatchItemList as String] as? [Data]),
            [location.persistentReference]
        )
        XCTAssertEqual(query[kSecAttrService as String] as? String, service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, account)
        XCTAssertNil(query[kSecValuePersistentRef as String])
        XCTAssertEqual(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed,
            true
        )
    }

    func testUserInitiatedPinnedQueryAllowsNativeAuthorizationUI() {
        let query = ClaudeKeychainQuery.pinned(
            to: makeLocation(),
            accessMode: .userInitiated
        )

        XCTAssertEqual(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed,
            false
        )
    }

    func testResolvedCustomKeychainItemPinsReadAndWrite() throws {
        let location = makeLocation(path: "/Volumes/Test/custom.keychain-db")
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        client.data = Data("one".utf8)
        let keychain = makeKeychain(client: client)

        XCTAssertEqual(try keychain.locateLiveItem(accessMode: .nonInteractive), location)
        XCTAssertEqual(try keychain.readLiveItemJSON(accessMode: .nonInteractive), client.data)
        try keychain.writeLiveItemJSON(Data("two".utf8), accessMode: .userInitiated)

        XCTAssertEqual(client.locateCalls.count, 10)
        XCTAssertEqual(client.readCalls.map(\.location), [location, location])
        XCTAssertEqual(client.updateCalls.map(\.location), [location])
    }

    func testExactItemMethodsRevalidatePersistentIdentityAroundDataAccess() throws {
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        client.data = Data("secret".utf8)
        let keychain = makeKeychain(client: client)

        XCTAssertEqual(
            try keychain.readLiveItemJSON(at: location, accessMode: .nonInteractive),
            client.data
        )
        try keychain.writeLiveItemJSON(
            Data("updated".utf8),
            at: location,
            accessMode: .userInitiated
        )
        XCTAssertThrowsError(
            try keychain.deleteLiveItem(at: location, accessMode: .nonInteractive)
        )

        XCTAssertEqual(client.locateCalls.count, 7)
        XCTAssertEqual(client.readCalls.map(\.location), [location, location])
        XCTAssertEqual(client.updateCalls.map(\.location), [location])
    }

    func testDuplicateItemsAreRejectedBeforeSecretAccessOrMutation() {
        let first = makeLocation(path: "/tmp/login.keychain-db", reference: Data("first".utf8))
        let second = makeLocation(path: "/tmp/custom.keychain-db", reference: Data("second".utf8))
        let client = FakeClaudeKeychainSecurityClient(items: [first, second])
        let keychain = makeKeychain(client: client)

        XCTAssertThrowsError(try keychain.readLiveItemJSON(accessMode: .nonInteractive)) { error in
            guard case ClaudeCodeCredentialsKeychainError.duplicateLiveItems(let items) = error else {
                return XCTFail("Expected duplicateLiveItems, got \(error)")
            }
            XCTAssertEqual(items, [first, second])
        }
        XCTAssertThrowsError(
            try keychain.writeLiveItemJSON(Data("new".utf8), accessMode: .userInitiated)
        )
        XCTAssertThrowsError(try keychain.deleteLiveItem(accessMode: .userInitiated))

        XCTAssertTrue(client.readCalls.isEmpty)
        XCTAssertTrue(client.updateCalls.isEmpty)
    }

    func testMismatchedExactLocationIsRejectedBeforeSecretAccess() {
        let client = FakeClaudeKeychainSecurityClient(items: [])
        let keychain = makeKeychain(client: client)
        let wrongAccount = ClaudeKeychainItemLocation(
            serviceName: service,
            accountName: "someone-else",
            keychainPath: "/tmp/custom.keychain-db",
            persistentReference: Data("reference".utf8),
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2)
        )

        XCTAssertThrowsError(
            try keychain.readLiveItemJSON(at: wrongAccount, accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.itemIdentityMismatch = error else {
                return XCTFail("Expected itemIdentityMismatch, got \(error)")
            }
        }
        XCTAssertTrue(client.readCalls.isEmpty)
    }

    func testMissingOrReplacedResolvedItemHasSafeSemantics() throws {
        let client = FakeClaudeKeychainSecurityClient(items: [])
        let keychain = makeKeychain(client: client)

        XCTAssertNil(try keychain.locateLiveItem(accessMode: .nonInteractive))
        XCTAssertNil(try keychain.readLiveItemJSON(accessMode: .nonInteractive))
        XCTAssertNoThrow(try keychain.deleteLiveItem(accessMode: .nonInteractive))
        XCTAssertThrowsError(
            try keychain.writeLiveItemJSON(Data("never-created".utf8), accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.missingLiveItem = error else {
                return XCTFail("Expected missingLiveItem, got \(error)")
            }
        }

        client.items = [makeLocation()]
        client.updateSucceeds = false
        XCTAssertThrowsError(
            try keychain.writeLiveItemJSON(Data("replacement-race".utf8), accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.securityToolError(.itemChanged) = error else {
                return XCTFail("Expected itemChanged after replacement, got \(error)")
            }
        }
    }

    func testModificationStampDetectsUpdateAndReplacementWithoutSecretData() {
        let original = makeLocation(reference: Data("one".utf8), modifiedAt: 20)
        let updated = makeLocation(reference: Data("one".utf8), modifiedAt: 21)
        let replaced = makeLocation(reference: Data("two".utf8), modifiedAt: 21)

        XCTAssertNotEqual(original.modificationStamp, updated.modificationStamp)
        XCTAssertNotEqual(updated.modificationStamp, replaced.modificationStamp)
        XCTAssertEqual(original.identity, original.modificationStamp.identity)
    }

    func testDeniedGenerationSuppressesAutomaticReadsUntilMetadataChanges() {
        let denied = makeLocation(reference: Data("one".utf8), modifiedAt: 20)
        let unchanged = makeLocation(reference: Data("one".utf8), modifiedAt: 20)
        let modified = makeLocation(reference: Data("one".utf8), modifiedAt: 21)
        let replaced = makeLocation(reference: Data("two".utf8), modifiedAt: 20)
        let state = ClaudeKeychainAuthorizationState.needsAuthorization(
            item: denied,
            disposition: .interactionRequired
        )

        XCTAssertTrue(state.suppressesAutomaticDataRead(currentItem: unchanged))
        XCTAssertTrue(state.suppressesAutomaticDataRead(currentItem: nil))
        XCTAssertFalse(state.suppressesAutomaticDataRead(currentItem: modified))
        XCTAssertFalse(state.suppressesAutomaticDataRead(currentItem: replaced))
    }

    func testBackgroundAccessGateNeverInvokesLiveBackendWhenAuthorizationIsMissing() throws {
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        client.data = Data("secret".utf8)
        client.accessStatus = .needsAuthorization
        let keychain = makeKeychain(client: client)

        XCTAssertThrowsError(
            try keychain.readLiveItemJSON(accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.securityToolError(
                .authorizationDenied
            ) = error else {
                return XCTFail("Expected authorizationDenied, got \(error)")
            }
        }
        XCTAssertTrue(client.readCalls.isEmpty)

        XCTAssertEqual(
            try keychain.readLiveItemJSON(accessMode: .userInitiated),
            client.data
        )
        XCTAssertEqual(client.readCalls.count, 1)
    }

    func testBackgroundAccessGateNeverInvokesLiveBackendWhenKeychainIsLocked() {
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        client.data = Data("secret".utf8)
        client.accessStatus = .keychainLocked
        let keychain = makeKeychain(client: client)

        XCTAssertThrowsError(
            try keychain.readLiveItemJSON(accessMode: .nonInteractive)
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.securityToolError(
                .keychainLocked
            ) = error else {
                return XCTFail("Expected keychainLocked, got \(error)")
            }
        }
        XCTAssertTrue(client.readCalls.isEmpty)
    }

    func testWriteVerifiesCompleteStoredValueAfterHelperSuccess() {
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        client.data = Data("before".utf8)
        client.corruptDataAfterUpdate = true
        let keychain = makeKeychain(client: client)

        XCTAssertThrowsError(
            try keychain.writeLiveItemJSON(
                Data("expected".utf8),
                accessMode: .nonInteractive
            )
        ) { error in
            guard case ClaudeCodeCredentialsKeychainError.securityToolError(
                .verificationFailed
            ) = error else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
        }
        XCTAssertEqual(client.updateCalls.count, 1)
        XCTAssertEqual(client.readCalls.count, 1)
    }

    func testWriteRevalidatesMutationLeaseAfterAccessPreflight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-KeychainLease-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(heartbeatInterval: 60),
            environment: [:]
        )
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        let displacedLock = root.appendingPathComponent(
            "original-storage-write-lock",
            isDirectory: true
        )
        client.accessStatusHook = {
            try FileManager.default.moveItem(
                at: coordinator.storageWriteLockURL,
                to: displacedLock
            )
            try FileManager.default.createDirectory(
                at: coordinator.storageWriteLockURL,
                withIntermediateDirectories: false
            )
        }
        let keychain = makeKeychain(client: client)

        var caught: Error?
        do {
            try await coordinator.withLease { _ in
                try keychain.writeLiveItemJSON(
                    Data("must-not-write".utf8),
                    at: location,
                    accessMode: .nonInteractive
                )
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(
            caught as? ClaudeOAuthRefreshCoordinatorError,
            .leaseLost(lock: .storageWrite)
        )
        XCTAssertTrue(client.updateCalls.isEmpty)
    }

    func testWriteRevalidatesMutationLeaseAfterHelperReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LimitLifeboat-KeychainPostLease-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = ClaudeOAuthRefreshCoordinator(
            homeDirectory: home,
            configuration: .init(heartbeatInterval: 60),
            environment: [:]
        )
        let location = makeLocation()
        let client = FakeClaudeKeychainSecurityClient(items: [location])
        let displacedLock = root.appendingPathComponent(
            "original-storage-write-lock",
            isDirectory: true
        )
        client.afterUpdateHook = {
            try FileManager.default.moveItem(
                at: coordinator.storageWriteLockURL,
                to: displacedLock
            )
            try FileManager.default.createDirectory(
                at: coordinator.storageWriteLockURL,
                withIntermediateDirectories: false
            )
        }
        let keychain = makeKeychain(client: client)

        var caught: Error?
        do {
            try await coordinator.withLease { _ in
                try keychain.writeLiveItemJSON(
                    Data("write-completed-before-lease-loss".utf8),
                    at: location,
                    accessMode: .nonInteractive
                )
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(
            caught as? ClaudeOAuthRefreshCoordinatorError,
            .leaseLost(lock: .storageWrite)
        )
        XCTAssertEqual(client.updateCalls.count, 1)
    }

    func testUnanchoredDenialAndFailedStateAreFailClosed() {
        let current = makeLocation()

        XCTAssertTrue(
            ClaudeKeychainAuthorizationState.needsAuthorization(
                item: nil,
                disposition: .userCancelled
            ).suppressesAutomaticDataRead(currentItem: current)
        )
        XCTAssertTrue(
            ClaudeKeychainAuthorizationState.failed(message: "ambiguous")
                .suppressesAutomaticDataRead(currentItem: current)
        )
        XCTAssertTrue(
            ClaudeKeychainAuthorizationState.notFound
                .suppressesAutomaticDataRead(currentItem: nil)
        )
        XCTAssertFalse(
            ClaudeKeychainAuthorizationState.notFound
                .suppressesAutomaticDataRead(currentItem: current)
        )
        XCTAssertFalse(
            ClaudeKeychainAuthorizationState.keychainLocked(current)
                .suppressesAutomaticDataRead(currentItem: current)
        )
    }

    func testCredentialAccessDispositionSeparatesCancellationAndAuthorization() {
        XCTAssertEqual(
            CredentialAccessDisposition(status: errSecInteractionNotAllowed),
            .interactionRequired
        )
        XCTAssertEqual(
            CredentialAccessDisposition(status: errSecInteractionRequired),
            .interactionRequired
        )
        XCTAssertEqual(CredentialAccessDisposition(status: errSecAuthFailed), .interactionRequired)
        XCTAssertEqual(CredentialAccessDisposition(status: errSecUserCanceled), .userCancelled)
        XCTAssertEqual(
            CredentialAccessDisposition(status: errSecCSStaticCodeChanged),
            .codeSignatureInvalid
        )
        XCTAssertEqual(CredentialAccessDisposition(status: errSecNotAvailable), .unavailable)
        XCTAssertEqual(CredentialAccessDisposition(status: errSecDecode), .other(errSecDecode))
    }

    func testPartitionACLDescriptionDecoderIsStrictAndPreservesUnknownEntries() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "Partitions": [
                    "apple-tool:",
                    "teamid:3DQ7YC2YH2",
                    "future-client:opaque"
                ],
                "FutureKey": ["preserve": true]
            ],
            format: .xml,
            options: 0
        )
        let encoded = plist.map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            ClaudeSecurityToolPartitionList.decode(encoded),
            ["apple-tool:", "teamid:3DQ7YC2YH2", "future-client:opaque"]
        )
        XCTAssertNil(ClaudeSecurityToolPartitionList.decode("0"))
        XCTAssertNil(ClaudeSecurityToolPartitionList.decode("zz"))
        XCTAssertNil(ClaudeSecurityToolPartitionList.decode("é"))

        let missingPartitions = try PropertyListSerialization.data(
            fromPropertyList: ["Other": true],
            format: .xml,
            options: 0
        )
        XCTAssertNil(
            ClaudeSecurityToolPartitionList.decode(
                missingPartitions.map { String(format: "%02x", $0) }.joined()
            )
        )
    }

    func testCoreErrorsPreserveTypedCredentialDisposition() {
        let cancelled = ClaudeCodeCredentialsKeychainError.keychainError(errSecUserCanceled)
        XCTAssertEqual(cancelled.credentialAccessDisposition, .userCancelled)
        XCTAssertTrue(cancelled.isKeychainAccessDenied)

        let unavailable = CredentialStoreError.keychainError(errSecNotAvailable)
        XCTAssertEqual(unavailable.credentialAccessDisposition, .unavailable)
        XCTAssertFalse(unavailable.isKeychainAccessDenied)

        let replaced = RunningExecutableIntegrityError.replaced(path: "/tmp/app")
        let integrity = CredentialStoreError.credentialAccessUnavailable(underlying: replaced)
        XCTAssertEqual(integrity.credentialAccessDisposition, .codeSignatureInvalid)

        let mismatch = ClaudeCodeCredentialsKeychainError.securityToolError(
            .verificationFailed
        )
        XCTAssertEqual(mismatch.credentialAccessDisposition, .unavailable)
    }

    func testAuthorizationStateAndLocationsAreSendable() {
        assertSendable(ClaudeKeychainAuthorizationState.self)
        assertSendable(ClaudeKeychainItemLocation.self)
        assertSendable(ClaudeKeychainItemModificationStamp.self)
        assertSendable(CredentialAccessDisposition.self)
    }

    private func makeKeychain(
        client: FakeClaudeKeychainSecurityClient
    ) -> ClaudeCodeCredentialsKeychain {
        ClaudeCodeCredentialsKeychain(
            serviceName: service,
            accountName: account,
            securityClient: client,
            liveCredentialBackend: client
        )
    }

    private func makeLocation(
        path: String = "/tmp/login.keychain-db",
        reference: Data = Data("persistent-reference".utf8),
        modifiedAt: TimeInterval = 2
    ) -> ClaudeKeychainItemLocation {
        ClaudeKeychainItemLocation(
            serviceName: service,
            accountName: account,
            keychainPath: path,
            persistentReference: reference,
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: modifiedAt)
        )
    }

    private func cfEqual(_ lhs: Any?, _ rhs: CFTypeRef) -> Bool {
        guard let lhs else { return false }
        return CFEqual(lhs as CFTypeRef, rhs)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}
}

private final class FakeClaudeKeychainSecurityClient:
    @unchecked Sendable,
    ClaudeKeychainSecurityClient,
    ClaudeLiveCredentialBackend
{
    struct LocateCall {
        let serviceName: String
        let accountName: String
        let accessMode: CredentialAccessMode
    }

    struct ItemCall {
        let location: ClaudeKeychainItemLocation
        let accessMode: CredentialAccessMode
    }

    struct UpdateCall {
        let data: Data
        let location: ClaudeKeychainItemLocation
        let accessMode: CredentialAccessMode
    }

    var items: [ClaudeKeychainItemLocation]
    var data: Data?
    var updateSucceeds = true
    var corruptDataAfterUpdate = false
    var accessStatus = ClaudeSecurityToolAccessStatus.ready
    var accessStatusHook: (() throws -> Void)?
    var afterUpdateHook: (() throws -> Void)?
    private(set) var locateCalls: [LocateCall] = []
    private(set) var readCalls: [ItemCall] = []
    private(set) var updateCalls: [UpdateCall] = []

    init(items: [ClaudeKeychainItemLocation]) {
        self.items = items
    }

    func locateItems(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeKeychainItemLocation] {
        locateCalls.append(
            LocateCall(
                serviceName: serviceName,
                accountName: accountName,
                accessMode: accessMode
            )
        )
        return items
    }

    func securityToolAccessStatus(
        at location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolAccessStatus {
        try accessStatusHook?()
        return accessStatus
    }

    func readData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool
    ) throws -> Data {
        try authorizeAccess(accessMode)
        guard try verifyBefore() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        readCalls.append(ItemCall(location: location, accessMode: accessMode))
        guard try verifyAfter() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        return data ?? Data()
    }

    func updateData(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool,
        mutationAttempt: ClaudeCredentialWriteAttempt?
    ) throws {
        try authorizeAccess(accessMode)
        guard try verifyBefore() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        mutationAttempt?.markHelperStarted()
        updateCalls.append(
            UpdateCall(data: data, location: location, accessMode: accessMode)
        )
        mutationAttempt?.markHelperSucceeded()
        try afterUpdateHook?()
        guard updateSucceeds, try verifyAfter() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        self.data = corruptDataAfterUpdate ? Data("corrupt".utf8) : data
    }
}
