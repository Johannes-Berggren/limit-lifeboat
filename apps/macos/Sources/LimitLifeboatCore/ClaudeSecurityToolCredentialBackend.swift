import Darwin
import Foundation

/// One invocation of Apple's bundled Keychain command-line tool.
///
/// The environment is deliberately not configurable. Credential bytes are
/// normally passed only through standard input and never appear in argv or an
/// environment variable. The sole exception is the oversized-credential
/// fallback (see `updateInvocation`): a credential too large for `security`'s
/// fixed interactive command buffer is passed as an `add-generic-password`
/// argv element, which is bounded only by `ARG_MAX`. `description` redacts
/// those bytes so they never reach a log.
struct ClaudeSecurityToolInvocation:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let executablePath: String
    let arguments: [String]
    let standardInput: Data?

    init(
        executablePath: String,
        arguments: [String],
        standardInput: Data?
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.standardInput = standardInput
    }

    var description: String {
        let inputDescription = standardInput.map {
            "<redacted \($0.count) bytes>"
        } ?? "none"
        return "ClaudeSecurityToolInvocation(executablePath: \(executablePath), "
            + "arguments: \(redactedArguments), standardInput: \(inputDescription))"
    }

    var debugDescription: String { description }

    /// The oversized-credential fallback carries the secret as the argv element
    /// following `-X` (hex) or `-w`/`-p` (raw). Redact that element so logging
    /// an invocation can never leak credential bytes, mirroring how
    /// `standardInput` is redacted for the interactive path.
    private var redactedArguments: [String] {
        var redacted = arguments
        var index = redacted.startIndex
        while index < redacted.endIndex {
            if ["-X", "-w", "-p"].contains(redacted[index]),
               redacted.index(after: index) < redacted.endIndex {
                let secretIndex = redacted.index(after: index)
                redacted[secretIndex] =
                    "<redacted \(redacted[secretIndex].utf8.count) bytes>"
                index = redacted.index(after: secretIndex)
            } else {
                index = redacted.index(after: index)
            }
        }
        return redacted
    }
}

struct ClaudeSecurityToolResult:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data

    init(
        exitCode: Int32,
        standardOutput: Data = Data(),
        standardError: Data = Data()
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    var description: String {
        "ClaudeSecurityToolResult(exitCode: \(exitCode), "
            + "standardOutput: <redacted \(standardOutput.count) bytes>, "
            + "standardError: <redacted \(standardError.count) bytes>)"
    }

    var debugDescription: String { description }
}

protocol ClaudeSecurityToolRunning: Sendable {
    func run(_ invocation: ClaudeSecurityToolInvocation) throws -> ClaudeSecurityToolResult
}

protocol ClaudeLiveCredentialBackend: Sendable {
    func readData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool
    ) throws -> Data

    func updateData(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool,
        mutationAttempt: ClaudeCredentialWriteAttempt?
    ) throws
}

public enum ClaudeSecurityToolArgumentField: String, Equatable, Sendable {
    case serviceName
    case accountName
    case label
    case keychainPath
}

public enum ClaudeSecurityToolCredentialError: Error, Equatable, Sendable, LocalizedError {
    case authorizationDenied
    case userCancelled
    case keychainLocked
    case itemChanged
    case invalidArgument(field: ClaudeSecurityToolArgumentField)
    case payloadTooLarge(commandByteCount: Int, maximumByteCount: Int)
    case malformedToolOutput
    case verificationFailed
    case toolTimedOut
    case toolFailed(exitCode: Int32?)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Keychain access was not authorized."
        case .userCancelled:
            return "Keychain authorization was cancelled."
        case .keychainLocked:
            return "The Keychain is locked."
        case .itemChanged:
            return "The Claude credential item changed before the operation completed."
        case .invalidArgument(let field):
            return "The \(field.rawValue) cannot be passed safely to the Keychain tool."
        case .payloadTooLarge(let commandByteCount, let maximumByteCount):
            return "The credential update requires \(commandByteCount) command bytes; the Keychain tool accepts at most \(maximumByteCount)."
        case .malformedToolOutput:
            return "The Keychain tool returned an invalid credential response."
        case .verificationFailed:
            return "The Keychain tool returned success, but the stored credential did not match."
        case .toolTimedOut:
            return "The Keychain tool did not finish in time."
        case .toolFailed(let exitCode):
            if let exitCode {
                return "The Keychain tool failed with exit code \(exitCode)."
            }
            return "The Keychain tool could not be run."
        }
    }
}

