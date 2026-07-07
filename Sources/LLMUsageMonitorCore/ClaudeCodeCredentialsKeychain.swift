import Foundation

public enum ClaudeCodeCredentialsKeychainError: Error, LocalizedError {
    case securityToolFailed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .securityToolFailed(let status, let message):
            let detail = message.isEmpty ? "no error output" : message
            return "/usr/bin/security exited with status \(status) (\(detail))."
        }
    }
}

/// Where the live Claude Code CLI credentials come from and go back to.
/// Abstracted so tests (and the switcher's snapshot store) can substitute an
/// in-memory source.
public protocol ClaudeCLICredentialSource: Sendable {
    /// The full keychain item JSON, or nil when no item exists (logged out).
    func readLiveItemJSON() throws -> Data?
    func writeLiveItemJSON(_ data: Data) throws
}

/// Reads and writes the "Claude Code-credentials" generic password via
/// /usr/bin/security. The CLI owns that item, so going through the same tool
/// (rather than SecItem, which would be scoped to this app's identity) keeps
/// the item readable by Claude Code afterwards.
public struct ClaudeCodeCredentialsKeychain: ClaudeCLICredentialSource {
    public static let serviceName = "Claude Code-credentials"

    /// `security` uses this exit status for errSecItemNotFound.
    private static let itemNotFoundStatus: Int32 = 44

    public init() {}

    public func readLiveItemJSON() throws -> Data? {
        let result = try runSecurity(arguments: [
            "find-generic-password",
            "-s", Self.serviceName,
            "-w"
        ])

        guard result.status == 0 else {
            if result.status == Self.itemNotFoundStatus
                || result.errorOutput.localizedCaseInsensitiveContains("could not be found") {
                return nil
            }
            throw ClaudeCodeCredentialsKeychainError.securityToolFailed(
                status: result.status,
                message: result.errorOutput
            )
        }

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }

        // `security -w` prints non-ASCII passwords as "0x<HEX>  \"...\"";
        // decode that form defensively before assuming plain text.
        if output.hasPrefix("0x"), let decoded = decodeHexPassword(output) {
            return decoded
        }
        return Data(output.utf8)
    }

    public func writeLiveItemJSON(_ data: Data) throws {
        let result = try runSecurity(arguments: [
            "add-generic-password",
            "-U",
            "-a", NSUserName(),
            "-s", Self.serviceName,
            "-w", String(decoding: data, as: UTF8.self)
        ])

        guard result.status == 0 else {
            throw ClaudeCodeCredentialsKeychainError.securityToolFailed(
                status: result.status,
                message: result.errorOutput
            )
        }
    }

    private func decodeHexPassword(_ output: String) -> Data? {
        let hexText = output
            .dropFirst(2)
            .prefix { !$0.isWhitespace }
        guard !hexText.isEmpty, hexText.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: hexText.count / 2)
        var index = hexText.startIndex
        while index < hexText.endIndex {
            let next = hexText.index(index, offsetBy: 2)
            guard let byte = UInt8(hexText[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private func runSecurity(arguments: [String]) throws -> (status: Int32, output: String, errorOutput: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: outputData, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

/// Replaces only the "claudeAiOauth" key of the keychain item JSON, keeping
/// every sibling (especially the machine-level "mcpOAuth") byte-for-byte in
/// place, so an account switch never clobbers machine state.
public func mergeClaudeAiOauth(_ claudeAiOauthObjectJSON: Data, intoItemJSON existing: Data?) -> Data {
    var item: [String: Any] = [:]
    if let existing,
       let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
        item = parsed
    }

    if let claudeAiOauth = try? JSONSerialization.jsonObject(with: claudeAiOauthObjectJSON) as? [String: Any] {
        item["claudeAiOauth"] = claudeAiOauth
    }

    guard let merged = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else {
        return existing ?? Data("{}".utf8)
    }
    return merged
}
