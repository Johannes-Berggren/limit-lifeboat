import XCTest
@testable import LimitLifeboatCore

final class CodexCredentialStoreModeTests: XCTestCase {
    func testMissingSettingIsFileStore() {
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: "model = \"gpt-6.1-sol\"\n"), .file)
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: ""), .file)
    }

    func testReadsTopLevelValues() {
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: "cli_auth_credentials_store = \"keyring\""), .keyring)
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: "cli_auth_credentials_store='auto' # macOS"), .auto)
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: "cli_auth_credentials_store = \"ephemeral\""), .ephemeral)
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: "cli_auth_credentials_store = \"file\""), .file)
        XCTAssertEqual(
            CodexCredentialStoreMode.parse(configTOML: "cli_auth_credentials_store = \"vault\""),
            .unrecognized("vault")
        )
    }

    func testIgnoresCommentsAndTableScopedKeys() {
        let toml = """
        # cli_auth_credentials_store = "keyring"
        model = "gpt-6.1-sol"

        [profiles.work]
        cli_auth_credentials_store = "keyring"
        """
        XCTAssertEqual(CodexCredentialStoreMode.parse(configTOML: toml), .file)
    }

    func testOnlyFileStoreSupportsSwitching() {
        XCTAssertTrue(CodexCredentialStoreMode.file.supportsFileSwitching)
        XCTAssertFalse(CodexCredentialStoreMode.keyring.supportsFileSwitching)
        XCTAssertFalse(CodexCredentialStoreMode.auto.supportsFileSwitching)
        XCTAssertFalse(CodexCredentialStoreMode.ephemeral.supportsFileSwitching)
    }
}
