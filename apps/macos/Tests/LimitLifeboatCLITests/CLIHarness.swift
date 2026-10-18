import Foundation
import XCTest
@testable import LimitLifeboatCore

/// Runs the built `limit-lifeboat` binary against a throwaway home directory.
///
/// `CFFIXED_USER_HOME` moves the user's Application Support folder, so the CLI
/// reads `<home>/Library/Application Support/LimitLifeboat` — the same
/// resolution path it uses for real — and never the developer's own store.
struct CLIHarness {
    let home: URL
    let store: URL
    let repository: ProfileRepository

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("limit-lifeboat-cli-\(UUID().uuidString)", isDirectory: true)
        store = home
            .appendingPathComponent("Library/Application Support/LimitLifeboat", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        repository = try ProfileRepository(applicationSupportDirectory: store)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static var binaryURL: URL? {
        // The test bundle sits beside the products in .build/<config>/.
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("limit-lifeboat")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func run(_ arguments: [String], environment: [String: String] = [:]) throws -> Result {
        let binary = try XCTUnwrap(Self.binaryURL, "the limit-lifeboat product was not built beside the tests")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = home.path
        env["HOME"] = home.path
        process.environment = env.merging(environment) { $1 }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waiting so a large output cannot fill the pipe and stall.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }
}
