import Foundation
import Security

/// Result of running the `security` tool: its exit code plus the merged
/// stdout+stderr text, so callers can classify failures (e.g. a wrong
/// password) without relying on the exit code alone.
public struct SecurityToolResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Seam over the two `/usr/bin/security` invocations the partition-list repair
/// needs, so the orchestrator can be unit-tested with an in-memory fake and
/// never touches the real Keychain.
public protocol SecurityToolRunning: Sendable {
    /// `security dump-keychain -a <keychain>`: merged stdout+stderr, NUL-stripped,
    /// exit status ignored. Reads only ACL metadata, so it never prompts.
    func dumpKeychainACL(keychainPath: String) throws -> String

    /// `security set-generic-password-partition-list -S <csv> -s <svc> -a <acct> <keychain>`.
    /// Modifying the partition list requires the login-keychain password; it is
    /// delivered to the tool's prompt so no GUI dialog appears.
    func setPartitionList(
        csv: String,
        service: String,
        account: String,
        keychainPath: String,
        password: String
    ) throws -> SecurityToolResult
}

/// No-password probe of whether the app's partition entry is already present.
public enum KeychainPartitionStatus: Equatable, Sendable {
    case complete
    case missing([String])
    case itemNotFound
    case unparseable
}

/// What a repair would need to do, computed from a single (slow) keychain dump
/// so the caller can prompt for a password only once and never dump twice for
/// the same decision.
public enum KeychainPartitionPlan: Equatable, Sendable {
    case complete(existing: [String])
    case itemNotFound
    case unparseable
    case needsWrite(csv: String, added: [String])
}

public enum KeychainPartitionRepairOutcome: Equatable, Sendable {
    case alreadyComplete(existing: [String])
    case repaired(added: [String], merged: [String])
}

public enum KeychainPartitionRepairError: Error, LocalizedError, Equatable {
    case itemNotFound
    case unparseablePartitionList
    case wrongPassword
    case verificationFailed(stillMissing: [String])
    case securityToolFailed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code is not logged in, so there is no keychain item to repair. "
                + "Run `claude` and sign in with /login first, then try again."
        case .unparseablePartitionList:
            return "The existing keychain partition list could not be read safely, so no changes were made."
        case .wrongPassword:
            return "That login keychain password was not correct."
        case .verificationFailed(let stillMissing):
            return "The keychain partition list was updated but \(stillMissing.joined(separator: ", ")) "
                + "is still missing afterwards."
        case .securityToolFailed(let status, let message):
            let detail = message.isEmpty ? "exit \(status)" : message
            return "Could not update the keychain partition list (\(detail))."
        }
    }
}

/// Repairs the partition list of the shared `Claude Code-credentials` keychain
/// item so the app's Developer ID team is trusted to read it without a password
/// prompt on every access. This only ever modifies the partition list of the
/// existing item via `security set-generic-password-partition-list`; it never
/// creates the item or replaces its ACL, preserving Claude Code's ownership.
///
/// A native port of `scripts/fix-keychain-prompts.sh`.
public struct KeychainPartitionRepair: Sendable {
    private let service: String
    private let account: String
    private let keychainPath: String
    private let requiredPartitions: [String]
    private let runner: SecurityToolRunning

    public init(
        service: String = ClaudeCodeCredentialsKeychain.serviceName,
        account: String = NSUserName(),
        keychainPath: String = KeychainPartitionRepair.defaultLoginKeychainPath(),
        requiredPartitions: [String],
        runner: SecurityToolRunning = SystemSecurityTool()
    ) {
        self.service = service
        self.account = account
        self.keychainPath = keychainPath
        self.requiredPartitions = requiredPartitions
        self.runner = runner
    }

