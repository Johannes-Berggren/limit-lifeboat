import XCTest
@testable import LLMUsageMonitorCore

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
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !stubs.isEmpty else {
            throw URLError(.unsupportedURL)
        }
        let (status, body) = try stubs.removeFirst().get()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LLMUsageMonitor")

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
}
