import XCTest
@testable import LimitLifeboatCore

final class UsageHistoryCSVExporterTests: XCTestCase {
    private let exporter = UsageHistoryCSVExporter()

    func testEmptyInputProducesHeaderOnly() {
        XCTAssertEqual(exporter.csv(records: [:], accounts: [:]), UsageHistoryCSVExporter.header + "\n")
    }

    func testRowCarriesAllColumns() {
        let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let timestamp = Date(timeIntervalSince1970: 1_783_000_000)
        let reset = Date(timeIntervalSince1970: 1_783_100_000)
        let record = UsageHistoryRecord(
            timestamp: timestamp,
            accountID: accountID,
            windows: [
                UsageWindowReading(id: "weekly-all", kind: .weekly, usedPercent: 57.25, resetDate: reset, windowMinutes: 10_080)
            ]
        )

        let csv = exporter.csv(
            records: [accountID: [record]],
            accounts: [accountID: .init(label: "Work", provider: .claude)]
        )

        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], UsageHistoryCSVExporter.header)
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[1], accountID.uuidString)
        XCTAssertEqual(fields[2], "Work")
        XCTAssertEqual(fields[3], "claude")
        XCTAssertEqual(fields[4], "weekly-all")
        XCTAssertEqual(fields[5], "weekly")
        XCTAssertEqual(fields[6], "57.25")
        XCTAssertFalse(fields[7].isEmpty)
        XCTAssertEqual(fields[8], "10080")
        // ISO8601, parseable back to the exact second.
        XCTAssertEqual(ISO8601DateFormatter().date(from: fields[0]), timestamp)
        XCTAssertEqual(ISO8601DateFormatter().date(from: fields[7]), reset)
    }

    func testNilResetAndWindowMinutesLeaveEmptyCells() {
        let accountID = UUID()
        let record = UsageHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_783_000_000),
            accountID: accountID,
            windows: [UsageWindowReading(id: "primary", kind: .other, usedPercent: 40)]
        )

        let csv = exporter.csv(
            records: [accountID: [record]],
            accounts: [accountID: .init(label: "A", provider: .codex)]
        )

        let line = csv.split(separator: "\n").map(String.init)[1]
        XCTAssertTrue(line.hasSuffix(",40,,"))
    }

    func testLabelWithCommaAndQuoteIsRFC4180Escaped() {
        let accountID = UUID()
        let record = UsageHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_783_000_000),
            accountID: accountID,
            windows: [UsageWindowReading(id: "session", kind: .session, usedPercent: 10)]
        )

        let csv = exporter.csv(
            records: [accountID: [record]],
            accounts: [accountID: .init(label: "Work, \"personal\"", provider: .claude)]
        )

        XCTAssertTrue(csv.contains("\"Work, \"\"personal\"\"\""))
    }

    func testAccountsOrderedByUUIDAndRecordsChronologically() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let early = Date(timeIntervalSince1970: 1_783_000_000)
        let late = Date(timeIntervalSince1970: 1_783_005_000)
        func record(_ id: UUID, _ timestamp: Date) -> UsageHistoryRecord {
            UsageHistoryRecord(
                timestamp: timestamp,
                accountID: id,
                windows: [UsageWindowReading(id: "session", kind: .session, usedPercent: 10)]
            )
        }

        let csv = exporter.csv(
            records: [
                second: [record(second, early)],
                first: [record(first, late), record(first, early)]
            ],
            accounts: [
                first: .init(label: "First", provider: .claude),
                second: .init(label: "Second", provider: .codex)
            ]
        )

        let labels = csv.split(separator: "\n").dropFirst().map { line in
            String(line.split(separator: ",")[2])
        }
        XCTAssertEqual(labels, ["First", "First", "Second"])
        let firstTimestamps = csv.split(separator: "\n").dropFirst().prefix(2).map { String($0.split(separator: ",")[0]) }
        XCTAssertEqual(firstTimestamps, firstTimestamps.sorted())
    }

    func testUnknownAccountFallsBackWithoutCrashing() {
        let accountID = UUID()
        let record = UsageHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_783_000_000),
            accountID: accountID,
            windows: [UsageWindowReading(id: "session", kind: .session, usedPercent: 10)]
        )

        let csv = exporter.csv(records: [accountID: [record]], accounts: [:])
        XCTAssertTrue(csv.contains(",unknown,unknown,"))
    }
}
