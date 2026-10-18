import XCTest
@testable import LimitLifeboatCore

final class CLIReadCommandOutputTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private func report() -> CLIStatusReport {
        CLIStatusReport(
            generatedAt: now,
            accounts: [
                CLIAccountStatus(
                    id: "a",
                    provider: "claude",
                    label: "Work",
                    email: "work@example.com",
                    plan: "Max 20x",
                    isActive: true,
                    priority: 0,
                    reading: CLIUsageReading(
                        risk: "warning",
                        mostConstrainedPercent: 85,
                        windows: [
                            CLIUsageWindow(
                                id: "session", kind: "session", label: "Session (5h)",
                                usedPercent: 85, risk: "warning", resetsAt: nil
                            )
                        ],
                        lastRefreshed: now.addingTimeInterval(-300),
                        ageSeconds: 300,
                        source: "usage API",
                        extraUsage: "$12.50 of $50 extra usage this month"
                    )
                ),
                CLIAccountStatus(id: "b", provider: "claude", label: "Spare", isActive: false, priority: 1),
            ]
        )
    }

    func testStatusTextMatchesThePre113Format() throws {
        let text = try CLIReadCommandOutput.render(.status, report: report(), json: false, now: now)
        XCTAssertEqual(text, """
        * [claude] Work (work@example.com)
              Session (5h): 85% used [warning]
              $12.50 of $50 extra usage this month
              updated 5m ago via usage API
          [claude] Spare
              no reading yet
        """)
    }

    func testListTextHasNoUsageLines() throws {
        let text = try CLIReadCommandOutput.render(.list, report: report(), json: false, now: now)
        XCTAssertEqual(text, "* [claude] Work (work@example.com)\n  [claude] Spare")
    }

    func testActiveTextFiltersToActiveAccounts() throws {
        let text = try CLIReadCommandOutput.render(.active, report: report(), json: false, now: now)
        XCTAssertTrue(text.hasPrefix("* [claude] Work"))
        XCTAssertFalse(text.contains("Spare"))
    }

    func testNoActiveAccountSaysSo() throws {
        var inactive = report()
        inactive.accounts = inactive.accounts.map { var a = $0; a.isActive = false; return a }
        XCTAssertEqual(
            try CLIReadCommandOutput.render(.active, report: inactive, json: false, now: now),
            "No account is currently active."
        )
    }

    func testEveryCommandRendersNonEmptyValidJSONInBothModes() throws {
        for command in CLIReadCommand.allCases {
            let text = try CLIReadCommandOutput.render(command, report: report(), json: false, now: now)
            XCTAssertFalse(text.isEmpty, "\(command) text")

            let json = try CLIReadCommandOutput.render(command, report: report(), json: true, now: now)
            let decoded = try JSONDecoder.appDecoder.decode(CLIStatusReport.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.schema, CLIStatusReport.schemaVersion)
            XCTAssertEqual(decoded.accounts.count, command == .active ? 1 : 2, "\(command) json")
        }
    }
}