    public static func defaultLoginKeychainPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db")
            .path
    }

    /// Computes what a repair needs with a single keychain dump. Never prompts.
    /// The dump is slow (it enumerates the whole keychain), so callers should
    /// plan once, prompt once, then `apply`.
    public func plan() throws -> KeychainPartitionPlan {
        let parse = Self.parsePartitionList(
            fromDump: try runner.dumpKeychainACL(keychainPath: keychainPath),
            service: service,
            account: account
        )
        switch parse {
        case .itemNotFound:
            return .itemNotFound
        case .unparseable:
            // `-S` replaces the full partition list. If the existing list
            // cannot be parsed, writing only the required entries could remove
            // unknown trusted partitions, so fail closed without prompting.
            return .unparseable
        case .found(let existing):
            let (merged, added) = Self.merge(existing: existing, required: requiredPartitions)
            if added.isEmpty {
                return .complete(existing: existing)
            }
            return .needsWrite(csv: merged.joined(separator: ","), added: added)
        }
    }

    /// Probes the current partition list without ever prompting for a password.
    public func status() throws -> KeychainPartitionStatus {
        switch try plan() {
        case .complete:
            return .complete
        case .itemNotFound:
            return .itemNotFound
        case .unparseable:
            return .unparseable
        case .needsWrite(_, let added):
            return .missing(added)
        }
    }

    /// Applies a `.needsWrite` plan's change and verifies it landed. `password`
    /// authorizes the one partition-list write.
    public func apply(csv: String, added: [String], password: String) throws -> KeychainPartitionRepairOutcome {
        let result = try runner.setPartitionList(
            csv: csv,
            service: service,
            account: account,
            keychainPath: keychainPath,
            password: password
        )
        if result.exitCode != 0 {
            if Self.isAuthFailure(result.output) {
                throw KeychainPartitionRepairError.wrongPassword
            }
            throw KeychainPartitionRepairError.securityToolFailed(
                status: result.exitCode,
                message: Self.condensedMessage(result.output)
            )
        }

        let verifyList: [String]
        if case .found(let list) = Self.parsePartitionList(
            fromDump: try runner.dumpKeychainACL(keychainPath: keychainPath),
            service: service,
            account: account
        ) {
            verifyList = list
        } else {
            verifyList = []
        }
        let stillMissing = added.filter { !verifyList.contains($0) }
        if !stillMissing.isEmpty {
            throw KeychainPartitionRepairError.verificationFailed(stillMissing: stillMissing)
        }
        let merged = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return .repaired(added: added, merged: merged)
    }

    /// Convenience that plans and applies in one call (two dumps). `password` is
    /// used only when a write is actually required.
    public func repair(password: String) throws -> KeychainPartitionRepairOutcome {
        switch try plan() {
        case .itemNotFound:
            throw KeychainPartitionRepairError.itemNotFound
        case .unparseable:
            throw KeychainPartitionRepairError.unparseablePartitionList
        case .complete(let existing):
            return .alreadyComplete(existing: existing)
        case .needsWrite(let csv, let added):
            return try apply(csv: csv, added: added, password: password)
        }
    }

    // MARK: - Pure logic (ported from the script's awk)

    enum PartitionParse: Equatable {
        case found([String])
        case unparseable
        case itemNotFound
    }

    /// Extracts the partition list for the given service+account from
    /// `security dump-keychain -a` output. Within the item's block, the list is
    /// the `description:` line immediately following the
    /// `authorizations (1): partition_id` line (other ACL entries have their own
    /// description lines, so ordering matters).
    static func parsePartitionList(
        fromDump dump: String,
        service: String,
        account: String
    ) -> PartitionParse {
        let svceMarker = "\"svce\"<blob>=\"\(service)\""
        let acctMarker = "\"acct\"<blob>=\"\(account)\""

        var svceOK = false
        var acctOK = false
        var inItem = false
        var sawItem = false
        var grab = false

        for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("keychain: ") {
                inItem = false
                svceOK = false
                acctOK = false
                grab = false
            }
            if line.contains(svceMarker) { svceOK = true }
            if line.contains(acctMarker) { acctOK = true }
            if svceOK && acctOK {
                inItem = true
                sawItem = true
            }
            if inItem && line.contains("authorizations (1): partition_id") {
                grab = true
                continue
            }
            if inItem && grab {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("entry ") {
                    // The partition entry ended without a description. Do not
                    // consume a description from a later ACL entry.
                    grab = false
                    continue
                }
                if trimmed.hasPrefix("description:") {
                    let value = trimmed.dropFirst("description:".count)
                        .trimmingCharacters(in: .whitespaces)
                    let entries = value
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    return .found(entries)
                }
            }
        }
        return sawItem ? .unparseable : .itemNotFound
    }

    /// Keeps every existing entry and appends the required ones that are absent.
    static func merge(existing: [String], required: [String]) -> (merged: [String], added: [String]) {
        var merged = existing
        var added: [String] = []
        for entry in required where !merged.contains(entry) {
            merged.append(entry)
            added.append(entry)
        }
        return (merged, added)
    }

    static func isAuthFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return output.contains("\(errSecAuthFailed)")   // -25293
            || lowered.contains("not correct")
            || lowered.contains("passphrase")
    }

    private static func condensedMessage(_ output: String) -> String {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// Real `SecurityToolRunning` backed by `/usr/bin/security`. The set operation
/// is driven through `/usr/bin/expect` so the login password satisfies the
/// tool's terminal prompt without ever appearing on any process's argv.
public struct SystemSecurityTool: SecurityToolRunning {
    private let securityPath: String
    private let expectPath: String
    private let expectTimeoutSeconds: Int
    /// Env var name the expect script reads the password from, so the secret is
    /// never interpolated into script text or command arguments.
    private static let passwordEnvKey = "LL_KEYCHAIN_PARTITION_PASSWORD"

    public init() {
        self.init(
            securityPath: "/usr/bin/security",
            expectPath: "/usr/bin/expect",
            expectTimeoutSeconds: 20
        )
    }

    init(securityPath: String, expectPath: String, expectTimeoutSeconds: Int) {
        self.securityPath = securityPath
        self.expectPath = expectPath
        self.expectTimeoutSeconds = expectTimeoutSeconds
    }

    public func dumpKeychainACL(keychainPath: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = ["dump-keychain", "-a", keychainPath]
        let (_, out, err) = try Self.run(process)
        // dump-keychain splits output across stdout+stderr and can emit raw NUL
        // bytes; the exit status is unreliable and deliberately ignored.
        let merged = out + err
        let stripped = merged.filter { $0 != 0 }
        return String(decoding: stripped, as: UTF8.self)
    }

    public func setPartitionList(
        csv: String,
        service: String,
        account: String,
        keychainPath: String,
        password: String
    ) throws -> SecurityToolResult {
        let securityArgs = [
            securityPath,
            "set-generic-password-partition-list",
            "-S", csv,
            "-s", service,
            "-a", account,
            keychainPath
        ]

        if FileManager.default.fileExists(atPath: expectPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: expectPath)
            process.arguments = [
                "-c",
                Self.expectScript(
                    securityArgs: securityArgs,
                    timeoutSeconds: expectTimeoutSeconds
                )
            ]
            var environment = ProcessInfo.processInfo.environment
            environment[Self.passwordEnvKey] = password
            process.environment = environment
            let (status, out, err) = try Self.run(process)
            let output = String(decoding: out, as: UTF8.self) + String(decoding: err, as: UTF8.self)
            return SecurityToolResult(exitCode: status, output: output)
        }

        // Fallback when /usr/bin/expect is absent: pass the password via -k.
        // This exposes it on argv to same-user processes for the child's
        // lifetime, so it is only used when the PTY path is unavailable.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = [
            "set-generic-password-partition-list",
            "-S", csv,
            "-s", service,
            "-a", account,
            "-k", password,
            keychainPath
        ]
        let (status, out, err) = try Self.run(process)
        let output = String(decoding: out, as: UTF8.self) + String(decoding: err, as: UTF8.self)
        return SecurityToolResult(exitCode: status, output: output)
    }

    /// Runs a process, draining both pipes concurrently so large output (a full
    /// keychain dump) can never deadlock against a filled pipe buffer.
    private static func run(_ process: Process) throws -> (status: Int32, out: Data, err: Data) {
        final class Box: @unchecked Sendable { var data = Data() }
        let outBox = Box()
        let errBox = Box()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        try process.run()
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, outBox.data, errBox.data)
    }

    private static func expectScript(securityArgs: [String], timeoutSeconds: Int) -> String {
        let commandList = securityArgs.map(tclQuotedString).joined(separator: " ")
        return #"""
        set timeout \#(timeoutSeconds)
        log_user 1
        set command [list \#(commandList)]
        eval spawn -noecho $command
        expect {
            -re {[Pp]assword} { send -- "$env(\#(passwordEnvKey))\r"; exp_continue }
            eof {}
            timeout {
                set child_pid [exp_pid]
                catch {close}
                catch {exec /bin/kill -TERM $child_pid}
                after 200
                catch {exec /bin/kill -KILL $child_pid}
                catch {wait}
                exit 124
            }
        }
        catch wait result
        exit [expr {[lindex $result 3] == 0 ? 0 : 1}]
        """#
    }

    /// Quotes a value as a single Tcl list element. Only non-secret arguments
    /// pass through here; the password is delivered via the environment.
    private static func tclQuotedString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "\"\(escaped)\""
    }
}
