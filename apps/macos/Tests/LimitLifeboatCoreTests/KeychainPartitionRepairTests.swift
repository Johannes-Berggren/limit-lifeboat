import Foundation
import XCTest
@testable import LimitLifeboatCore

final class KeychainPartitionRepairTests: XCTestCase {
    private let service = "Claude Code-credentials"
    private let account = "tester"
    private let required = [
        "apple-tool:",
        "apple:",
        "teamid:3DQ7YC2YH2",
        "teamid:Q6L2SF6YDW"
    ]

    // MARK: - parsePartitionList

    func testParseFindsPartitionListForServiceAndAccount() {
        let dump = Self.dump(
            service: "Claude Code-credentials",
            account: "tester",
            partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW"
        )
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: dump, service: service, account: account),
            .found(["apple-tool:", "apple:", "teamid:Q6L2SF6YDW"])
        )
    }

    func testParseGrabsListAfterPartitionIdNotAnEarlierDescription() {
        // An earlier ACL entry carries its own description line; the parser must
        // grab the description after `partition_id`, not the first one it sees.
        let dump = """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="tester"
            "svce"<blob>="Claude Code-credentials"
        access: <SecKeychainRef>
            entry 0:
                authorizations (3): decrypt derive sign
                description: some-other-decrypt-acl
            entry 1:
                authorizations (1): partition_id
                description: apple-tool:,apple:,teamid:Q6L2SF6YDW
                applications (0):
        """
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: dump, service: service, account: account),
            .found(["apple-tool:", "apple:", "teamid:Q6L2SF6YDW"])
        )
    }

    func testParseSkipsBlocksForOtherItems() {
        // A different item's block precedes the target; the parser must reset on
        // each `keychain:` line and only return the target item's list.
        let other = Self.dump(
            service: "Some Other Service",
            account: "tester",
            partitions: "apple:,teamid:ZZZZZZZZZZ"
        )
        let target = Self.dump(
            service: "Claude Code-credentials",
            account: "tester",
            partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW"
        )
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: other + "\n" + target, service: service, account: account),
            .found(["apple-tool:", "apple:", "teamid:Q6L2SF6YDW"])
        )
    }

    func testParseReturnsItemNotFoundWhenServiceAbsent() {
        let dump = Self.dump(
            service: "Some Other Service",
            account: "tester",
            partitions: "apple:"
        )
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: dump, service: service, account: account),
            .itemNotFound
        )
    }

    func testParseReturnsUnparseableWhenItemPresentButNoPartitionList() {
        let dump = """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="tester"
            "svce"<blob>="Claude Code-credentials"
        access: <SecKeychainRef>
            entry 0:
                authorizations (3): decrypt derive sign
        """
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: dump, service: service, account: account),
            .unparseable
        )
    }

    func testParseDoesNotCarryPartitionGrabIntoNextItem() {
        let targetWithoutDescription = """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="tester"
            "svce"<blob>="Claude Code-credentials"
        access: <SecKeychainRef>
            entry 0:
                authorizations (1): partition_id
        """
        let unrelated = Self.dump(
            service: "Some Other Service",
            account: "tester",
            partitions: "apple:,teamid:UNRELATED"
        )

        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(
                fromDump: targetWithoutDescription + "\n" + unrelated,
                service: service,
                account: account
            ),
            .unparseable
        )
    }

    func testParseDoesNotCarryPartitionGrabIntoLaterACLEntry() {
        let dump = """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="tester"
            "svce"<blob>="Claude Code-credentials"
        access: <SecKeychainRef>
            entry 0:
                authorizations (1): partition_id
            entry 1:
                authorizations (3): decrypt derive sign
                description: unrelated-decrypt-acl
        """

        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(
                fromDump: dump,
                service: service,
                account: account
            ),
            .unparseable
        )
    }

    // MARK: - merge

    func testMergeAppendsOnlyMissingRequiredEntries() {
        let existing = ["apple-tool:", "apple:", "teamid:Q6L2SF6YDW"]
        let result = KeychainPartitionRepair.merge(existing: existing, required: required)
        XCTAssertEqual(result.added, ["teamid:3DQ7YC2YH2"])
        XCTAssertEqual(result.merged, existing + ["teamid:3DQ7YC2YH2"])
    }

    func testMergeAddsNothingWhenComplete() {
        let existing = required
        let result = KeychainPartitionRepair.merge(existing: existing, required: required)
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(result.merged, existing)
    }

    func testMergePreservesUnknownExistingEntries() {
        let existing = ["apple:", "teamid:UNKNOWN0000"]
        let result = KeychainPartitionRepair.merge(existing: existing, required: required)
        XCTAssertEqual(result.merged, ["apple:", "teamid:UNKNOWN0000", "apple-tool:", "teamid:3DQ7YC2YH2", "teamid:Q6L2SF6YDW"])
        XCTAssertEqual(result.added, ["apple-tool:", "teamid:3DQ7YC2YH2", "teamid:Q6L2SF6YDW"])
    }

    func testMergeSeedsFromEmptyExisting() {
        let result = KeychainPartitionRepair.merge(existing: [], required: required)
        XCTAssertEqual(result.merged, required)
        XCTAssertEqual(result.added, required)
    }

    // MARK: - Orchestrator

    func testRepairAddsMissingTeamAndVerifies() throws {
        let before = Self.dump(service: service, account: account, partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW")
        let after = Self.dump(service: service, account: account, partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW,teamid:3DQ7YC2YH2")
        let runner = FakeSecurityTool(dumps: [before, after], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )

        let outcome = try repair.repair(password: "hunter2")
        XCTAssertEqual(outcome, .repaired(added: ["teamid:3DQ7YC2YH2"], merged: ["apple-tool:", "apple:", "teamid:Q6L2SF6YDW", "teamid:3DQ7YC2YH2"]))

        // The set call must carry the full merged CSV and correct service/account.
        XCTAssertEqual(runner.setCalls.count, 1)
        XCTAssertEqual(runner.setCalls.first?.csv, "apple-tool:,apple:,teamid:Q6L2SF6YDW,teamid:3DQ7YC2YH2")
        XCTAssertEqual(runner.setCalls.first?.service, service)
        XCTAssertEqual(runner.setCalls.first?.account, account)
        XCTAssertEqual(runner.setCalls.first?.password, "hunter2")
    }

    func testRepairReturnsAlreadyCompleteWithoutWriting() throws {
        let complete = Self.dump(service: service, account: account, partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW,teamid:3DQ7YC2YH2")
        let runner = FakeSecurityTool(dumps: [complete], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )

        XCTAssertEqual(try repair.repair(password: "hunter2"), .alreadyComplete(existing: ["apple-tool:", "apple:", "teamid:Q6L2SF6YDW", "teamid:3DQ7YC2YH2"]))
        XCTAssertTrue(runner.setCalls.isEmpty, "No password write when nothing is missing")
    }

    func testRepairMapsAuthFailureToWrongPassword() {
        let before = Self.dump(service: service, account: account, partitions: "apple:,teamid:Q6L2SF6YDW")
        let runner = FakeSecurityTool(
            dumps: [before],
            setResult: SecurityToolResult(exitCode: 1, output: "SecKeychainItemSetAccessWithPassword: The user name or passphrase you entered is not correct. (-25293)")
        )
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )

        XCTAssertThrowsError(try repair.repair(password: "wrong")) { error in
            XCTAssertEqual(error as? KeychainPartitionRepairError, .wrongPassword)
        }
    }

    func testRepairThrowsVerificationFailedWhenEntryStillMissingAfterWrite() {
        let before = Self.dump(service: service, account: account, partitions: "apple:,teamid:Q6L2SF6YDW")
        // The "after" dump is unchanged: the write silently did not land.
        let runner = FakeSecurityTool(dumps: [before, before], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )

        XCTAssertThrowsError(try repair.repair(password: "hunter2")) { error in
            guard case .verificationFailed(let stillMissing) = error as? KeychainPartitionRepairError else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
            XCTAssertTrue(stillMissing.contains("teamid:3DQ7YC2YH2"))
        }
    }

    func testRepairThrowsItemNotFoundWithoutEverWriting() {
        let dump = Self.dump(service: "Some Other Service", account: account, partitions: "apple:")
        let runner = FakeSecurityTool(dumps: [dump], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )

        XCTAssertThrowsError(try repair.repair(password: "hunter2")) { error in
            XCTAssertEqual(error as? KeychainPartitionRepairError, .itemNotFound)
        }
        XCTAssertTrue(runner.setCalls.isEmpty, "Never write when the item is absent — the item must stay Claude-owned")
    }

    func testRepairRefusesToReplaceUnparseablePartitionList() throws {
        let dump = """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="tester"
            "svce"<blob>="Claude Code-credentials"
        access: <SecKeychainRef>
            entry 0:
                authorizations (3): decrypt derive sign
        """
        let runner = FakeSecurityTool(
            dumps: [dump],
            setResult: SecurityToolResult(exitCode: 0, output: "")
        )
        let repair = KeychainPartitionRepair(
            service: service,
            account: account,
            keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required,
            runner: runner
        )

        XCTAssertEqual(try repair.plan(), .unparseable)
        XCTAssertEqual(try repair.status(), .unparseable)
        XCTAssertThrowsError(try repair.repair(password: "hunter2")) { error in
            XCTAssertEqual(error as? KeychainPartitionRepairError, .unparseablePartitionList)
        }
        XCTAssertTrue(runner.setCalls.isEmpty, "Never replace an ACL whose existing partitions could not be preserved")
    }

    func testStatusReportsMissingEntries() throws {
        let dump = Self.dump(service: service, account: account, partitions: "apple-tool:,apple:,teamid:Q6L2SF6YDW")
        let runner = FakeSecurityTool(dumps: [dump], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )
        XCTAssertEqual(try repair.status(), .missing(["teamid:3DQ7YC2YH2"]))
    }

    func testStatusReportsItemNotFound() throws {
        let dump = Self.dump(service: "Some Other Service", account: account, partitions: "apple:")
        let runner = FakeSecurityTool(dumps: [dump], setResult: SecurityToolResult(exitCode: 0, output: ""))
        let repair = KeychainPartitionRepair(
            service: service, account: account, keychainPath: "/tmp/login.keychain-db",
            requiredPartitions: required, runner: runner
        )
        XCTAssertEqual(try repair.status(), .itemNotFound)
    }

    // MARK: - Opt-in interop (real /usr/bin/security, read side only)

    func testDumpKeychainReadIsNonInteractiveAndParseable() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_KEYCHAIN_INTEROP_TESTS"] == "1",
            "Opt-in only: exercises the real /usr/bin/security dump-keychain."
        )
        let tool = SystemSecurityTool()
        let keychain = KeychainPartitionRepair.defaultLoginKeychainPath()
        let dump = try tool.dumpKeychainACL(keychainPath: keychain)
        XCTAssertFalse(dump.isEmpty, "dump-keychain should produce ACL output for the login keychain")

        // A definitely-absent service must parse to itemNotFound — proving the
        // real dump feeds the parser correctly without any keychain write.
        let absent = "com.limitlifeboat.absent.\(UUID().uuidString)"
        XCTAssertEqual(
            KeychainPartitionRepair.parsePartitionList(fromDump: dump, service: absent, account: NSUserName()),
            .itemNotFound
        )
    }

    func testExpectTimeoutTerminatesUnmatchedPrompt() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/expect"),
            "Requires the system expect binary."
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboatExpectTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeSecurity = directory.appendingPathComponent("fake-security")
        let script = """
        #!/bin/sh
        trap '' HUP TERM
        printf 'Unrecognized authorization prompt:'
        while :; do
            read answer
        done
        """
        try Data(script.utf8).write(to: fakeSecurity)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeSecurity.path
        )

        let tool = SystemSecurityTool(
            securityPath: fakeSecurity.path,
            expectPath: "/usr/bin/expect",
            expectTimeoutSeconds: 1
        )
        let started = Date()
        let result = try tool.setPartitionList(
            csv: required.joined(separator: ","),
            service: service,
            account: account,
            keychainPath: "/tmp/login.keychain-db",
            password: "unused"
        )

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - Fixtures

    /// Builds a minimal `security dump-keychain -a` style block for one item.
    private static func dump(service: String, account: String, partitions: String) -> String {
        """
        keychain: "/Users/tester/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            "acct"<blob>="\(account)"
            "svce"<blob>="\(service)"
        access: <SecKeychainRef>
            entry 0:
                authorizations (1): partition_id
                description: \(partitions)
                applications (0):
        """
    }
}

private final class FakeSecurityTool: SecurityToolRunning, @unchecked Sendable {
    struct SetCall: Equatable {
        let csv: String
        let service: String
        let account: String
        let keychainPath: String
        let password: String
    }

    private var dumps: [String]
    private var dumpIndex = 0
    private let setResult: SecurityToolResult
    private(set) var setCalls: [SetCall] = []

    init(dumps: [String], setResult: SecurityToolResult) {
        self.dumps = dumps
        self.setResult = setResult
    }

    func dumpKeychainACL(keychainPath: String) throws -> String {
        defer { if dumpIndex < dumps.count - 1 { dumpIndex += 1 } }
        return dumps[min(dumpIndex, dumps.count - 1)]
    }

    func setPartitionList(
        csv: String,
        service: String,
        account: String,
        keychainPath: String,
        password: String
    ) throws -> SecurityToolResult {
        setCalls.append(SetCall(csv: csv, service: service, account: account, keychainPath: keychainPath, password: password))
        return setResult
    }
}
