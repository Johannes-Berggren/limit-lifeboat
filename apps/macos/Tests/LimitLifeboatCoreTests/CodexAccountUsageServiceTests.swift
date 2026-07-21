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
        let rateResponse = #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex_spark":{"primary":{"usedPercent":70,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1783093420},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1783388580},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"plus","rateLimitReachedType":"rate_limit_reached"}},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"reset-1","resetType":"codexRateLimits","status":"available","grantedAt":1781654400,"expiresAt":1784246400,"title":"Full reset","description":"Ready to redeem"}]}}}"# + "\n"
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
        XCTAssertEqual(limits.reachedType, "rate_limit_reached")
        XCTAssertEqual(limits.resetAvailability?.availableCount, 2)
        XCTAssertEqual(limits.resetAvailability?.credits?.count, 1)
        XCTAssertEqual(limits.resetAvailability?.credits?.first?.id, "reset-1")
        XCTAssertEqual(
            limits.resetAvailability?.credits?.first?.expiresAt,
            Date(timeIntervalSince1970: 1_784_246_400)
        )
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
        XCTAssertEqual(snapshot.codexRateLimitReachedType, "rate_limit_reached")
    }

    func testResetAvailabilityPreservesZeroAndCountOnlyReadings() {
        let zero = CodexUsageAppServerResponseAccumulator.parseRateLimits([
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 300]
            ],
            "rateLimitResetCredits": ["availableCount": 0, "credits": []]
        ])
        let countOnly = CodexUsageAppServerResponseAccumulator.parseRateLimits([
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 300]
            ],
            "rateLimitResetCredits": ["availableCount": 3, "credits": NSNull()]
        ])
        let absent = CodexUsageAppServerResponseAccumulator.parseRateLimits([
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 300]
            ]
        ])

        XCTAssertEqual(zero?.resetAvailability, CodexRateLimitResetAvailability(availableCount: 0, credits: []))
        XCTAssertEqual(countOnly?.resetAvailability?.availableCount, 3)
        XCTAssertNil(countOnly?.resetAvailability?.credits)
        XCTAssertNil(absent?.resetAvailability)
    }

    func testResetAvailabilitySkipsMalformedDetailsAndRejectsMalformedCounts() {
        let baseLimits: [String: Any] = [
            "primary": ["usedPercent": 5, "windowDurationMins": 300]
        ]
        let parsed = CodexUsageAppServerResponseAccumulator.parseRateLimits([
            "rateLimits": baseLimits,
            "rateLimitResetCredits": [
                "availableCount": 4,
                "credits": [
                    [
                        "id": "future",
                        "resetType": "futureResetType",
                        "status": "futureStatus",
                        "grantedAt": 1_783_000_000
                    ],
                    ["id": "missing-required-fields"]
                ]
            ]
        ])
        XCTAssertEqual(parsed?.resetAvailability?.availableCount, 4)
        XCTAssertEqual(parsed?.resetAvailability?.credits?.count, 1)
        XCTAssertEqual(parsed?.resetAvailability?.credits?.first?.resetType, "futureResetType")
        XCTAssertEqual(parsed?.resetAvailability?.credits?.first?.status, "futureStatus")

        for malformedCount: Any in ["NaN", 1.5] {
            let malformed = CodexUsageAppServerResponseAccumulator.parseRateLimits([
                "rateLimits": baseLimits,
                "rateLimitResetCredits": ["availableCount": malformedCount]
            ])
            XCTAssertNil(malformed?.resetAvailability)
        }

        let negative = CodexUsageAppServerResponseAccumulator.parseRateLimits([
            "rateLimits": baseLimits,
            "rateLimitResetCredits": ["availableCount": -3]
        ])
        XCTAssertEqual(negative?.resetAvailability?.availableCount, 0)
    }

    func testRedeemResetReturnsRefreshedUsageAndReusesVerifiedIdentity() async throws {
        let initial = try authJSON(accountID: "acct-1", accessToken: "old", refreshToken: "refresh-1")
        let updated = try authJSON(accountID: "acct-1", accessToken: "new", refreshToken: "refresh-2")
        let refreshedReading = CodexRateLimitReading(
            windows: [
                CodexRateLimitWindowReading(
                    name: "primary",
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: Date(timeIntervalSince1970: 1_783_100_000)
                )
            ],
            credits: nil,
            planType: "pro",
            reachedType: nil,
            resetAvailability: CodexRateLimitResetAvailability(availableCount: 1, credits: [])
        )
        let runner = FakeCodexUsageRunner(
            outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 100)),
            resetOutcome: .success(
                accountEmail: "user@example.com",
                outcome: .reset,
                rateLimits: refreshedReading
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

        let result = try await service.redeemReset(
            for: profile,
            authJSON: initial,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: profile.identity,
            idempotencyKey: "attempt-1"
        )

        XCTAssertEqual(result.outcome, .reset)
        XCTAssertEqual(result.refreshedUsage?.snapshot.windows.first?.usedPercent, 0)
        XCTAssertEqual(result.refreshedUsage?.snapshot.codexRateLimitResetAvailability?.availableCount, 1)
        XCTAssertEqual(result.updatedAuthJSON, updated)
        XCTAssertEqual(runner.resetIdempotencyKeys, ["attempt-1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(runner.resetCodexHome).path))
    }

    func testRedeemResetPreservesConfirmedOutcomeWhenPostReadFails() async throws {
        let runner = FakeCodexUsageRunner(
            outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 100)),
            resetOutcome: .completedWithoutRefresh(
                accountEmail: "user@example.com",
                outcome: .alreadyRedeemed,
                reason: "post-read timeout"
            )
        )
        let service = CodexAccountUsageService(runner: runner)
        let profile = AccountProfile(
            provider: .codex,
            label: "Codex",
            identity: AccountIdentity(email: "user@example.com", accountID: "acct-1", source: .codexIDToken)
        )

        let result = try await service.redeemReset(
            for: profile,
            authJSON: try authJSON(accountID: "acct-1"),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            expectedIdentity: profile.identity,
            idempotencyKey: "attempt-2"
        )

        XCTAssertEqual(result.outcome, .alreadyRedeemed)
        XCTAssertTrue(result.outcome.consumedReset)
        XCTAssertNil(result.refreshedUsage)
        XCTAssertEqual(result.refreshFailureReason, "post-read timeout")
    }

    func testRedeemResetSurfacesUnsupportedMethod() async throws {
        let runner = FakeCodexUsageRunner(
            outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 100)),
            resetOutcome: .unsupported(reason: "Update Codex")
        )
        let service = CodexAccountUsageService(runner: runner)

        do {
            _ = try await service.redeemReset(
                for: AccountProfile(provider: .codex, label: "Codex"),
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil,
                idempotencyKey: "attempt-3"
            )
            XCTFail("Expected unsupported reset redemption")
        } catch let error as CodexResetRedemptionError {
            XCTAssertEqual(error.failure, .unsupported(reason: "Update Codex"))
        }
    }

    func testRedeemResetReturnsSafeTokenRotationWithTransientFailure() async throws {
        let updated = try authJSON(
            accountID: "acct-1",
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh"
        )
        let runner = FakeCodexUsageRunner(
            outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 100)),
            resetOutcome: .unavailable(reason: "Temporary failure"),
            updatedAuthJSON: updated
        )
        let service = CodexAccountUsageService(runner: runner)

        do {
            _ = try await service.redeemReset(
                for: AccountProfile(provider: .codex, label: "Codex"),
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil,
                idempotencyKey: "attempt-transient"
            )
            XCTFail("Expected transient reset failure")
        } catch let error as CodexResetRedemptionError {
            XCTAssertEqual(error.failure, .unavailable(reason: "Temporary failure"))
            XCTAssertEqual(error.updatedAuthJSON, updated)
        }
    }

    func testRedeemResetRejectsIdentityMismatchBeforeCallingResetRunner() async throws {
        let runner = FakeCodexUsageRunner(
            outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 100)),
            resetOutcome: .unavailable(reason: "Must not be called")
        )
        let service = CodexAccountUsageService(runner: runner)
        let expected = AccountIdentity(accountID: "acct-expected", source: .codexIDToken)

        do {
            _ = try await service.redeemReset(
                for: AccountProfile(provider: .codex, label: "Codex", identity: expected),
                authJSON: try authJSON(accountID: "acct-other"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: expected,
                idempotencyKey: "attempt-wrong-account"
            )
            XCTFail("Expected identity mismatch")
        } catch let error as CodexAccountUsageError {
            guard case .unavailable(let reason) = error else {
                return XCTFail("Expected identity mismatch, got \(error)")
            }
            XCTAssertTrue(reason.contains("different saved account"))
        }
        XCTAssertTrue(runner.resetIdempotencyKeys.isEmpty)
    }

    func testRedeemResetPreservesNoCreditAndNothingToResetOutcomes() async throws {
        for outcome in [CodexResetRedemptionOutcome.noCredit, .nothingToReset] {
            let runner = FakeCodexUsageRunner(
                outcome: .success(accountEmail: "user@example.com", rateLimits: reading(usedPercent: 75)),
                resetOutcome: .success(
                    accountEmail: "user@example.com",
                    outcome: outcome,
                    rateLimits: reading(usedPercent: 75)
                )
            )
            let service = CodexAccountUsageService(runner: runner)
            let result = try await service.redeemReset(
                for: AccountProfile(provider: .codex, label: "Codex"),
                authJSON: try authJSON(accountID: "acct-1"),
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                expectedIdentity: nil,
                idempotencyKey: "attempt-\(outcome.rawValue)"
            )

            XCTAssertEqual(result.outcome, outcome)
            XCTAssertFalse(result.outcome.consumedReset)
            XCTAssertNotNil(result.refreshedUsage)
        }
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

    func testProcessRunnerRedeemsSequentiallyAndRefetchesLimits() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account_read
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}'
        IFS= read -r consume
        printf '%s' "$consume" > "$CODEX_HOME/consume.json"
        printf '%s\n' '{"id":3,"result":{"outcome":"reset"}}'
        IFS= read -r rate_limits
        printf '%s\n' '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":1,"credits":[]}}}'
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexUsageAppServerProcessRunner().redeemReset(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: false,
            idempotencyKey: "safe-attempt",
            expectedAccountEmail: "user@example.com",
            timeout: 2
        )

        guard case .success(let email, let redemption, let reading) = outcome else {
            return XCTFail("Expected successful reset, got \(outcome)")
        }
        XCTAssertEqual(email, "user@example.com")
        XCTAssertEqual(redemption, .reset)
        XCTAssertEqual(reading.windows.first?.usedPercent, 0)
        XCTAssertEqual(reading.resetAvailability?.availableCount, 1)
        let request = try String(
            contentsOf: fixture.directory.appendingPathComponent("consume.json"),
            encoding: .utf8
        )
        XCTAssertTrue(request.contains(#""idempotencyKey":"safe-attempt""#))
        XCTAssertFalse(request.contains("creditId"))
    }

    func testProcessRunnerStopsBeforeConsumeWhenAccountEmailChanges() async throws {
        let fixture = try UsageExecutableScriptFixture(contents: """
        #!/bin/sh
        IFS= read -r initialize
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r account_read
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"other@example.com"},"requiresOpenaiAuth":true}}'
        IFS= read -r consume
        printf '%s' "$consume" > "$CODEX_HOME/unexpected-consume.json"
        """)
        defer { fixture.cleanup() }

        let outcome = await CodexUsageAppServerProcessRunner().redeemReset(
            executableURL: fixture.executable,
            codexHome: fixture.directory,
            forceRefresh: false,
            idempotencyKey: "wrong-account-attempt",
            expectedAccountEmail: "user@example.com",
            timeout: 2
        )

        guard case .unavailable(let reason) = outcome else {
            return XCTFail("Expected identity rejection, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("different account"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent("unexpected-consume.json").path
            )
        )
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
    private var resetOutcomes: [CodexResetAppServerOutcome]
    let updatedAuthJSON: Data?
    private(set) var codexHome: URL?
    private(set) var initialAuthJSON: Data?
    private(set) var homePermissions: Int?
    private(set) var authPermissions: Int?
    private(set) var forceRefreshValues: [Bool] = []
    private(set) var resetForceRefreshValues: [Bool] = []
    private(set) var resetIdempotencyKeys: [String] = []
    private(set) var resetCodexHome: URL?

    init(outcome: CodexUsageAppServerOutcome, updatedAuthJSON: Data? = nil) {
        self.outcomes = [outcome]
        self.resetOutcomes = []
        self.updatedAuthJSON = updatedAuthJSON
    }

    init(
        outcome: CodexUsageAppServerOutcome,
        resetOutcome: CodexResetAppServerOutcome,
        updatedAuthJSON: Data? = nil
    ) {
        self.outcomes = [outcome]
        self.resetOutcomes = [resetOutcome]
        self.updatedAuthJSON = updatedAuthJSON
    }

    init(outcomes: [CodexUsageAppServerOutcome], updatedAuthJSON: Data? = nil) {
        self.outcomes = outcomes
        self.resetOutcomes = []
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

    func redeemReset(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        idempotencyKey: String,
        expectedAccountEmail: String?,
        timeout: TimeInterval
    ) async -> CodexResetAppServerOutcome {
        resetForceRefreshValues.append(forceRefresh)
        resetIdempotencyKeys.append(idempotencyKey)
        resetCodexHome = codexHome
        if let updatedAuthJSON {
            try? updatedAuthJSON.write(
                to: codexHome.appendingPathComponent("auth.json"),
                options: .atomic
            )
        }
        guard !resetOutcomes.isEmpty else {
            return .unavailable(reason: "Fake reset runner exhausted")
        }
        return resetOutcomes.removeFirst()
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