/// Reads and updates an existing Claude credential through `/usr/bin/security`.
///
/// There is intentionally no API to request creation or deletion. Updating
/// uses `security -i` so credential bytes are never visible in the process
/// argument list. Apple's `-U` operation is an upsert and cannot atomically
/// target a persistent reference, so callers must also hold the cooperative
/// storage lock; `verifyCurrentItem` detects a non-cooperating replacement
/// immediately before and after the tool call.
struct ClaudeSecurityToolCredentialBackend: ClaudeLiveCredentialBackend, Sendable {
    static let executablePath = "/usr/bin/security"
    static let interactiveCommandBufferByteLimit = 4_096
    /// Ceiling for the oversized-credential fallback, which passes the hex
    /// secret as an argv element. `ARG_MAX` is 1 MiB and the runner clears the
    /// environment, so 512 KiB leaves a 2x margin for the argv pointer array
    /// and kernel reservation while capping the raw credential near ~256 KiB —
    /// far above realistic `mcpOAuth`-inflated credential growth.
    static let directCommandArgumentByteLimit = 524_288

    private let runner: any ClaudeSecurityToolRunning

    init(
        runner: any ClaudeSecurityToolRunning = SystemClaudeSecurityToolRunner()
    ) {
        self.runner = runner
    }

    func readData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool
    ) throws -> Data {
        let invocation = ClaudeSecurityToolInvocation(
            executablePath: Self.executablePath,
            arguments: [
                "find-generic-password",
                "-a", location.accountName,
                "-s", location.serviceName,
                "-g",
                location.keychainPath
            ],
            standardInput: nil
        )
        try authorizeAccess(accessMode)
        guard try verifyBefore() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        let result = try run(invocation)
        guard try verifyAfter() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        guard result.exitCode == 0 else {
            throw Self.failure(for: result)
        }

        return try Self.passwordData(from: result.standardError)
    }

    func updateData(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        authorizeAccess: @Sendable (CredentialAccessMode) throws -> Void,
        verifyBefore: @Sendable () throws -> Bool,
        verifyAfter: @Sendable () throws -> Bool,
        mutationAttempt: ClaudeCredentialWriteAttempt? = nil
    ) throws {
        let invocation = try Self.updateInvocation(data: data, location: location)
        try authorizeAccess(accessMode)

        guard try verifyBefore() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }

        // This is the first point at which the helper could mutate the item.
        // The transaction uses the receipt to distinguish prompt/preflight
        // failures from verification failures after a possible commit.
        mutationAttempt?.markHelperStarted()
        let result = try run(invocation)
        if result.exitCode == 0 {
            mutationAttempt?.markHelperSucceeded()
        }

        guard try verifyAfter() else {
            throw ClaudeSecurityToolCredentialError.itemChanged
        }
        guard result.exitCode == 0 else {
            throw Self.failure(for: result)
        }
    }

    private func run(
        _ invocation: ClaudeSecurityToolInvocation
    ) throws -> ClaudeSecurityToolResult {
        do {
            return try runner.run(invocation)
        } catch SystemClaudeSecurityToolRunnerError.timedOut {
            throw ClaudeSecurityToolCredentialError.toolTimedOut
        } catch {
            throw ClaudeSecurityToolCredentialError.toolFailed(exitCode: nil)
        }
    }

    private static func updateInvocation(
        data: Data,
        location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolInvocation {
        // Validate the raw field values once, up front. Validity is
        // independent of the transport chosen below.
        let rawAccount = try validatedRawArgument(
            location.accountName,
            field: .accountName
        )
        let rawService = try validatedRawArgument(
            location.serviceName,
            field: .serviceName
        )
        let rawLabel = try validatedRawArgument(
            location.label,
            field: .label
        )
        let rawKeychain = try validatedRawArgument(
            location.keychainPath,
            field: .keychainPath
        )

        let (hexByteCount, hexOverflow) = data.count.multipliedReportingOverflow(
            by: 2
        )

        // Preferred transport: pipe the whole command over stdin so no secret
        // byte ever reaches argv. This only works while the command fits
        // security's fixed interactive command buffer.
        let account = escapedInteractiveArgument(rawAccount)
        let service = escapedInteractiveArgument(rawService)
        let label = escapedInteractiveArgument(rawLabel)
        let keychain = escapedInteractiveArgument(rawKeychain)
        let commandPrefix = "add-generic-password -U"
            + " -a \(account)"
            + " -s \(service)"
            + " -l \(label)"
            + " -X \""
        let commandSuffix = "\" \(keychain)\n"
        let fixedByteCount = commandPrefix.utf8.count
            + commandSuffix.utf8.count
            + 1 // security's terminating NUL
        let (commandByteCount, commandOverflow) =
            fixedByteCount.addingReportingOverflow(hexByteCount)

        if !hexOverflow,
           !commandOverflow,
           commandByteCount <= interactiveCommandBufferByteLimit {
            // Avoid materializing a second copy of the credential. The complete
            // command, LF, and security's NUL fit the fixed interactive buffer.
            let command = commandPrefix + lowercaseHex(data) + commandSuffix
            return ClaudeSecurityToolInvocation(
                executablePath: executablePath,
                arguments: ["-i"],
                standardInput: Data(command.utf8)
            )
        }

        // Fallback for a credential too large for the interactive buffer (the
        // provider blob grows with preserved sibling keys such as mcpOAuth).
        // Invoke security directly and pass the hex secret as an argv element,
        // which is bounded by ARG_MAX rather than the interactive buffer. Same
        // executable, so the item ACL and apple-tool: partition trust still
        // apply and the write stays prompt-free. The secret is briefly visible
        // in the process argument list; `description` redacts it for logs.
        let argumentFixedByteCount =
            "add-generic-password".utf8.count
            + "-U".utf8.count
            + "-a".utf8.count + rawAccount.utf8.count
            + "-s".utf8.count + rawService.utf8.count
            + "-l".utf8.count + rawLabel.utf8.count
            + "-X".utf8.count
            + rawKeychain.utf8.count
        let (argumentByteCount, argumentOverflow) =
            argumentFixedByteCount.addingReportingOverflow(hexByteCount)

        guard !hexOverflow,
              !argumentOverflow,
              argumentByteCount <= directCommandArgumentByteLimit else {
            throw ClaudeSecurityToolCredentialError.payloadTooLarge(
                commandByteCount: hexOverflow || argumentOverflow
                    ? Int.max
                    : argumentByteCount,
                maximumByteCount: directCommandArgumentByteLimit
            )
        }

        return ClaudeSecurityToolInvocation(
            executablePath: executablePath,
            arguments: [
                "add-generic-password", "-U",
                "-a", rawAccount,
                "-s", rawService,
                "-l", rawLabel,
                "-X", lowercaseHex(data),
                rawKeychain
            ],
            standardInput: nil
        )
    }

    /// Rejects bytes that cannot be carried safely to the Keychain tool by
    /// either transport, and returns the value unchanged. A NUL would truncate
    /// an argv element (argv is a NUL-terminated C string); LF/CR would split
    /// an interactive command line. Enforcing both on every path keeps a given
    /// location's validity independent of the credential size.
    private static func validatedRawArgument(
        _ value: String,
        field: ClaudeSecurityToolArgumentField
    ) throws -> String {
        guard !value.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value == 10 || $0.value == 13
        }) else {
            throw ClaudeSecurityToolCredentialError.invalidArgument(field: field)
        }
        return value
    }

    /// Escapes and double-quotes an already-validated value for embedding in a
    /// `security -i` interactive command line. The interactive tokenizer
    /// unquotes this back to the original value, so the argv fallback passes
    /// the unescaped value instead.
    private static func escapedInteractiveArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func lowercaseHex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(data.count * 2)
        for byte in data {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// `security find-generic-password -g` writes one unambiguous password
    /// record to stderr. Printable bytes are wrapped in quotes; any
    /// non-printable byte or backslash causes the complete value to be emitted
    /// as `0x` hex before a lossy display rendering. Parse only the exact
    /// machine-recoverable form and never surface either stream in errors.
    private static func passwordData(
        from toolError: Data
    ) throws -> Data {
        let prefix = Data("password: ".utf8)
        guard toolError.starts(with: prefix),
              toolError.last == 0x0a else {
            throw ClaudeSecurityToolCredentialError.malformedToolOutput
        }

        let body = toolError.dropFirst(prefix.count).dropLast()
        guard !body.contains(0x0a), !body.contains(0x0d) else {
            throw ClaudeSecurityToolCredentialError.malformedToolOutput
        }
        guard !body.isEmpty else {
            return Data()
        }

        if body.starts(with: [0x30, 0x78]) {
            guard let separator = body.firstIndex(of: 0x20) else {
                throw ClaudeSecurityToolCredentialError.malformedToolOutput
            }
            let encoded = body[body.index(body.startIndex, offsetBy: 2)..<separator]
            guard !encoded.isEmpty,
                  encoded.count.isMultiple(of: 2),
                  let decoded = Data(strictASCIIHex: encoded) else {
                throw ClaudeSecurityToolCredentialError.malformedToolOutput
            }

            let display = body[body.index(after: separator)...]
            if !display.isEmpty {
                guard display.count >= 3,
                      display[display.startIndex] == 0x20,
                      display[display.index(after: display.startIndex)] == 0x22,
                      display.last == 0x22,
                      display.allSatisfy({ 0x20...0x7e ~= $0 }) else {
                    throw ClaudeSecurityToolCredentialError.malformedToolOutput
                }
            }
            return decoded
        }

        guard body.first == 0x22,
              body.last == 0x22,
              body.count >= 3 else {
            throw ClaudeSecurityToolCredentialError.malformedToolOutput
        }
        let printable = body.dropFirst().dropLast()
        guard printable.allSatisfy({
            0x20...0x7e ~= $0 && $0 != 0x5c
        }) else {
            throw ClaudeSecurityToolCredentialError.malformedToolOutput
        }
        return Data(printable)
    }

    private static func failure(
        for result: ClaudeSecurityToolResult
    ) -> ClaudeSecurityToolCredentialError {
        // stdout can contain the credential, so failure classification is
        // intentionally based only on the status and sanitized stderr text.
        let stderr = String(decoding: result.standardError, as: UTF8.self)
            .lowercased()

        if result.exitCode == 44
            || stderr.contains("errsecitemnotfound")
            || stderr.contains("item could not be found")
            || stderr.contains("specified item could not be found")
        {
            return .itemChanged
        }
        if stderr.contains("keychain is locked")
            || stderr.contains("keychain was locked")
            || stderr.contains("locked keychain")
            || stderr.contains("errsecinteractionnotallowed")
            || stderr.contains("interaction is not allowed")
            || stderr.contains("interaction not allowed")
        {
            return .keychainLocked
        }
        if result.exitCode == 128
            || stderr.contains("errsecusercanceled")
            || stderr.contains("user canceled")
            || stderr.contains("user cancelled")
        {
            return .userCancelled
        }
        if result.exitCode == 51
            || stderr.contains("errsecauthfailed")
            || stderr.contains("authorization denied")
            || stderr.contains("authentication failed")
            || stderr.contains("passphrase")
        {
            return .authorizationDenied
        }
        return .toolFailed(exitCode: result.exitCode)
    }
}

