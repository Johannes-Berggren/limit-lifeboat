import XCTest
@testable import LimitLifeboatCore

/// Recording HTTPClienting mock, shared with ClaudeOAuthTokenRefresherTests.
final class MockHTTPClient: HTTPClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [Result<(status: Int, body: Data), Error>] = []
    private(set) var requests: [URLRequest] = []

    func stub(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        stubs.append(.success((status, body)))
    }

    func stub(status: Int, bodyText: String) {
        stub(status: status, body: Data(bodyText.utf8))
    }

    func stub(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        stubs.append(.failure(error))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = try dequeueResponse(for: request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }

    /// Keep the synchronous primitive outside the async protocol requirement;
    /// direct lock/unlock calls are unavailable from Swift 6 async contexts.
    private func dequeueResponse(for request: URLRequest) throws -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !stubs.isEmpty else {
            throw URLError(.unsupportedURL)
        }
        let (status, body) = try stubs.removeFirst().get()
        return (status, body)
    }
}

final class ClaudeUsageAPIClientTests: XCTestCase {
    /// Copied from a live api/oauth/usage response: both the preferred
    /// "limits" array and the legacy five_hour/seven_day objects are present,
    /// alongside keys the client must ignore.
    private let liveResponseJSON = """
    {
        "five_hour": {"utilization": 53.0, "resets_at": "2026-07-08T00:49:59.940321+00:00"},
        "seven_day": {"utilization": 8.0, "resets_at": "2026-07-13T06:00:00+00:00"},
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "seven_day_oauth_apps": null,
        "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null},
        "tangelo": null,
        "limits": [
            {"kind": "session", "group": "session", "percent": 53, "severity": "normal", "resets_at": "2026-07-08T00:49:59.940321+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 8, "severity": "normal", "resets_at": "2026-07-13T06:00:00+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 6, "severity": "normal", "resets_at": "2026-07-13T06:00:00+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
        ]
    }
    """

    func testFetchSendsAuthorizedRequestAndParsesLimitsArray() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: liveResponseJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let usage = try await client.fetchUsage(accessToken: "test-access-token")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LimitLifeboat")

        XCTAssertEqual(usage.windows.count, 3)

        XCTAssertEqual(usage.windows[0].kindRaw, "session")
        XCTAssertNil(usage.windows[0].scopeName)
        XCTAssertEqual(usage.windows[0].usedPercent, 53)
        let sessionReset = try XCTUnwrap(usage.windows[0].resetsAt)
        // ISO8601 with fractional seconds and a +00:00 offset.
        XCTAssertEqual(sessionReset.timeIntervalSince1970, 1_783_471_799.940321, accuracy: 0.01)

