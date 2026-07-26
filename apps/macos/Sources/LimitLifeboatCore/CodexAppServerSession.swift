import Foundation

/// One `codex app-server --stdio` exchange in an isolated CODEX_HOME.
///
/// Owns everything the three app-server call sites had been duplicating:
/// process configuration, the JSON-RPC handshake, newline-delimited framing,
/// draining stderr so a noisy subprocess cannot fill its pipe, and the
/// terminate -> SIGKILL teardown that keeps a subprocess ignoring SIGTERM
/// from outliving the app.
///
/// Callers supply the requests that follow `initialized` and consume raw
/// stdout, so each keeps its own response classification and its own copy in
/// user-facing wording.
enum CodexAppServerSession {
    /// How the exchange ended. Completion is not represented here: the
    /// consumer owns that state, so callers read their own accumulator first
    /// and fall back to these only when it came back empty. Callers map them
    /// to their own copy, so the same failure reads correctly whether it
    /// surfaced from a usage check or an account verification.
    enum Outcome {
        /// The process could not be launched at all.
        case launchFailed
        /// The timeout elapsed first.
        case timedOut
        /// The process exited without the consumer signalling completion.
        case endedEarly
    }

    /// The handshake every caller sends before its own requests.
    private static let handshake: [[String: Any]] = [
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
        ["method": "initialized", "params": [:]]
    ]

    /// Runs the exchange on the calling thread.
    ///
    /// - Parameter consume: called with each chunk of stdout as it arrives,
    ///   off the calling thread. Return true once the exchange is complete.
    ///   Implementations must be safe to call concurrently with teardown.
    /// An app-server process pinned to `codexHome`, not yet launched. Exposed
    /// for the reset flow, which drives a multi-turn conversation the
    /// fire-and-forget `run` shape cannot express but which must be
    /// configured identically.
    static func configuredProcess(executableURL: URL, codexHome: URL) -> Process {
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
        return process
    }

    static func run(
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval,
        requests: [[String: Any]],
        consume: @escaping (Data) -> Bool
    ) -> Outcome {
        let process = configuredProcess(executableURL: executableURL, codexHome: codexHome)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let completed = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty || consume(data) {
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
            return .launchFailed
        }

        for message in handshake + requests {
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
            usleep(100_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        return waitResult == .timedOut ? .timedOut : .endedEarly
    }
}
