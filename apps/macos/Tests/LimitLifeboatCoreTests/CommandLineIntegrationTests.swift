import XCTest
@testable import LimitLifeboatCore

final class CommandLineToolInstallerTests: XCTestCase {
    private var directory: URL!
    private var tool: URL!
    private var link: URL { directory.appendingPathComponent("bin/limit-lifeboat") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helpers = directory.appendingPathComponent("Limit Lifeboat.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        tool = helpers.appendingPathComponent("limit-lifeboat")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLinksCreatesBinAndUninstallsOnlyItsOwnLink() throws {
        let installer = CommandLineToolInstaller(linkURL: link)
        XCTAssertEqual(installer.status(bundledTool: tool), .notInstalled)

        try installer.install(bundledTool: tool)
        XCTAssertEqual(installer.status(bundledTool: tool), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), tool.path)

        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testNeverReplacesSomeoneElsesFile() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("self-built".utf8).write(to: link)
        let installer = CommandLineToolInstaller(linkURL: link)

        XCTAssertEqual(installer.status(bundledTool: tool), .occupied)
        XCTAssertThrowsError(try installer.install(bundledTool: tool))
        try installer.uninstall()
        XCTAssertEqual(try String(contentsOf: link), "self-built")
    }

    func testReplacesALinkToAnOlderCopyOfTheApp() throws {
        let old = directory.appendingPathComponent("Old/Limit Lifeboat.app/Contents/Helpers/limit-lifeboat")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        let installer = CommandLineToolInstaller(linkURL: link)

        XCTAssertEqual(installer.status(bundledTool: tool), .notInstalled)
        try installer.install(bundledTool: tool)
        XCTAssertEqual(installer.status(bundledTool: tool), .installed)
    }
}

extension CommandLineToolInstallerTests {
    func testRepointsOnlyAnExistingLinkOfOursAfterTheAppMoved() throws {
        let installer = CommandLineToolInstaller(linkURL: link)
        XCTAssertFalse(installer.repointIfMoved(bundledTool: tool), "never creates a link")

        let old = directory.appendingPathComponent("Old/Limit Lifeboat.app/Contents/Helpers/limit-lifeboat")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        XCTAssertTrue(installer.repointIfMoved(bundledTool: tool))
        XCTAssertEqual(installer.status(bundledTool: tool), .installed)
        XCTAssertFalse(installer.repointIfMoved(bundledTool: tool), "already current")
    }

    func testRefusesToLinkIntoADiskImageOrTranslocatedCopy() {
        XCTAssertTrue(CommandLineToolInstaller.isTemporaryLocation(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Limit Lifeboat.app/Contents/Helpers/limit-lifeboat")))
        XCTAssertFalse(CommandLineToolInstaller.isTemporaryLocation(tool))
        let installer = CommandLineToolInstaller(linkURL: link)
        XCTAssertThrowsError(try installer.install(bundledTool: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Limit Lifeboat.app/Contents/Helpers/limit-lifeboat")))
    }
}

final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var settingsURL: URL!

    override func setUpWithError() throws {
        settingsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: settingsURL)
        try? FileManager.default.removeItem(at: settingsURL.appendingPathExtension("limit-lifeboat-backup"))
    }

    private func read() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }

    func testSetsAndRemovesOnlyItsOwnStatusLineKeepingOtherSettings() throws {
        try Data(#"{"model":"opus","hooks":{"Stop":[]}}"#.utf8).write(to: settingsURL)
        let installer = ClaudeStatusLineInstaller(settingsURL: settingsURL)

        try installer.install(toolPath: "/Users/me/.local/bin/limit-lifeboat")
        XCTAssertEqual(installer.status(), .installed)
        let statusLine = try XCTUnwrap(try read()["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "'/Users/me/.local/bin/limit-lifeboat' statusline")
        XCTAssertEqual(try read()["model"] as? String, "opus")

        try installer.uninstall()
        XCTAssertEqual(installer.status(), .notSet)
        XCTAssertEqual(try read()["model"] as? String, "opus")
        XCTAssertNotNil(try read()["hooks"])
    }

    func testOwnershipIsExact() {
        XCTAssertTrue(ClaudeStatusLineInstaller.isOurs("'/Users/me/.local/bin/limit-lifeboat' statusline"))
        XCTAssertTrue(ClaudeStatusLineInstaller.isOurs("limit-lifeboat statusline"))
        XCTAssertFalse(ClaudeStatusLineInstaller.isOurs("foo && limit-lifeboat statusline"))
        XCTAssertFalse(ClaudeStatusLineInstaller.isOurs("'/x/limit-lifeboat' statusline; rm -rf ~"))
        XCTAssertFalse(ClaudeStatusLineInstaller.isOurs("~/my-line.sh"))
    }

    func testNeverOverwritesTheUsersOwnStatusLine() throws {
        try Data(#"{"statusLine":{"type":"command","command":"~/my-line.sh"}}"#.utf8).write(to: settingsURL)
        let installer = ClaudeStatusLineInstaller(settingsURL: settingsURL)

        XCTAssertEqual(installer.status(), .other("~/my-line.sh"))
        XCTAssertThrowsError(try installer.install(toolPath: "/x/limit-lifeboat"))
        try installer.uninstall()
        XCTAssertEqual((try read()["statusLine"] as? [String: Any])?["command"] as? String, "~/my-line.sh")
    }
}