        XCTAssertEqual(usage.windows[1].kindRaw, "weekly_all")
        XCTAssertEqual(usage.windows[1].usedPercent, 8)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_783_922_400))

        XCTAssertEqual(usage.windows[2].kindRaw, "weekly_scoped")
        XCTAssertEqual(usage.windows[2].scopeName, "Fable")
        XCTAssertEqual(usage.windows[2].usedPercent, 6)
    }

    func testFallsBackToLegacyObjectsWhenLimitsArrayAbsent() async throws {
        let legacyOnlyJSON = """
        {
            "five_hour": {"utilization": 53.0, "resets_at": "2026-07-08T00:49:59.940321+00:00"},
            "seven_day": {"utilization": 8.0, "resets_at": "2026-07-13T06:00:00+00:00"},
            "seven_day_opus": null,
            "seven_day_sonnet": {"utilization": 12.0, "resets_at": null},
            "tangelo": null
        }
        """
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: legacyOnlyJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let usage = try await client.fetchUsage(accessToken: "token")

        XCTAssertEqual(usage.windows.map(\.kindRaw), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(usage.windows[0].usedPercent, 53)
        XCTAssertEqual(usage.windows[1].usedPercent, 8)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_783_922_400))
        XCTAssertEqual(usage.windows[2].usedPercent, 12)
        XCTAssertNil(usage.windows[2].resetsAt)
    }

    func testFallsBackToLegacyObjectsWhenLimitsArrayIsEmpty() async throws {
        let emptyLimitsJSON = """
        {
            "limits": [],
            "five_hour": {"utilization": 41.0, "resets_at": "2026-07-13T06:00:00+00:00"}
        }
        """
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: emptyLimitsJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let usage = try await client.fetchUsage(accessToken: "token")

        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].kindRaw, "five_hour")
        XCTAssertEqual(usage.windows[0].usedPercent, 41)
    }

    /// Numbers arrive both numeric and string-typed; the client coerces
    /// String the same way the Codex log reader does.
    func testParsesStringTypedUtilization() async throws {
        let stringNumbersJSON = """
        {
            "limits": [
                {"kind": "session", "percent": null, "utilization": "53.5", "resets_at": "2026-07-13T06:00:00+00:00"}
            ],
            "five_hour": {"utilization": "53.5", "resets_at": "2026-07-13T06:00:00+00:00"}
        }
        """
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: stringNumbersJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let usage = try await client.fetchUsage(accessToken: "token")

        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].kindRaw, "session")
        XCTAssertEqual(usage.windows[0].usedPercent, 53.5)
    }

    func testThrowsUnauthorizedOn401And403() async {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 401, bodyText: "{}")
        httpClient.stub(status: 403, bodyText: "{}")
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        for _ in 0..<2 {
            do {
                _ = try await client.fetchUsage(accessToken: "expired-token")
                XCTFail("Expected unauthorized")
            } catch let error as ClaudeUsageAPIError {
                guard case .unauthorized = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testThrowsHTTPStatusForRateLimitAndServerErrors() async {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 429, bodyText: "{}")
        httpClient.stub(status: 500, bodyText: "{}")
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        for expectedStatus in [429, 500] {
            do {
                _ = try await client.fetchUsage(accessToken: "token")
                XCTFail("Expected http(status:)")
            } catch let error as ClaudeUsageAPIError {
                guard case .http(let status) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(status, expectedStatus)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testThrowsMalformedResponseForNonJSONBody() async {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: "<html>not json</html>")
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        do {
            _ = try await client.fetchUsage(accessToken: "token")
            XCTFail("Expected malformedResponse")
        } catch let error as ClaudeUsageAPIError {
            guard case .malformedResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMakeSnapshotMapsWindowsAndMirrorsMostConstrained() throws {
        let sessionReset = Date(timeIntervalSince1970: 1_783_471_799)
        let weeklyReset = Date(timeIntervalSince1970: 1_783_922_400)
        let usage = ClaudeAPIUsage(windows: [
            ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 53, resetsAt: sessionReset),
            ClaudeAPIUsageWindow(kindRaw: "weekly_all", usedPercent: 8, resetsAt: weeklyReset),
            ClaudeAPIUsageWindow(kindRaw: "weekly_scoped", scopeName: "Fable", usedPercent: 6, resetsAt: weeklyReset)
        ])

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: profile, usage: usage, now: now)

        XCTAssertEqual(snapshot.accountID, profile.id)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.windows.count, 3)

        // Ids match the TUI parser's so alert dedupe keys survive the flip
        // between sources.
        XCTAssertEqual(snapshot.windows[0].id, "session")
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].label, "Session (5h)")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 53)
        XCTAssertEqual(snapshot.windows[0].windowMinutes, 300)
        XCTAssertEqual(snapshot.windows[0].resetDate, sessionReset)
        XCTAssertNotNil(snapshot.windows[0].resetDescription)
        XCTAssertEqual(snapshot.windows[0].riskLevel, .healthy)

        XCTAssertEqual(snapshot.windows[1].id, "weekly-all")
        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertEqual(snapshot.windows[1].label, "Weekly (all models)")
        XCTAssertEqual(snapshot.windows[1].windowMinutes, 10080)

        XCTAssertEqual(snapshot.windows[2].id, "weekly-fable")
        XCTAssertEqual(snapshot.windows[2].kind, .weeklyScoped)
        XCTAssertEqual(snapshot.windows[2].label, "Weekly (Fable)")
        XCTAssertEqual(snapshot.windows[2].windowMinutes, 10080)

        // The scalar fields mirror the most-constrained window (session, 53%).
        XCTAssertEqual(snapshot.includedRemaining, 47)
        XCTAssertEqual(snapshot.includedLimit, 100)
        XCTAssertEqual(snapshot.resetDate, sessionReset)
        XCTAssertNotNil(snapshot.resetDescription)
        XCTAssertEqual(snapshot.riskLevel, .healthy)
        XCTAssertEqual(snapshot.source, ClaudeUsageAPIClient.source)
        XCTAssertEqual(snapshot.source, "Anthropic usage API")
        XCTAssertEqual(snapshot.parseConfidence, .high)
        XCTAssertEqual(snapshot.lastRefreshed, now)
        XCTAssertEqual(snapshot.creditStatus, "Live Anthropic account view across devices.")
        XCTAssertEqual(
            snapshot.message,
            "Anthropic usage API reports session 53% - weekly all models 8% - weekly Fable 6%"
        )
    }

    func testMakeSnapshotMapsLegacyAndUnknownKinds() {
        let usage = ClaudeAPIUsage(windows: [
            ClaudeAPIUsageWindow(kindRaw: "five_hour", usedPercent: 10),
            ClaudeAPIUsageWindow(kindRaw: "seven_day", usedPercent: 20),
            ClaudeAPIUsageWindow(kindRaw: "seven_day_opus", usedPercent: 30),
            ClaudeAPIUsageWindow(kindRaw: "seven_day_sonnet", usedPercent: 40),
            ClaudeAPIUsageWindow(kindRaw: "monthly_special", usedPercent: 85)
        ])

        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: profile, usage: usage)

        XCTAssertEqual(
            snapshot.windows.map(\.id),
            ["session", "weekly-all", "weekly-opus", "weekly-sonnet", "monthly-special"]
        )
        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.session, .weekly, .weeklyScoped, .weeklyScoped, .other]
        )
        XCTAssertEqual(snapshot.windows[2].label, "Weekly (Opus)")
        XCTAssertEqual(snapshot.windows[3].label, "Weekly (Sonnet)")
        XCTAssertEqual(snapshot.windows[4].label, "Monthly Special")
        XCTAssertNil(snapshot.windows[4].windowMinutes)

        // Most constrained is the unknown window at 85% -> warning headline.
        XCTAssertEqual(snapshot.includedRemaining, 15)
        XCTAssertEqual(snapshot.riskLevel, .warning)
        XCTAssertTrue(snapshot.message.contains("monthly special 85%"))
    }

    func testMakeSnapshotWithoutWindowsReportsUnknown() {
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: profile, usage: ClaudeAPIUsage(windows: []))

        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.riskLevel, .unknown)
        XCTAssertEqual(snapshot.parseConfidence, .none)
        XCTAssertEqual(snapshot.source, "Anthropic usage API")
        XCTAssertEqual(snapshot.message, "Anthropic usage API did not include a recognizable limit.")
    }

    // MARK: - extra_usage / pay-as-you-go

    func testParsesExtraUsageBlockAndPerLimitSeverity() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: liveResponseJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let usage = try await client.fetchUsage(accessToken: "token")

        let extra = try XCTUnwrap(usage.extraUsage)
        XCTAssertFalse(extra.isEnabled)
        XCTAssertNil(extra.monthlyLimit)
        XCTAssertNil(extra.usedCredits)

        XCTAssertEqual(usage.windows[0].severityRaw, "normal")
        XCTAssertEqual(usage.windows[0].isActive, true)
        XCTAssertEqual(usage.windows[1].isActive, false)
    }

    func testMissingExtraUsageBlockLeavesItNil() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"limits": [{"kind": "session", "percent": 12}]}"#)
        let usage = try await ClaudeUsageAPIClient(httpClient: httpClient).fetchUsage(accessToken: "token")
        XCTAssertNil(usage.extraUsage)
    }

    func testMakeSnapshotDisabledOverageKeepsOriginalCreditStatus() {
        let usage = ClaudeAPIUsage(
            windows: [ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 53)],
            extraUsage: ClaudeAPIExtraUsage(isEnabled: false)
        )
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: claudeProfile, usage: usage)

        XCTAssertEqual(snapshot.payAsYouGoState, .disabled)
        XCTAssertEqual(snapshot.creditStatus, "Live Anthropic account view across devices.")
        XCTAssertEqual(snapshot.billingUsageMode, .includedSubscription)
    }

    /// Overage enabled but included usage not yet exhausted is a backstop, not
    /// active billing: `.enabledIdle`, and the account still reads as a normal
    /// included subscription (no PAYG badge). This is the exact case that was
    /// wrongly showing "Pay as you go" on a healthy account.
    func testMakeSnapshotEnabledIdleDoesNotAlarm() {
        let usage = ClaudeAPIUsage(
            windows: [ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 40)],
            extraUsage: ClaudeAPIExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 0)
        )
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: claudeProfile, usage: usage)

        XCTAssertEqual(snapshot.payAsYouGoState, .enabledIdle)
        XCTAssertEqual(snapshot.billingUsageMode, .includedSubscription)
    }

    /// The reported false positive: overage enabled and credits consumed in the
    /// past, but the current window is at 0% — must NOT read as actively paying.
    /// `used_credits` is cumulative and is deliberately ignored as a trigger.
    func testMakeSnapshotOverageEnabledWithPastCreditsButIdleWindowIsNotActive() {
        let usage = ClaudeAPIUsage(
            windows: [ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 0)],
            extraUsage: ClaudeAPIExtraUsage(isEnabled: true, monthlyLimit: 100, usedCredits: 42)
        )
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: claudeProfile, usage: usage)

        XCTAssertEqual(snapshot.payAsYouGoState, .enabledIdle)
        XCTAssertEqual(snapshot.billingUsageMode, .includedSubscription)
    }

    func testMakeSnapshotEnabledActiveWhenIncludedExhausted() {
        let usage = ClaudeAPIUsage(
            windows: [ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 100)],
            extraUsage: ClaudeAPIExtraUsage(isEnabled: true)
        )
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: claudeProfile, usage: usage)

        XCTAssertEqual(snapshot.payAsYouGoState, .enabledActive)
        XCTAssertEqual(snapshot.billingUsageMode, .overLimitPayAsYouGo)
        // The string scanner (used by notifications + the TUI fallback) agrees.
        XCTAssertTrue(snapshot.hasPayAsYouGoSignal)
        XCTAssertTrue(snapshot.payAsYouGoLooksActive)
    }

    func testMakeSnapshotWithoutExtraUsageLeavesPayStateNil() {
        let usage = ClaudeAPIUsage(windows: [ClaudeAPIUsageWindow(kindRaw: "session", usedPercent: 10)])
        let snapshot = ClaudeUsageAPIClient().makeSnapshot(for: claudeProfile, usage: usage)
        XCTAssertNil(snapshot.payAsYouGoState)
    }

    private var claudeProfile: AccountProfile {
        AccountProfile(provider: .claude, label: "Claude")
    }

    // MARK: - Account info (api/oauth/profile)

    /// Copied from a live api/oauth/profile response, trimmed to the keys the
    /// client reads plus ones it must ignore.
    private let liveProfileJSON = """
    {
        "account": {
            "uuid": "11111111-1111-4111-8111-111111111111",
            "full_name": "Taylor Example",
            "display_name": "Taylor",
            "email": "taylor@example.com",
            "has_claude_max": true,
            "has_claude_pro": false,
            "user_rate_limit_tier": "default_claude_max_20x"
        },
        "organization": {
            "uuid": "22222222-2222-4222-8222-222222222222",
            "name": "taylor@example.com's Organization",
            "organization_type": "claude_max",
            "billing_type": "stripe_subscription",
            "rate_limit_tier": "default_claude_max_20x",
            "seat_tier": null,
            "subscription_status": "active"
        },
        "application": {"client_id": "test-client"},
        "enabled_plugins": []
    }
    """

    private let teamPremiumProfileJSON = """
    {
        "account": {
            "uuid": "33333333-3333-4333-8333-333333333333",
            "full_name": "Morgan Example",
            "display_name": "Morgan",
            "email": "developer@example.com",
            "has_claude_max": true,
            "has_claude_pro": false
        },
        "organization": {
            "uuid": "44444444-4444-4444-8444-444444444444",
            "name": "Example Labs",
            "organization_type": "claude_team",
            "billing_type": "stripe_subscription",
            "rate_limit_tier": "default_claude_max_5x",
            "seat_tier": "team_tier_1"
        }
    }
    """

    func testFetchAccountInfoSendsAuthorizedRequestAndParsesProfile() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: liveProfileJSON)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)
        let now = Date(timeIntervalSince1970: 1_783_000_000)

        let info = try await client.fetchAccountInfo(accessToken: "test-access-token", now: now)

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(request.url, ClaudeUsageAPIClient.profileEndpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LimitLifeboat")

        let identity = try XCTUnwrap(info.identity)
        XCTAssertEqual(identity.email, "taylor@example.com")
        XCTAssertEqual(identity.displayName, "Taylor Example")
        XCTAssertEqual(identity.organization, "taylor@example.com's Organization")
        XCTAssertEqual(identity.organizationID, "22222222-2222-4222-8222-222222222222")
        // accountID carries the account uuid, while organizationID carries
        // the org uuid. Together they distinguish same-email Claude orgs.
        XCTAssertEqual(identity.accountID, "11111111-1111-4111-8111-111111111111")
        XCTAssertNotEqual(identity.accountID, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(identity.source, .claudeCodeUsage)
        XCTAssertEqual(identity.updatedAt, now)
        XCTAssertTrue(identity.isLikelyValid)

        XCTAssertEqual(info.planLabel, "Max 20x")
    }

    func testFetchAccountInfoLabelsTeamPremiumBeforeRateLimitMultiplier() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: teamPremiumProfileJSON)

        let info = try await ClaudeUsageAPIClient(httpClient: httpClient).fetchAccountInfo(accessToken: "token")

        let identity = try XCTUnwrap(info.identity)
        XCTAssertEqual(identity.email, "developer@example.com")
        XCTAssertEqual(identity.organization, "Example Labs")
        XCTAssertEqual(identity.organizationID, "44444444-4444-4444-8444-444444444444")
        XCTAssertEqual(info.planLabel, "Team Premium")
    }

    /// The same login seen through both identity sources — the profile API
    /// and ~/.claude.json via ClaudeIdentityReader — must map uuids the same
    /// way, so CLIAccountSyncPlanner activates the existing profile instead
    /// of creating a duplicate.
    func testFetchAccountInfoIdentityMatchesClaudeIdentityReaderIdentity() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let claudeConfigJSON = """
        {
            "oauthAccount": {
                "accountUuid": "11111111-1111-4111-8111-111111111111",
                "emailAddress": "taylor@example.com",
                "organizationUuid": "22222222-2222-4222-8222-222222222222",
                "organizationName": "taylor@example.com's Organization",
                "displayName": "Taylor"
            }
        }
        """
        try Data(claudeConfigJSON.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let readerIdentity = try XCTUnwrap(ClaudeIdentityReader(homeDirectory: home).readIdentity())

        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: liveProfileJSON)
        let info = try await ClaudeUsageAPIClient(httpClient: httpClient).fetchAccountInfo(accessToken: "token")
        let apiIdentity = try XCTUnwrap(info.identity)

        XCTAssertEqual(apiIdentity.accountID, readerIdentity.accountID)
        XCTAssertEqual(apiIdentity.organizationID, readerIdentity.organizationID)
        XCTAssertTrue(apiIdentity.matches(readerIdentity))

        let profile = AccountProfile(provider: .claude, label: "Claude", identity: readerIdentity)
        let action = CLIAccountSyncPlanner().plan(
            provider: .claude,
            currentIdentity: apiIdentity,
            profiles: [profile]
        )
        XCTAssertEqual(action, .activate(profile.id))
    }

    func testFetchAccountInfoThrowsUnauthorizedOn401And403() async {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 401, bodyText: "{}")
        httpClient.stub(status: 403, bodyText: "{}")
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        for _ in 0..<2 {
            do {
                _ = try await client.fetchAccountInfo(accessToken: "expired-token")
                XCTFail("Expected unauthorized")
            } catch let error as ClaudeUsageAPIError {
                guard case .unauthorized = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// Tolerant decoding: an object without account/organization keys yields
    /// empty info rather than throwing.
    func testFetchAccountInfoWithUnrecognizedObjectYieldsEmptyInfo() async throws {
        let httpClient = MockHTTPClient()
        httpClient.stub(status: 200, bodyText: #"{"something_else": true}"#)
        let client = ClaudeUsageAPIClient(httpClient: httpClient)

        let info = try await client.fetchAccountInfo(accessToken: "token")

        XCTAssertNil(info.identity)
        XCTAssertNil(info.planLabel)
    }

    func testPlanLabelMapping() {
        // Known rate-limit tiers.
        XCTAssertEqual(planLabel(organizationTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(planLabel(organizationTier: "default_claude_max_5x"), "Max 5x")
        // Multipliers Anthropic ships later generalize via the <N> capture.
        XCTAssertEqual(planLabel(organizationTier: "default_claude_max_7x"), "Max 7x")
        XCTAssertEqual(planLabel(organizationTier: "default_claude_max_100x"), "Max 100x")
        // Pro-flavored tiers.
        XCTAssertEqual(planLabel(organizationTier: "default_claude_pro"), "Pro")

        // The tier outranks the coarser signals when it is recognized.
        XCTAssertEqual(planLabel(organizationTier: "default_claude_pro", organizationType: "claude_max"), "Pro")
        XCTAssertEqual(
            planLabel(accountTier: "default_claude_max_20x", organizationTier: "default_claude_max_5x"),
            "Max 20x"
        )

        // Team org seat tiers outrank Max-flavored rate-limit tiers.
        XCTAssertEqual(
            planLabel(organizationTier: "default_claude_max_5x", organizationType: "claude_team", seatTier: "team_tier_1"),
            "Team Premium"
        )
        XCTAssertEqual(
            planLabel(organizationTier: "default_claude_max_5x", organizationType: "claude_team", seatTier: "team_tier_0"),
            "Team Standard"
        )
        XCTAssertEqual(
            planLabel(organizationType: "claude_team"),
            "Team"
        )

        // Unknown or absent tier: organization type decides first...
        XCTAssertEqual(planLabel(organizationType: "claude_max"), "Max")
        XCTAssertEqual(planLabel(organizationTier: "default_enterprise", organizationType: "claude_max"), "Max")
        // ...then the account flags; Max outranks Pro when both are set
        // (an upgraded account keeps has_claude_pro true).
        XCTAssertEqual(planLabel(hasClaudePro: true), "Pro")
        XCTAssertEqual(planLabel(hasClaudeMax: true), "Max")
        XCTAssertEqual(planLabel(hasClaudeMax: true, hasClaudePro: true), "Max")

        // No plan signal at all.
        XCTAssertNil(planLabel())
        XCTAssertNil(planLabel(organizationTier: "mystery_tier"))
        XCTAssertNil(planLabel(organizationType: "claude_enterprise"))
    }

    private func planLabel(
        accountTier: String? = nil,
        organizationTier: String? = nil,
        organizationType: String? = nil,
        billingType: String? = nil,
        seatTier: String? = nil,
        hasClaudeMax: Bool = false,
        hasClaudePro: Bool = false
    ) -> String? {
        ClaudeUsageAPIClient.planLabel(
            accountRateLimitTier: accountTier,
            organizationRateLimitTier: organizationTier,
            organizationType: organizationType,
            billingType: billingType,
            seatTier: seatTier,
            hasClaudeMax: hasClaudeMax,
            hasClaudePro: hasClaudePro
        )
    }
}
