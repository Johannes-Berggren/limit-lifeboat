import Foundation
import XCTest
@testable import LimitLifeboatCore

final class CodexAuthPreflightServiceTests: XCTestCase {
    func testSuccessfulRefreshReturnsUpdatedCredentialsAndCleansTemporaryHome() async throws {
        let initial = try authJSON(accountID: "acct-1", accessToken: "old", refreshToken: "refresh-1")
        let updated = try authJSON(accountID: "acct-1", accessToken: "new", refreshToken: "refresh-2")
        let runner = FakeCodexAppServerRunner(
            outcome: .success(accountEmail: "user@example.com"),
            updatedAuthJSON: updated
        )
        let service = CodexAuthPreflightService(runner: runner)

        let result = await service.preflight(
            authJSON: initial,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: AccountIdentity(accountID: "acct-1", source: .codexIDToken)
        )

        XCTAssertEqual(result, .ready(updatedAuthJSON: updated))
        XCTAssertEqual(runner.initialAuthJSON, initial)
        XCTAssertEqual(runner.homePermissions, 0o700)
        XCTAssertEqual(runner.authPermissions, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.codexHome).path))
    }

    func testAuthenticationRejectionRequiresLoginAndCleansTemporaryHome() async throws {
        let runner = FakeCodexAppServerRunner(
            outcome: .requiresLogin(reason: "The refresh token was already used.")
        )
        let service = CodexAuthPreflightService(runner: runner)

        let result = await service.preflight(
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: nil
        )

        XCTAssertEqual(result, .requiresLogin(reason: "The refresh token was already used."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.codexHome).path))
    }

    func testIdentityMismatchNeverReturnsRefreshedCredentials() async throws {
        let updated = try authJSON(accountID: "other-account", accessToken: "new", refreshToken: "refresh-2")
        let runner = FakeCodexAppServerRunner(
            outcome: .success(accountEmail: "user@example.com"),
            updatedAuthJSON: updated
        )
        let service = CodexAuthPreflightService(runner: runner)

        let result = await service.preflight(
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: AccountIdentity(accountID: "acct-1", source: .codexIDToken)
        )

        guard case .temporarilyUnavailable(let reason) = result else {
            return XCTFail("Expected identity mismatch to be unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("different account"))
    }

    func testSuccessfulProcessWithoutSubscriptionTokensRequiresLogin() async throws {
        let runner = FakeCodexAppServerRunner(
            outcome: .success(accountEmail: nil),
            updatedAuthJSON: Data(#"{"auth_mode":"chatgpt"}"#.utf8)
        )
        let service = CodexAuthPreflightService(runner: runner)

        let result = await service.preflight(
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: nil
        )

        guard case .requiresLogin = result else {
            return XCTFail("Expected missing tokens to require login, got \(result)")
        }
    }

    func testReturnedAccountIdentityMustMatchRefreshedCredentials() async throws {
        let updated = try authJSON(accountID: "acct-1", accessToken: "new", refreshToken: "refresh-2")
        let runner = FakeCodexAppServerRunner(
            outcome: .success(accountEmail: "different@example.com"),
            updatedAuthJSON: updated
        )
        let service = CodexAuthPreflightService(runner: runner)

        let result = await service.preflight(
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: nil
        )

        guard case .temporarilyUnavailable(let reason) = result else {
            return XCTFail("Expected returned account mismatch to be unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("identity"))
    }

    func testAppServerResponseClassifierDistinguishesAuthenticationFromTransientFailure() throws {
        let rejected = CodexAppServerResponseAccumulator()
        XCTAssertTrue(
            rejected.append(Data((#"{"id":2,"error":{"message":"refresh token was already used"}}"# + "\n").utf8))
        )
        guard case .requiresLogin = rejected.outcome else {
            return XCTFail("Expected authentication rejection")
        }

        let transient = CodexAppServerResponseAccumulator()
        XCTAssertTrue(
            transient.append(Data((#"{"id":2,"error":{"message":"server overloaded"}}"# + "\n").utf8))
        )
        guard case .unavailable = transient.outcome else {
            return XCTFail("Expected transient failure")
        }
    }

    func testProcessRunnerSendsAppServerRequestsAndParsesSuccess() async throws {
        let fixture = try ExecutableScriptFixture(contents: """
        #!/bin/sh
        IFS= read -r initialize
        IFS= read -r initialized
        IFS= read -r account_read
        printf '%s\\n' '{"id":1,"result":{}}'
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}'
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexAppServerProcessRunner().forceRefresh(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            timeout: 2
        )

        XCTAssertEqual(outcome, .success(accountEmail: "user@example.com"))
    }

    func testProcessRunnerTimeoutIsTransient() async throws {
        let fixture = try ExecutableScriptFixture(contents: """
        #!/bin/sh
        sleep 5
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexAppServerProcessRunner().forceRefresh(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            timeout: 0.05
        )

        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected timeout to be unavailable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("timed out"))
    }

    private func authJSON(
        accountID: String,
        accessToken: String = "access",
        refreshToken: String = "refresh"
    ) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "user@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
        ], options: [.sortedKeys])
        let encodedPayload = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": accountID,
                "id_token": "header.\(encodedPayload).signature"
            ]
        ], options: [.sortedKeys])
    }
}

private struct ExecutableScriptFixture {
    let directory: URL
    let executable: URL

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-preflight-runner-test-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("fake-codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class FakeCodexAppServerRunner: CodexAppServerRunning, @unchecked Sendable {
    let outcome: CodexAppServerRefreshOutcome
    let updatedAuthJSON: Data?
    private(set) var codexHome: URL?
    private(set) var initialAuthJSON: Data?
    private(set) var homePermissions: Int?
    private(set) var authPermissions: Int?

    init(outcome: CodexAppServerRefreshOutcome, updatedAuthJSON: Data? = nil) {
        self.outcome = outcome
        self.updatedAuthJSON = updatedAuthJSON
    }

    func forceRefresh(
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) async -> CodexAppServerRefreshOutcome {
        self.codexHome = codexHome
        let authURL = codexHome.appendingPathComponent("auth.json")
        self.initialAuthJSON = try? Data(contentsOf: authURL)
        self.homePermissions = permissions(at: codexHome)
        self.authPermissions = permissions(at: authURL)
        if let updatedAuthJSON {
            try? updatedAuthJSON.write(to: authURL, options: .atomic)
        }
        return outcome
    }

    private func permissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }
}
