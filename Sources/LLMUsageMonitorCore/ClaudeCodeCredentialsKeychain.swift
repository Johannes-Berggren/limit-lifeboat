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
    func deleteLiveItem() throws
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

        return Self.decodePasswordOutput(result.output)
    }

    public func writeLiveItemJSON(_ data: Data) throws {
        // The item JSON is secret material, so it must never appear in the
        // process argument list (visible to `ps`). `security -i` reads the
        // whole add command from stdin instead.
        let command = Self.makeAddGenericPasswordCommand(
            account: NSUserName(),
            service: Self.serviceName,
            value: String(decoding: data, as: UTF8.self)
        )
        let result = try runSecurity(arguments: ["-i"], input: Data((command + "\n").utf8))

        guard result.status == 0 else {
            throw ClaudeCodeCredentialsKeychainError.securityToolFailed(
                status: result.status,
                message: result.errorOutput
            )
        }
    }

    public func deleteLiveItem() throws {
        let result = try runSecurity(arguments: [
            "delete-generic-password",
            "-a", NSUserName(),
            "-s", Self.serviceName
        ])
        guard result.status == 0 || result.status == Self.itemNotFoundStatus else {
            throw ClaudeCodeCredentialsKeychainError.securityToolFailed(
                status: result.status,
                message: result.errorOutput
            )
        }
    }

    /// Normalizes `security find-generic-password -w` output into the stored
    /// password bytes, or nil when the output is empty.
    ///
    /// `-w` prints an ASCII password as plain text, but a password containing
    /// ANY non-ASCII byte as bare lowercase hex with no "0x" prefix (the
    /// "0x<HEX> \"...\"" form only appears in `-g` output). Our passwords are
    /// JSON, so text starting with "{" or "[" is taken verbatim before the
    /// hex interpretation gets a chance to misread an all-hex-looking value.
    static func decodePasswordOutput(_ raw: String) -> Data? {
        let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }
        if output.hasPrefix("{") || output.hasPrefix("[") {
            return Data(output.utf8)
        }
        if let decoded = decodeHexPassword(output) {
            return decoded
        }
        return Data(output.utf8)
    }

    /// Builds the `add-generic-password` line fed to `security -i`. The value
    /// is double-quoted with backslashes escaped before inner quotes; raw
    /// UTF-8 passes through unchanged.
    static func makeAddGenericPasswordCommand(account: String, service: String, value: String) -> String {
        "add-generic-password -U -a \"\(escapeQuoted(account))\" -s \"\(escapeQuoted(service))\" -w \"\(escapeQuoted(value))\""
    }

    private static func escapeQuoted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func decodeHexPassword(_ output: String) -> Data? {
        var hexText = Substring(output)
        if hexText.hasPrefix("0x") {
            hexText = hexText.dropFirst(2)
        }
        guard !hexText.isEmpty,
              hexText.count.isMultiple(of: 2),
              hexText.allSatisfy(\.isHexDigit) else {
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

    private func runSecurity(arguments: [String], input: Data? = nil) throws -> (status: Int32, output: String, errorOutput: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        try process.run()
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }
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
