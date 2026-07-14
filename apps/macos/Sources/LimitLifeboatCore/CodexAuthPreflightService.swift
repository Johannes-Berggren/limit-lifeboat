import Foundation

public enum CodexAuthPreflightResult: Equatable, Sendable {
    /// The app-server accepted the saved login and wrote a fresh auth document.
    case ready(updatedAuthJSON: Data)
    /// Codex confirmed that the saved login cannot be refreshed.
    case requiresLogin(reason: String)
    /// Verification could not finish, but the credentials were not rejected.
    case temporarilyUnavailable(reason: String)
}

enum CodexAppServerRefreshOutcome: Equatable, Sendable {
    case success(accountEmail: String?)
    case requiresLogin(reason: String)
    case unavailable(reason: String)
}

protocol CodexAppServerRunning {
    func forceRefresh(
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) async -> CodexAppServerRefreshOutcome
}

/// Validates a copied Codex login in an isolated CODEX_HOME. Codex owns the
/// refresh protocol and token rotation; this app only persists the resulting
/// auth.json after identity and concurrency checks succeed.
public struct CodexAuthPreflightService {
    private let runner: any CodexAppServerRunning
    private let fileManager: FileManager
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.runner = CodexAppServerProcessRunner()
        self.fileManager = .default
        self.timeout = timeout
    }

    init(
        runner: any CodexAppServerRunning,
        fileManager: FileManager = .default,
        timeout: TimeInterval = 20
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.timeout = timeout
    }

    public func preflight(
        authJSON: Data,
        executableURL: URL,
        expectedIdentity: AccountIdentity?
    ) async -> CodexAuthPreflightResult {
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("limit-lifeboat-codex-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .temporarilyUnavailable(reason: "Could not prepare an isolated Codex credential check.")
        }
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let authURL = temporaryHome.appendingPathComponent("auth.json")
        do {
            try authJSON.write(to: authURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        } catch {
            return .temporarilyUnavailable(reason: "Could not prepare the saved Codex login for verification.")
        }

        let returnedAccountEmail: String?
        switch await runner.forceRefresh(
            executableURL: executableURL,
            codexHome: temporaryHome,
            timeout: timeout
        ) {
        case .requiresLogin(let reason):
            return .requiresLogin(reason: reason)
        case .unavailable(let reason):
            return .temporarilyUnavailable(reason: reason)
        case .success(let accountEmail):
            returnedAccountEmail = accountEmail
        }

        let updated: Data
        do {
            updated = try Data(contentsOf: authURL)
        } catch {
            return .temporarilyUnavailable(reason: "Codex refreshed the account but did not return readable credentials.")
        }
        guard Self.hasSubscriptionTokens(updated) else {
            return .requiresLogin(reason: "The saved Codex account no longer contains a ChatGPT login.")
        }

        let refreshedIdentity = CodexIdentityReader.accountInfo(fromAuthJSON: updated)?.identity
        if let returnedAccountEmail {
            guard refreshedIdentity?.email?.caseInsensitiveCompare(returnedAccountEmail) == .orderedSame else {
                return .temporarilyUnavailable(
                    reason: "Codex returned an account identity that did not match its refreshed credentials, so nothing was changed."
                )
            }
        }

        if let expectedIdentity {
            guard let refreshedIdentity,
                  expectedIdentity.matches(refreshedIdentity) else {
                return .temporarilyUnavailable(
                    reason: "Codex refreshed a different account than the selected profile, so nothing was changed."
                )
            }
        }
        return .ready(updatedAuthJSON: updated)
    }

    private static func hasSubscriptionTokens(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String else {
            return false
        }
        return !accessToken.isEmpty && !refreshToken.isEmpty
    }
}

final class CodexAppServerResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var storedOutcome: CodexAppServerRefreshOutcome?

    var outcome: CodexAppServerRefreshOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcome
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else {
                continue
            }
            if id == 1, object["error"] != nil {
                storedOutcome = .unavailable(reason: "This Codex version could not initialize account verification.")
                return true
            }
            guard id == 2 else { continue }
            storedOutcome = Self.classify(object)
            return true
        }
        return false
    }

    private static func classify(_ response: [String: Any]) -> CodexAppServerRefreshOutcome {
        if let result = response["result"] as? [String: Any] {
            if let account = result["account"] as? [String: Any] {
                guard account["type"] as? String == "chatgpt" else {
                    return .unavailable(reason: "Codex returned a different authentication type for this account.")
                }
                return .success(accountEmail: account["email"] as? String)
            }
            if result["requiresOpenaiAuth"] as? Bool == true {
                return .requiresLogin(reason: "Codex could not find a usable ChatGPT login for this account.")
            }
        }

        guard let error = response["error"] else {
            return .unavailable(reason: "Codex returned an unexpected account-verification response.")
        }
        let errorData = try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys])
        let normalized = errorData.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
        let authenticationMarkers = [
            "invalid_grant",
            "token_invalidated",
            "refresh token was already used",
            "refresh token has already been used",
            "invalid refresh token",
            "refresh token is invalid",
            "refresh token has expired",
            "refresh token expired",
            "token expired",
            "token revoked",
            "sign in again",
            "login again",
            "unauthorized",
            "401"
        ]
        if authenticationMarkers.contains(where: normalized.contains) {
            return .requiresLogin(reason: "Codex could not refresh this account. Sign in again to continue using it.")
        }
        return .unavailable(reason: "Codex could not verify this account right now.")
    }
}

struct CodexAppServerProcessRunner: CodexAppServerRunning {
    func forceRefresh(
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) async -> CodexAppServerRefreshOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runSynchronously(
                        executableURL: executableURL,
                        codexHome: codexHome,
                        timeout: timeout
                    )
                )
            }
        }
    }

    private func runSynchronously(
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) -> CodexAppServerRefreshOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--stdio",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "analytics.enabled=false",
            "-c", "check_for_update_on_startup=false"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["RUST_LOG"] = "error"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let accumulator = CodexAppServerResponseAccumulator()
        let completed = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty || accumulator.append(data) {
                completed.signal()
            }
        }
        // Drain diagnostics so a noisy subprocess cannot fill its stderr pipe.
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return .unavailable(reason: "Could not start Codex account verification.")
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "limit_lifeboat",
                        "title": "Limit Lifeboat",
                        "version": "1"
                    ],
                    "capabilities": [:]
                ]
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/read", "id": 2, "params": ["refreshToken": true]]
        ]
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { continue }
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0a]))
        }

        let waitResult = completed.wait(timeout: .now() + timeout)
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        if let outcome = accumulator.outcome {
            return outcome
        }
        if waitResult == .timedOut {
            return .unavailable(reason: "Codex account verification timed out.")
        }
        return .unavailable(reason: "Codex account verification ended before returning a result.")
    }
}
