import XCTest
@testable import LimitLifeboatCore

final class ProfileRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboatProfileTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadReturnsEmptyWhenFileMissing() throws {
        let repository = try ProfileRepository(applicationSupportDirectory: root)
        XCTAssertEqual(try repository.loadProfiles(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles.json").path))
    }

    func testNamedApplicationSupportDirectorySelectsRequestedNamespace() throws {
        let fileManager = ApplicationSupportFileManager(baseURL: root)
        let repository = try ProfileRepository(
            applicationSupportDirectoryName: "LimitLifeboat-Dev",
            fileManager: fileManager
        )

        XCTAssertEqual(
            repository.applicationSupportDirectory,
            root.appendingPathComponent("LimitLifeboat-Dev", isDirectory: true)
        )
    }

    func testSaveLoadRoundTripPreservesProfiles() throws {
        let repository = try ProfileRepository(applicationSupportDirectory: root)
        // ISO8601 encoding has whole-second precision, so use whole-second dates.
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let profiles = [
            AccountProfile(
                provider: .claude,
                label: "Work",
                webDataStoreKind: .appDefault,
                identity: AccountIdentity(email: "work@example.com", accountID: "acct-1", source: .claudeCodeUsage, updatedAt: date),
                isActiveCLI: true,
                createdAt: date,
                updatedAt: date
            ),
            AccountProfile(provider: .claude, label: "Personal", createdAt: date, updatedAt: date),
            AccountProfile(provider: .codex, label: "Codex", createdAt: date, updatedAt: date),
        ]
        try repository.saveProfiles(profiles)

        XCTAssertEqual(try repository.loadProfiles(), profiles)
    }

    func testLoadDecodesCurrentDiskFormatAndDefaultsMissingStoreKind() throws {
        // On-disk format written by the previous app version, including a
        // profile without webDataStoreKind (pre-migration files).
        let json = """
        [
          {
            "createdAt": "2025-06-01T10:00:00Z",
            "id": "11111111-1111-1111-1111-111111111111",
            "identity": {
              "email": "a@example.com",
              "source": "codexIDToken",
              "updatedAt": "2025-06-01T10:00:00Z"
            },
            "isActiveCLI": true,
            "label": "ChatGPT/Codex 1",
            "planLabel": "",
            "provider": "codex",
            "updatedAt": "2025-06-01T10:00:00Z",
            "webDataStoreID": "22222222-2222-2222-2222-222222222222",
            "webDataStoreKind": "appDefault"
          },
          {
            "createdAt": "2025-06-01T10:00:00Z",
            "id": "33333333-3333-3333-3333-333333333333",
            "isActiveCLI": false,
            "label": "Claude 2",
            "planLabel": "",
            "provider": "claude",
            "updatedAt": "2025-06-01T10:00:00Z",
            "webDataStoreID": "44444444-4444-4444-4444-444444444444"
          }
        ]
        """
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("profiles.json"))

        let repository = try ProfileRepository(applicationSupportDirectory: root)
        let profiles = try repository.loadProfiles()

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].id.uuidString, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(profiles[0].webDataStoreKind, .appDefault)
        XCTAssertEqual(profiles[0].identity?.email, "a@example.com")
        XCTAssertTrue(profiles[0].isActiveCLI)
        XCTAssertEqual(profiles[1].webDataStoreKind, .isolated)
        XCTAssertNil(profiles[1].identity)
    }

    func testLoadClearsInvalidIdentity() throws {
        let repository = try ProfileRepository(applicationSupportDirectory: root)
        let garbageIdentity = AccountIdentity(organization: "Try Claude Pricing plans", source: .dashboard)
        try repository.saveProfiles([
            AccountProfile(provider: .claude, label: "Claude", identity: garbageIdentity)
        ])

        let loaded = try repository.loadProfiles()

        XCTAssertNil(loaded[0].identity)
    }

    func testLoadKeepsProfileOrderAndStoreKinds() throws {
        // With user-managed profiles there is no first-per-provider rewrite:
        // stored kinds must survive a load untouched.
        let repository = try ProfileRepository(applicationSupportDirectory: root)
        let profiles = [
            AccountProfile(provider: .claude, label: "One", webDataStoreKind: .isolated),
            AccountProfile(provider: .claude, label: "Two", webDataStoreKind: .isolated),
        ]
        try repository.saveProfiles(profiles)

        let loaded = try repository.loadProfiles()

        XCTAssertEqual(loaded.map(\.label), ["One", "Two"])
        XCTAssertEqual(loaded.map(\.webDataStoreKind), [.isolated, .isolated])
    }
}

private final class ApplicationSupportFileManager: FileManager {
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask == .userDomainMask {
            return [baseURL]
        }
        return super.urls(for: directory, in: domainMask)
    }
}