private extension Data {
    init?<Bytes: Collection>(strictASCIIHex encoded: Bytes)
    where Bytes.Element == UInt8 {
        guard encoded.count.isMultiple(of: 2) else {
            return nil
        }
        let encoded = Array(encoded)
        var decoded = [UInt8]()
        decoded.reserveCapacity(encoded.count / 2)
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = Self.hexNibble(encoded[index]),
                  let low = Self.hexNibble(encoded[index + 1]) else {
                return nil
            }
            decoded.append((high << 4) | low)
        }
        self.init(decoded)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }
}

struct SystemClaudeSecurityToolRunner: ClaudeSecurityToolRunning, @unchecked Sendable {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    func run(
        _ invocation: ClaudeSecurityToolInvocation
    ) throws -> ClaudeSecurityToolResult {
        guard invocation.executablePath == ClaudeSecurityToolCredentialBackend.executablePath else {
            throw SystemClaudeSecurityToolRunnerError.unexpectedExecutable
        }

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ClaudeSecurityToolCredentialBackend.executablePath
        )
        process.arguments = invocation.arguments
        // The command needs no inherited environment. Clearing it prevents an
        // unrelated token from becoming visible in the helper's process
        // metadata and makes execution independent of the launching shell.
        process.environment = [:]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let standardInput: Pipe?
        if invocation.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            standardInput = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            standardInput = nil
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }
        try process.run()

        // Drain both pipes concurrently. Waiting for process exit first can
        // deadlock when an existing credential or diagnostic exceeds a pipe's
        // kernel buffer.
        let output = LockedDataBox()
        let errorOutput = LockedDataBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(standardOutput.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errorOutput.set(standardError.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }

        var inputWriteError: Error?
        if let input = invocation.standardInput, let standardInput {
            do {
                try standardInput.fileHandleForWriting.write(contentsOf: input)
                try standardInput.fileHandleForWriting.close()
            } catch {
                try? standardInput.fileHandleForWriting.close()
                // A helper can reject the command and close stdin before its
                // diagnostic has been drained. Wait for its real exit status
                // so the caller can classify cancellation, authorization, or
                // lock failures without leaking the child process.
                inputWriteError = error
            }
        }

        let timeout = timeout.isFinite && timeout > 0 ? timeout : 120
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if terminated.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            if drainGroup.wait(timeout: .now() + 1) == .timedOut {
                try? standardOutput.fileHandleForReading.close()
                try? standardError.fileHandleForReading.close()
            }
            throw SystemClaudeSecurityToolRunnerError.timedOut
        }
        guard drainGroup.wait(timeout: .now() + 5) == .success else {
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
            throw SystemClaudeSecurityToolRunnerError.timedOut
        }
        let result = ClaudeSecurityToolResult(
            exitCode: process.terminationStatus,
            standardOutput: output.value,
            standardError: errorOutput.value
        )
        if let inputWriteError, result.exitCode == 0 {
            throw inputWriteError
        }
        return result
    }
}

private enum SystemClaudeSecurityToolRunnerError: Error {
    case unexpectedExecutable
    case timedOut
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }
}
