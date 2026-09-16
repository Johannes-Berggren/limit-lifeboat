import XCTest
@testable import LimitLifeboatCore

final class BudgetModeTests: XCTestCase {
    private let applier = BudgetModeApplier()

    func testFrugalWritesDocumentedKeysAndRecordsWhatItReplaced() throws {
        var settings: [String: Any] = [
            "model": "opus",
            "effortLevel": "xhigh",
            "env": ["FOO": "1"]
        ]

        let record = try XCTUnwrap(applier.apply(.frugal, to: &settings, replacing: nil))

        XCTAssertEqual(settings["model"] as? String, "sonnet")
        XCTAssertEqual(settings["advisorModel"] as? String, "opus")
        XCTAssertEqual(settings["maxEffortLevel"] as? String, "medium")
        XCTAssertEqual(settings["effortLevel"] as? String, "xhigh")
        XCTAssertEqual(settings["env"] as? [String: String], ["FOO": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "haiku"])
        XCTAssertEqual(record.previous, ["model": "\"opus\""])
        XCTAssertEqual(applier.status(settings: settings, record: record), .active(.frugal))
    }

    func testReturningToQualityRestoresTheOriginalExactly() throws {
        let original: [String: Any] = ["model": "opus", "env": ["FOO": "1"], "tui": "fullscreen"]
        var settings = original

        let frugal = applier.apply(.frugal, to: &settings, replacing: nil)
        let balanced = applier.apply(.balanced, to: &settings, replacing: frugal)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(settings["maxEffortLevel"] as? String, "high")

        let quality = applier.apply(.quality, to: &settings, replacing: balanced)

        XCTAssertNil(quality)
        XCTAssertEqual(NSDictionary(dictionary: settings), NSDictionary(dictionary: original))
    }

    func testValuesChangedByTheUserSinceAreKept() throws {
        var settings: [String: Any] = [:]
        let record = applier.apply(.frugal, to: &settings, replacing: nil)
        settings["model"] = "fable"

        XCTAssertEqual(applier.status(settings: settings, record: record), .modified(.frugal))
        _ = applier.apply(.quality, to: &settings, replacing: record)

        XCTAssertEqual(settings["model"] as? String, "fable")
        XCTAssertNil(settings["advisorModel"])
        XCTAssertNil(settings["env"])
    }

    func testControllerRoundTripsThroughFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"effortLevel":"xhigh","model":"opus"}"#.utf8).write(to: settingsURL)
        let controller = BudgetModeController(
            file: ClaudeSettingsFile(url: settingsURL),
            recordURL: directory.appendingPathComponent(BudgetModeController.recordFileName)
        )

        try controller.apply(.frugal)
        XCTAssertEqual(try controller.status(), .active(.frugal))

        try controller.apply(.quality)
        XCTAssertEqual(try controller.status(), .active(.quality))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: String])
        XCTAssertEqual(restored, ["effortLevel": "xhigh", "model": "opus"])
    }

    func testFailedSettingsWriteLeavesNoRecordBehind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A settings path whose parent is a file cannot be written.
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let recordURL = directory.appendingPathComponent(BudgetModeController.recordFileName)
        let controller = BudgetModeController(
            file: ClaudeSettingsFile(url: blocker.appendingPathComponent("settings.json")),
            recordURL: recordURL
        )

        XCTAssertThrowsError(try controller.apply(.frugal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testCorruptRecordRefusesToApplyInsteadOfOverwritingTheOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        try Data(#"{"model":"sonnet"}"#.utf8).write(to: settingsURL)
        let recordURL = directory.appendingPathComponent(BudgetModeController.recordFileName)
        try Data(#"{"mode":"frugal","future":true}"#.utf8).write(to: recordURL)
        let controller = BudgetModeController(file: ClaudeSettingsFile(url: settingsURL), recordURL: recordURL)

        XCTAssertThrowsError(try controller.status())
        XCTAssertThrowsError(try controller.apply(.balanced))
        XCTAssertEqual(try String(contentsOf: settingsURL), #"{"model":"sonnet"}"#)
        XCTAssertEqual(try String(contentsOf: recordURL), #"{"mode":"frugal","future":true}"#)
    }

    func testSuggestsNextCheaperModeOnlyWhenSwitchingCannotHelp() {
        XCTAssertEqual(
            BudgetSuggestionPolicy.suggestion(provider: .claude, current: .active(.quality), hasPaceAlert: true, hasSwitchCandidate: false),
            .balanced
        )
        XCTAssertEqual(
            BudgetSuggestionPolicy.suggestion(provider: .claude, current: .modified(.balanced), hasPaceAlert: true, hasSwitchCandidate: false),
            .frugal
        )
        XCTAssertNil(BudgetSuggestionPolicy.suggestion(provider: .claude, current: .active(.frugal), hasPaceAlert: true, hasSwitchCandidate: false))
        XCTAssertNil(BudgetSuggestionPolicy.suggestion(provider: .claude, current: .active(.quality), hasPaceAlert: true, hasSwitchCandidate: true))
        XCTAssertNil(BudgetSuggestionPolicy.suggestion(provider: .claude, current: .active(.quality), hasPaceAlert: false, hasSwitchCandidate: false))
        XCTAssertNil(BudgetSuggestionPolicy.suggestion(provider: .codex, current: .active(.quality), hasPaceAlert: true, hasSwitchCandidate: false))
    }
}
