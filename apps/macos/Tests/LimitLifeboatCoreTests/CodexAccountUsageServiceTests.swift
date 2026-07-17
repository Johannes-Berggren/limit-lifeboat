import Foundation
import XCTest
@testable import LimitLifeboatCore

final class CodexAccountUsageServiceTests: XCTestCase {
    func testSuccessfulFetchBuildsSnapshotReturnsRotatedAuthAndCleansTemporaryHome() async throws {
        let initial = try authJSON(accountID: "acct-1", accessToken: "old", refreshToken: "refresh-1")
        let updated = try authJSON(accountID: "acct-1", accessToken: "new", refreshToken: "refresh-2")
        let runner = FakeCodexUsageRunner(
            outcome: .success(
                accountEmail: "user@example.com",
                rateLimits: CodexRateLimitReading(
                    windows: [
                        CodexRateLimitWindowReading(
                            name: "primary",
                            usedPercent: 23,
                            windowMinutes: 300,
                            resetsAt: Date(timeIntervalSince1970: 1_783_093_420)
                        ),
                        CodexRateLimitWindowReading(
                            name: "secondary",
                            usedPercent: 86,
                            windowMinutes: 10_080,
                            resetsAt: Date(timeIntervalSince1970: 1_783_388_580)
                        )
                    ],
                    credits: CodexCreditsReading(hasCredits: true, unlimited: false, balance: "12.50"),
                    planType: "pro",
                    reachedType: nil
                )
            ),
            updatedAuthJSON: updated
        )
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(
            provider: .codex,
            label: "Codex",
            identity: AccountIdentity(
                email: "user@example.com",
                accountID: "acct-1",
                source: .codexIDToken
            )
        )

        let result = try await service.fetchSnapshot(
            for: profile,
            authJSON: initial,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: profile.identity,
            now: Date(timeIntervalSince1970: 1_783_000_000)
        )

        XCTAssertEqual(result.updatedAuthJSON, updated)
        XCTAssertEqual(result.accountInfo.planLabel, "Pro")
        XCTAssertEqual(result.snapshot.source, "Codex app server")
        XCTAssertEqual(result.snapshot.windows.map(\.id), ["codex-300", "codex-10080"])
        XCTAssertEqual(result.snapshot.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(result.snapshot.usedFraction ?? 0, 0.86, accuracy: 0.0001)
        XCTAssertEqual(result.snapshot.creditStatus, "Usage credits available: 12.50.")
        XCTAssertEqual(runner.initialAuthJSON, initial)
        XCTAssertEqual(runner.homePermissions, 0o700)
        XCTAssertEqual(runner.authPermissions, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.codexHome).path))
    }

    func testIdentityMismatchRejectsUsageAndCleansTemporaryHome() async throws {
        let runner = FakeCodexUsageRunner(
            outcome: .success(
                accountEmail: "user@example.com",
                rateLimits: reading(usedPercent: 10)
            )
        )
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(
            provider: .codex,
            label: "Expected",
            identity: AccountIdentity(accountID: "acct-expected", source: .codexIDToken)
        )

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                authJSON: try authJSON(accountID: "acct-other"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: profile.identity
            )
            XCTFail("Expected identity mismatch")
        } catch let error as CodexAccountUsageError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("different saved account"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.codexHome).path))
    }

    func testAccumulatorSelectsGeneralCodexBucketAndHandlesPartialOutOfOrderJSONL() throws {
        let accumulator = CodexUsageAppServerResponseAccumulator()
        let rateResponse = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex_spark":{"primary":{"usedPercent":70,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1783093420},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1783388580},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus","rateLimitReachedType":null}}}}"# + "\n"
        let accountResponse = #"{"method":"account/updated","params":{}}"# + "\n"
            + #"{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}"# + "\n"
        let combined = Data((rateResponse + accountResponse).utf8)
        let midpoint = combined.count / 2

        XCTAssertFalse(accumulator.append(combined.prefix(midpoint)))
        XCTAssertTrue(accumulator.append(combined.suffix(from: midpoint)))
        guard case .success(let email, let limits) = accumulator.outcome else {
            return XCTFail("Expected successful parsed usage")
        }
        XCTAssertEqual(email, "user@example.com")
        XCTAssertEqual(limits.windows.map(\.usedPercent), [12, 34])
        XCTAssertEqual(limits.planType, "plus")
    }

    func testAccumulatorClassifiesAuthenticationAndMalformedResponses() {
        let rejected = CodexUsageAppServerResponseAccumulator()
        XCTAssertTrue(
            rejected.append(Data((#"{"id":3,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"# + "\n").utf8))
        )
        guard case .requiresLogin = rejected.outcome else {
            return XCTFail("Expected requiresLogin")
        }

        let malformed = CodexUsageAppServerResponseAccumulator()
        XCTAssertTrue(
            malformed.append(Data((#"{"id":3,"result":{"rateLimits":{"primary":{"windowDurationMins":300}}}}"# + "\n").utf8))
        )
        guard case .unavailable = malformed.outcome else {
            return XCTFail("Expected unavailable")
        }
    }

    func testWeeklyPrimaryAndReachedLimitArePreserved() {
        let profile = AccountProfile(provider: .codex, label: "Weekly")
        let reading = CodexRateLimitReading(
            windows: [
                CodexRateLimitWindowReading(
                    name: "primary",
                    usedPercent: 42,
                    windowMinutes: 10_080,
                    resetsAt: Date(timeIntervalSince1970: 1_783_388_580)
                )
            ],
            credits: CodexCreditsReading(hasCredits: false, unlimited: false, balance: "0"),
            planType: "pro",
            reachedType: "rate_limit_reached"
        )

        let snapshot = CodexAccountUsageService.makeSnapshot(
            profile: profile,
            reading: reading,
            now: Date(timeIntervalSince1970: 1_783_000_000)
        )

        XCTAssertEqual(snapshot.windows.first?.kind, .weekly)
        XCTAssertEqual(snapshot.windows.first?.id, "codex-10080")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 42)
        XCTAssertEqual(snapshot.windows.first?.riskLevel, .depleted)
        XCTAssertEqual(snapshot.riskLevel, .depleted)
        XCTAssertEqual(snapshot.creditStatus, "Rate limit reached: rate_limit_reached.")
    }

    func testServiceCleansTemporaryHomeWhenRunnerIsUnavailable() async throws {
        let runner = FakeCodexUsageRunner(
            outcome: .unavailable(reason: "Unsupported method")
        )
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(provider: .codex, label: "Codex")

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil
            )
            XCTFail("Expected unavailable")
        } catch let error as CodexAccountUsageError {
            XCTAssertEqual(error, .unavailable(reason: "Unsupported method"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.codexHome).path))
    }

    func testAuthenticationFailureForcesOneRefreshBeforeReturningUsage() async throws {
        let updated = try authJSON(
            accountID: "acct-1",
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh"
        )
        let runner = FakeCodexUsageRunner(
            outcomes: [
                .requiresLogin(reason: "Access token expired"),
                .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 31))
            ],
            updatedAuthJSON: updated
        )
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(
            provider: .codex,
            label: "Codex",
            identity: AccountIdentity(accountID: "acct-1", source: .codexIDToken)
        )

        let result = try await service.fetchSnapshot(
            for: profile,
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: profile.identity
        )

        XCTAssertEqual(runner.forceRefreshValues, [false, true])
        XCTAssertEqual(result.updatedAuthJSON, updated)
        XCTAssertEqual(result.snapshot.windows.first?.usedPercent, 31)
    }

    func testRepeatedAuthenticationFailureRequiresLoginAfterOneForcedRefresh() async throws {
        let runner = FakeCodexUsageRunner(outcomes: [
            .requiresLogin(reason: "Access token expired"),
            .requiresLogin(reason: "Refresh token rejected")
        ])
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(provider: .codex, label: "Codex")

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil
            )
            XCTFail("Expected rejected forced refresh to require login")
        } catch let error as CodexAccountUsageError {
            XCTAssertEqual(error, .requiresLogin(reason: "Refresh token rejected"))
        }
        XCTAssertEqual(runner.forceRefreshValues, [false, true])
    }

    func testServerFailureAfterForcedRefreshRemainsRetryable() async throws {
        let runner = FakeCodexUsageRunner(outcomes: [
            .requiresLogin(reason: "Access token expired"),
            .unavailable(reason: "Codex server unavailable")
        ])
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(provider: .codex, label: "Codex")

        do {
            _ = try await service.fetchSnapshot(
                for: profile,
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil
            )
            XCTFail("Expected a retryable server failure")
        } catch let error as CodexAccountUsageError {
            XCTAssertEqual(error, .unavailable(reason: "Codex server unavailable"))
        }
        XCTAssertEqual(runner.forceRefreshValues, [false, true])
    }

    func testProcessRunnerSendsStableRequestsAndParsesResponses() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        IFS= read -r initialize
        IFS= read -r initialized
        IFS= read -r account_read
        IFS= read -r rate_limits
        printf '%s\\n' '{"id":1,"result":{}}'
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}'
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1783093420},"planType":"pro"}}}'
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexUsageAppServerProcessRunner().readUsage(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: false,
            timeout: 2
        )

        guard case .success(let email, let reading) = outcome else {
            return XCTFail("Expected success, got \(outcome)")
        }
        XCTAssertEqual(email, "user@example.com")
        XCTAssertEqual(reading.windows.first?.usedPercent, 25)
    }

    func testProcessRunnerTimeoutIsTransient() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        sleep 5
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexUsageAppServerProcessRunner().readUsage(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: false,
            timeout: 0.05
        )

        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected unavailable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("timed out"))
    }

    func testProcessRunnerSendsForcedRefreshRequestWhenRequested() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        IFS= read -r initialize
        IFS= read -r initialized
        IFS= read -r account_read
        IFS= read -r rate_limits
        printf '%s' "$account_read" > "$CODEX_HOME/account-read.json"
        printf '%s\\n' '{"id":1,"result":{}}'
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}'
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}'
        """)
        defer { fixture.cleanup() }

        _ = await CodexUsageAppServerProcessRunner().readUsage(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: true,
            timeout: 2
        )

        let request = try String(
            contentsOf: fixture.directory.appendingPathComponent("account-read.json"),
            encoding: .utf8
        )
        XCTAssertTrue(request.contains(#""refreshToken":true"#))
    }

    func testProcessRunnerEarlyExitIsTransient() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        exit 7
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexUsageAppServerProcessRunner().readUsage(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: false,
            timeout: 2
        )

        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected unavailable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("ended before returning"))
    }

    private func reading(usedPercent: Double) -> CodexRateLimitReading {
        CodexRateLimitReading(
            windows: [
                CodexRateLimitWindowReading(
                    name: "primary",
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: nil
                )
            ],
            credits: nil,
            planType: "pro",
            reachedType: nil
        )
    }

    private func authJSON(
        accountID: String,
        accessToken: String = "access",
        refreshToken: String = "refresh"
    ) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_plan_type": "pro"
            ]
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

private final class FakeCodexUsageRunner: CodexUsageAppServerRunning, @unchecked Sendable {
    private var outcomes: [CodexUsageAppServerOutcome]
    let updatedAuthJSON: Data?
    private(set) var codexHome: URL?
    private(set) var initialAuthJSON: Data?
    private(set) var homePermissions: Int?
    private(set) var authPermissions: Int?
    private(set) var forceRefreshValues: [Bool] = []

    init(outcome: CodexUsageAppServerOutcome, updatedAuthJSON: Data? = nil) {
        self.outcomes = [outcome]
        self.updatedAuthJSON = updatedAuthJSON
    }

    init(outcomes: [CodexUsageAppServerOutcome], updatedAuthJSON: Data? = nil) {
        self.outcomes = outcomes
        self.updatedAuthJSON = updatedAuthJSON
    }

    func readUsage(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        timeout: TimeInterval
    ) async -> CodexUsageAppServerOutcome {
        forceRefreshValues.append(forceRefresh)
        self.codexHome = codexHome
        let authURL = codexHome.appendingPathComponent("auth.json")
        initialAuthJSON = try? Data(contentsOf: authURL)
        homePermissions = permissions(at: codexHome)
        authPermissions = permissions(at: authURL)
        if let updatedAuthJSON {
            try? updatedAuthJSON.write(to: authURL, options: .atomic)
        }
        guard !outcomes.isEmpty else {
            return .unavailable(reason: "Fake runner exhausted")
        }
        return outcomes.removeFirst()
    }

    private func permissions(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }
}

private struct UsageExecutableScriptFixture {
    let directory: URL
    let executable: URL

    init(contents: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-runner-test-\(UUID().uuidString)", isDirectory: true)
        executable = directory.appendingPathComponent("fake-codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try contents.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
