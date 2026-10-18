import Foundation
import XCTest
@testable import LimitLifeboatCore

/// Regression tests for 1.1.18, where `status`, `list` and `active` exited 0
/// and printed nothing, in both text and `--json` mode. These run the real
/// binary so the fault is caught wherever it is reintroduced, including in
/// `main.swift`.
final class CLIReadCommandsEndToEndTests: XCTestCase {
    private var harness: CLIHarness!
    private var claudeActive: AccountProfile!
    private var claudeSpare: AccountProfile!
    private var codexActive: AccountProfile!

    override func setUpWithError() throws {
        harness = try CLIHarness()
        claudeActive = AccountProfile(
            provider: .claude,
            label: "Work",
            planLabel: "Max 20x",
            identity: AccountIdentity(email: "work@example.com", source: .claudeCodeUsage),
            isActiveCLI: true
        )
        claudeSpare = AccountProfile(provider: .claude, label: "Spare", planLabel: "Pro", isActiveCLI: false)
        codexActive = AccountProfile(provider: .codex, label: "Codex", planLabel: "Plus", isActiveCLI: true)
        try harness.repository.saveProfiles([claudeActive, claudeSpare, codexActive])

        let now = Date()
        let snapshot = UsageSnapshot(
            accountID: claudeActive.id,
            provider: .claude,
            windows: [
                UsageWindow(
                    id: UsageWindowID.slug("Session (5h)"),
                    kind: .session,
                    label: "Session (5h)",
                    usedPercent: 42,
                    resetDate: now.addingTimeInterval(2 * 3_600),
                    riskLevel: .healthy
                )
            ],
            riskLevel: .healthy,
            source: "test source",
            // 90 s, not a whole minute: the store keeps whole seconds and
            // DurationPhrase rounds up, so 120 s plus the run time could read
            // "3m". Anything from 61 s to 120 s prints "2m".
            lastRefreshed: now.addingTimeInterval(-90)
        )
        try harness.repository.saveUsageSnapshots([claudeActive.id: snapshot])
    }

    override func tearDown() {
        harness.cleanUp()
    }

    // MARK: - Text mode

    func testStatusTextListsEveryAccountWithItsReading() throws {
        let result = try harness.run(["status"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "* [claude] Work (work@example.com)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("      Session (5h): 42% used [healthy]") }, result.stdout)
        XCTAssertTrue(lines.contains("      updated 2m ago via test source"), result.stdout)
        XCTAssertTrue(lines.contains("  [claude] Spare (Pro)"), result.stdout)
        XCTAssertTrue(lines.contains("* [codex] Codex (Plus)"), result.stdout)
        XCTAssertTrue(lines.contains("      no reading yet"), result.stdout)
    }

    func testListTextListsAccountsWithoutUsage() throws {
        let result = try harness.run(["list"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "* [claude] Work (work@example.com)\n  [claude] Spare (Pro)\n* [codex] Codex (Plus)\n"
        )
    }

    func testActiveTextListsOnlyActiveAccounts() throws {
        let result = try harness.run(["active"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.isEmpty)
        XCTAssertTrue(result.stdout.contains("* [claude] Work (work@example.com)"))
        XCTAssertTrue(result.stdout.contains("* [codex] Codex (Plus)"))
        XCTAssertFalse(result.stdout.contains("Spare"))
    }

    func testEmptyStorePrintsGuidanceRatherThanNothing() throws {
        try harness.repository.saveProfiles([])
        for command in ["status", "list", "active"] {
            let result = try harness.run([command])
            XCTAssertEqual(result.status, 0, "\(command): \(result.stderr)")
            XCTAssertTrue(result.stdout.hasPrefix("No accounts saved yet."), "\(command): \(result.stdout)")
        }
    }

    // MARK: - JSON mode

    func testStatusJSONIsAValidSchemaReport() throws {
        let report = try decodeReport(["status", "--json"])
        XCTAssertEqual(report.accounts.map(\.label), ["Work", "Spare", "Codex"])
        let reading = try XCTUnwrap(report.accounts[0].reading)
        XCTAssertEqual(reading.mostConstrainedPercent, 42)
        XCTAssertEqual(reading.windows.map(\.label), ["Session (5h)"])
        XCTAssertEqual(reading.source, "test source")
        XCTAssertNil(report.accounts[1].reading)
    }

    func testListJSONOmitsReadings() throws {
        let report = try decodeReport(["list", "--json"])
        XCTAssertEqual(report.accounts.map(\.label), ["Work", "Spare", "Codex"])
        XCTAssertTrue(report.accounts.allSatisfy { $0.reading == nil })
    }

    func testActiveJSONHasOnlyActiveAccounts() throws {
        let report = try decodeReport(["active", "--json"])
        XCTAssertEqual(report.accounts.map(\.label), ["Work", "Codex"])
        XCTAssertTrue(report.accounts.allSatisfy(\.isActive))
        XCTAssertEqual(report.accounts[0].reading?.mostConstrainedPercent, 42)
    }

    func testJSONFlagPositionDoesNotMatter() throws {
        let report = try decodeReport(["--json", "status"])
        XCTAssertEqual(report.accounts.count, 3)
    }

    /// Asserts the documented top-level and per-account keys, not just that
    /// it decodes, so a renamed field is caught too.
    func testJSONCarriesTheDocumentedKeys() throws {
        let result = try harness.run(["status", "--json"])
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema", "generatedAt", "accounts"])
        XCTAssertEqual(object["schema"] as? Int, CLIStatusReport.schemaVersion)
        let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
        for key in ["id", "provider", "label", "isActive", "priority", "reading"] {
            XCTAssertNotNil(account[key], "missing \(key)")
        }
        let reading = try XCTUnwrap(account["reading"] as? [String: Any])
        for key in ["risk", "mostConstrainedPercent", "windows", "lastRefreshed", "ageSeconds", "source"] {
            XCTAssertNotNil(reading[key], "missing reading.\(key)")
        }
    }

    // MARK: - Helpers

    private func decodeReport(_ arguments: [String]) throws -> CLIStatusReport {
        let result = try harness.run(arguments)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(arguments) printed nothing")
        let report = try JSONDecoder.appDecoder.decode(CLIStatusReport.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(report.schema, CLIStatusReport.schemaVersion)
        return report
    }
}
