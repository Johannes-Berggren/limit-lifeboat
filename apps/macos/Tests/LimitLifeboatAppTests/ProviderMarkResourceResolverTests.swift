import Foundation
@testable import LimitLifeboat
import LimitLifeboatCore
import XCTest

final class ProviderMarkResourceResolverTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testLoadsPackagedAppResource() throws {
        let appURL = temporaryDirectory.appendingPathComponent("Limit Lifeboat.app")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try installValidMark(named: "claude", below: resourcesURL)

        let resolver = ProviderMarkResourceResolver(
            resourceURL: resourcesURL,
            bundleURL: appURL,
            executableURL: appURL.appendingPathComponent("Contents/MacOS/Limit Lifeboat")
        )

        XCTAssertNotNil(resolver.image(named: "claude"))
    }

    func testLoadsBundleURLSiblingForSwiftRun() throws {
        let swiftRunURL = temporaryDirectory.appendingPathComponent("swift-run", isDirectory: true)
        try installValidMark(named: "codex", below: swiftRunURL)

        let resolver = ProviderMarkResourceResolver(
            resourceURL: nil,
            bundleURL: swiftRunURL,
            executableURL: nil
        )

        XCTAssertNotNil(resolver.image(named: "codex"))
    }

    func testLoadsExecutableSiblingForSwiftRun() throws {
        let buildURL = temporaryDirectory.appendingPathComponent("debug", isDirectory: true)
        try installValidMark(named: "claude", below: buildURL)

        let resolver = ProviderMarkResourceResolver(
            resourceURL: nil,
            bundleURL: temporaryDirectory.appendingPathComponent("unrelated", isDirectory: true),
            executableURL: buildURL.appendingPathComponent("LimitLifeboat")
        )

        XCTAssertNotNil(resolver.image(named: "claude"))
    }

    func testMissingResourceBundleReturnsNil() {
        let resolver = ProviderMarkResourceResolver(
            resourceURL: temporaryDirectory.appendingPathComponent("Resources"),
            bundleURL: temporaryDirectory.appendingPathComponent("Limit Lifeboat.app"),
            executableURL: temporaryDirectory.appendingPathComponent("MacOS/Limit Lifeboat")
        )

        XCTAssertNil(resolver.image(named: "codex"))
    }

    func testMissingResourceFileReturnsNil() throws {
        let resourcesURL = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL.appendingPathComponent(
                ProviderMarkResourceResolver.resourceBundleName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let resolver = ProviderMarkResourceResolver(
            resourceURL: resourcesURL,
            bundleURL: temporaryDirectory,
            executableURL: nil
        )

        XCTAssertNil(resolver.image(named: "codex"))
    }

    func testInvalidImageReturnsNil() throws {
        let resourcesURL = temporaryDirectory.appendingPathComponent("Resources", isDirectory: true)
        let imageURL = markURL(named: "codex", below: resourcesURL)
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a PDF image".utf8).write(to: imageURL)
        let resolver = ProviderMarkResourceResolver(
            resourceURL: resourcesURL,
            bundleURL: temporaryDirectory,
            executableURL: nil
        )

        XCTAssertNil(resolver.image(named: "codex"))
    }

    func testMissingImageUsesProviderNameFallback() {
        let result = ProviderMarkTitleFallback.attributedString(
            for: .claude,
            textAttributes: [:]
        )

        XCTAssertEqual(result.string, " CLAUDE ")
    }

    private func installValidMark(named name: String, below parentURL: URL) throws {
        let destinationURL = markURL(named: name, below: parentURL)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: sourceMarkURL(named: name),
            to: destinationURL
        )
    }

    private func markURL(named name: String, below parentURL: URL) -> URL {
        parentURL
            .appendingPathComponent(
                ProviderMarkResourceResolver.resourceBundleName,
                isDirectory: true
            )
            .appendingPathComponent("ProviderMarks", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("pdf")
    }

    private func sourceMarkURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LimitLifeboat/Resources/ProviderMarks")
            .appendingPathComponent(name)
            .appendingPathExtension("pdf")
    }
}
