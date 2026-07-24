import Foundation
import XCTest
@testable import LimitLifeboatCore

final class ClaudeSecurityToolCredentialBackendTests: XCTestCase {
    func testReadPinsServiceAccountAndKeychainToHardcodedTool() throws {
        let runner = RecordingClaudeSecurityToolRunner(
            result: ClaudeSecurityToolResult(
                exitCode: 0,
                standardOutput: Data("attribute output is ignored".utf8),
                standardError: Data(
                    (
                        #"password: "{"token":"value"}""#
                            + "\n"
                    ).utf8
                )
            )
        )
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)
        let location = makeLocation()

        let data = try readData(using: backend, at: location)

        XCTAssertEqual(data, Data("{\"token\":\"value\"}".utf8))
        XCTAssertEqual(
            runner.invocations,
            [
                ClaudeSecurityToolInvocation(
                    executablePath: "/usr/bin/security",
                    arguments: [
                        "find-generic-password",
                        "-a", location.accountName,
                        "-s", location.serviceName,
                        "-g",
                        location.keychainPath
                    ],
                    standardInput: nil
                )
            ]
        )
    }

    func testReadDecodesHexFormForArbitraryCredentialBytes() throws {
        let cases: [(Data, String)] = [
            (
                Data(#"{"label":"München","path":"a\\b"}"#.utf8),
                #" "lossy display is ignored""#
            ),
            (
                Data([0x00, 0xff]),
                ""
            )
        ]

        for (expected, display) in cases {
            let encoded = expected.map { String(format: "%02X", $0) }.joined()
            let runner = RecordingClaudeSecurityToolRunner(
                result: ClaudeSecurityToolResult(
                    exitCode: 0,
                    standardError: Data(
                        ("password: 0x\(encoded) \(display)\n").utf8
                    )
                )
            )

            XCTAssertEqual(
                try readData(
                    using: ClaudeSecurityToolCredentialBackend(runner: runner),
                    at: makeLocation()
                ),
                expected
            )
        }
    }

    func testReadDecodesEmptyCredential() throws {
        let runner = RecordingClaudeSecurityToolRunner(
            result: ClaudeSecurityToolResult(
                exitCode: 0,
                standardError: Data("password: \n".utf8)
            )
        )

        XCTAssertEqual(
            try readData(
                using: ClaudeSecurityToolCredentialBackend(runner: runner),
                at: makeLocation()
            ),
            Data()
        )
    }

    func testReadRejectsMalformedToolOutputWithoutReturningIt() {
        let malformed = [
            "not-a-password\n",
            "password: \"value\"",
            "password: 0x0 \n",
            "password: 0xGG \n",
            "password: 0x00\n",
            "warning\npassword: \"value\"\n",
            "password: \"\"\n",
            "password: \"a\\\\b\"\n"
        ]

        for output in malformed {
            let runner = RecordingClaudeSecurityToolRunner(
                result: ClaudeSecurityToolResult(
                    exitCode: 0,
                    standardError: Data(output.utf8)
                )
            )
            XCTAssertThrowsError(
                try readData(
                    using: ClaudeSecurityToolCredentialBackend(runner: runner),
                    at: makeLocation()
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeSecurityToolCredentialError,
                    .malformedToolOutput
                )
                XCTAssertFalse(error.localizedDescription.contains(output))
            }
        }
    }

    func testUpdateUsesOneInteractiveHexCommandWithoutSecretArguments() throws {
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)
        let location = makeLocation(
            service: "Claude \"Code\"-credentials",
            account: #"test\user"#,
            label: #"Claude "Shared" Credential"#
        )
        let secret = Data("distinctive-secret".utf8)
        let verificationCount = LockedCounter()

        try updateData(
            secret,
            using: backend,
            at: location,
            verifyBefore: {
                _ = verificationCount.increment()
                return true
            },
            verifyAfter: {
                _ = verificationCount.increment()
                return true
            }
        )

        XCTAssertEqual(verificationCount.value, 2)
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(invocation.executablePath, "/usr/bin/security")
        XCTAssertEqual(invocation.arguments, ["-i"])
        XCTAssertFalse(invocation.arguments.joined().contains("distinctive-secret"))
        XCTAssertFalse(
            invocation.arguments.joined().contains("64697374696e63746976652d736563726574")
        )
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(invocation.standardInput), as: UTF8.self),
            #"add-generic-password -U -a "test\\user" -s "Claude \"Code\"-credentials" -l "Claude \"Shared\" Credential" -X "64697374696e63746976652d736563726574" "/tmp/test.keychain-db""#
                + "\n"
        )
    }

    func testUpdateRejectsNewlinesAndNULBeforeRunningTool() {
        let cases: [(ClaudeKeychainItemLocation, ClaudeSecurityToolArgumentField)] = [
            (
                makeLocation(account: "test\nuser"),
                .accountName
            ),
            (
                makeLocation(service: "Claude\u{0}Code"),
                .serviceName
            ),
            (
                makeLocation(label: "Claude\nCredential"),
                .label
            ),
            (
                makeLocation(path: "/tmp/test\rkeychain-db"),
                .keychainPath
            )
        ]

        for (location, field) in cases {
            let runner = RecordingClaudeSecurityToolRunner()
            let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

            XCTAssertThrowsError(
                try updateData(Data("secret".utf8), using: backend, at: location)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeSecurityToolCredentialError,
                    .invalidArgument(field: field)
                )
            }
            XCTAssertTrue(runner.invocations.isEmpty)
        }
    }

    func testUsesStdinAt4096AndFallsBackToDirectArgvAt4097() throws {
        var location = makeLocation(service: "s", account: "a", path: "/k")
        var baseCommand = expectedUpdateCommand(data: Data(), location: location)
        var baseByteCount = baseCommand.utf8.count + 1
        if (ClaudeSecurityToolCredentialBackend.interactiveCommandBufferByteLimit
            - baseByteCount).isMultiple(of: 2) == false
        {
            location = makeLocation(
                service: "s",
                account: "a",
                label: "s",
                path: "/kk"
            )
            baseCommand = expectedUpdateCommand(data: Data(), location: location)
            baseByteCount = baseCommand.utf8.count + 1
        }

        let payloadByteCount =
            (ClaudeSecurityToolCredentialBackend.interactiveCommandBufferByteLimit
                - baseByteCount) / 2
        let payload = Data(repeating: 0xab, count: payloadByteCount)
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

        try updateData(payload, using: backend, at: location)

        let input = try XCTUnwrap(runner.invocations.first?.standardInput)
        XCTAssertEqual(
            input.count + 1,
            ClaudeSecurityToolCredentialBackend.interactiveCommandBufferByteLimit
        )

        // One byte over the interactive buffer switches transport to a direct
        // argv invocation rather than failing.
        let oneByteLargerLocation = makeLocation(
            service: location.serviceName,
            account: location.accountName,
            label: location.label,
            path: location.keychainPath + "x"
        )
        try updateData(payload, using: backend, at: oneByteLargerLocation)

        XCTAssertEqual(runner.invocations.count, 2)
        let fallback = try XCTUnwrap(runner.invocations.last)
        XCTAssertNil(fallback.standardInput)
        XCTAssertFalse(fallback.arguments.contains("-i"))
        XCTAssertEqual(
            fallback.arguments,
            expectedDirectArguments(
                data: payload,
                location: oneByteLargerLocation
            )
        )
    }

    func testOversizedUpdateUsesDirectArgvWithUnescapedArguments() throws {
        // Fields carry characters that the interactive path escapes; the argv
        // path must pass them verbatim (security's tokenizer would otherwise
        // unquote the escaped form back to these same raw values).
        let location = makeLocation(
            service: #"Claude "Code"-credentials"#,
            account: #"test\user"#,
            label: #"Claude "Shared" Credential"#,
            path: #"/tmp/back\slash.keychain-db"#
        )
        let payload = Data(repeating: 0xab, count: 3_000) // 6000 hex bytes >> 4096
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)
        let verificationCount = LockedCounter()

        try updateData(
            payload,
            using: backend,
            at: location,
            verifyBefore: {
                _ = verificationCount.increment()
                return true
            },
            verifyAfter: {
                _ = verificationCount.increment()
                return true
            }
        )

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(invocation.standardInput)
        XCTAssertEqual(invocation.arguments[0], "add-generic-password")
        XCTAssertFalse(invocation.arguments.contains("-i"))
        XCTAssertEqual(invocation.arguments[3], #"test\user"#)
        XCTAssertEqual(
            invocation.arguments,
            expectedDirectArguments(data: payload, location: location)
        )
        XCTAssertEqual(verificationCount.value, 2)
    }

    func testOversizedUpdateDescriptionRedactsArgvSecret() throws {
        let location = makeLocation(service: "s", account: "a", path: "/k")
        let secret = Data("distinctive-secret".utf8)
        let payload = secret + Data(repeating: 0xab, count: 3_000)
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

        try updateData(payload, using: backend, at: location)

        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertNil(invocation.standardInput)
        let description = String(describing: invocation)
        XCTAssertTrue(description.contains("<redacted"))
        XCTAssertFalse(description.contains(hex))
        XCTAssertFalse(description.contains("distinctive-secret"))
    }

    func testPayloadBeyondDirectCeilingStillThrowsBeforeRunningTool() {
        let location = makeLocation(service: "s", account: "a", path: "/k")
        let payload = Data(
            repeating: 0xab,
            count: ClaudeSecurityToolCredentialBackend
                .directCommandArgumentByteLimit / 2 + 1
        )
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

        XCTAssertThrowsError(
            try updateData(payload, using: backend, at: location)
        ) { error in
            guard case .payloadTooLarge(_, let maximumByteCount)? =
                error as? ClaudeSecurityToolCredentialError else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(
                maximumByteCount,
                ClaudeSecurityToolCredentialBackend
                    .directCommandArgumentByteLimit
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testUpdateDetectsItemChangeBeforeAndAfterToolCall() {
        let location = makeLocation()

        let beforeRunner = RecordingClaudeSecurityToolRunner()
        let beforeBackend = ClaudeSecurityToolCredentialBackend(runner: beforeRunner)
        let beforeAttempt = ClaudeCredentialWriteAttempt()
        XCTAssertThrowsError(
            try updateData(
                Data("secret".utf8),
                using: beforeBackend,
                at: location,
                verifyBefore: { false },
                mutationAttempt: beforeAttempt
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeSecurityToolCredentialError,
                .itemChanged
            )
        }
        XCTAssertTrue(beforeRunner.invocations.isEmpty)
        XCTAssertFalse(beforeAttempt.helperStarted)
        XCTAssertFalse(beforeAttempt.helperSucceeded)

        let afterRunner = RecordingClaudeSecurityToolRunner()
        let afterBackend = ClaudeSecurityToolCredentialBackend(runner: afterRunner)
        let verificationCount = LockedCounter()
        let afterAttempt = ClaudeCredentialWriteAttempt()
        XCTAssertThrowsError(
            try updateData(
                Data("secret".utf8),
                using: afterBackend,
                at: location,
                verifyBefore: {
                    _ = verificationCount.increment()
                    return true
                },
                verifyAfter: {
                    _ = verificationCount.increment()
                    return false
                },
                mutationAttempt: afterAttempt
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeSecurityToolCredentialError,
                .itemChanged
            )
        }
        XCTAssertEqual(afterRunner.invocations.count, 1)
        XCTAssertEqual(verificationCount.value, 2)
        XCTAssertTrue(afterAttempt.helperStarted)
        XCTAssertTrue(afterAttempt.helperSucceeded)
    }

    func testToolFailuresAreClassifiedWithoutReturningToolOutput() {
        let cases: [(Int32, String, ClaudeSecurityToolCredentialError)] = [
            (
                51,
                "The user name or passphrase you entered is not correct.",
                .authorizationDenied
            ),
            (
                1,
                "The specified keychain is locked.",
                .keychainLocked
            ),
            (
                1,
                "SecKeychainSearchCopyNext: errSecInteractionNotAllowed "
                    + "(Interaction is not allowed with the Security Server.)",
                .keychainLocked
            ),
            (
                44,
                "The specified item could not be found in the keychain.",
                .itemChanged
            ),
            (
                128,
                "User canceled the operation.",
                .userCancelled
            ),
            (
                7,
                "distinctive-secret-from-stderr",
                .toolFailed(exitCode: 7)
            )
        ]

        for (exitCode, stderr, expectedError) in cases {
            let runner = RecordingClaudeSecurityToolRunner(
                result: ClaudeSecurityToolResult(
                    exitCode: exitCode,
                    standardError: Data(stderr.utf8)
                )
            )
            let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

            XCTAssertThrowsError(
                try readData(using: backend, at: makeLocation())
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeSecurityToolCredentialError,
                    expectedError
                )
                XCTAssertFalse(error.localizedDescription.contains(stderr))
            }
        }
    }

    func testRunnerErrorMapsToTypedToolFailure() {
        let runner = RecordingClaudeSecurityToolRunner(error: RunnerError.failed)
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

        XCTAssertThrowsError(
            try readData(using: backend, at: makeLocation())
        ) { error in
            XCTAssertEqual(
                error as? ClaudeSecurityToolCredentialError,
                .toolFailed(exitCode: nil)
            )
        }
    }

    func testInvocationAndResultDescriptionsRedactCredentialBytes() throws {
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)
        let secret = Data("distinctive-secret".utf8)

        try updateData(secret, using: backend, at: makeLocation())

        let invocationDescription = String(
            describing: try XCTUnwrap(runner.invocations.first)
        )
        XCTAssertTrue(invocationDescription.contains("<redacted"))
        XCTAssertFalse(invocationDescription.contains("distinctive-secret"))
        XCTAssertFalse(
            invocationDescription.contains(
                "64697374696e63746976652d736563726574"
            )
        )

        let resultDescription = String(
            describing: ClaudeSecurityToolResult(
                exitCode: 1,
                standardOutput: secret,
                standardError: secret
            )
        )
        XCTAssertTrue(resultDescription.contains("<redacted"))
        XCTAssertFalse(resultDescription.contains("distinctive-secret"))
    }

    func testDeniedNonInteractiveGateNeverRunsTool() {
        let runner = RecordingClaudeSecurityToolRunner()
        let backend = ClaudeSecurityToolCredentialBackend(runner: runner)

        XCTAssertThrowsError(
            try readData(
                using: backend,
                at: makeLocation(),
                authorizeAccess: { mode in
                    XCTAssertEqual(mode, .nonInteractive)
                    throw ClaudeSecurityToolCredentialError.authorizationDenied
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeSecurityToolCredentialError,
                .authorizationDenied
            )
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    private func makeLocation(
        service: String = "Claude Code-credentials",
        account: String = "test-user",
        label: String? = nil,
        path: String = "/tmp/test.keychain-db"
    ) -> ClaudeKeychainItemLocation {
        ClaudeKeychainItemLocation(
            serviceName: service,
            accountName: account,
            keychainPath: path,
            persistentReference: Data("persistent-reference".utf8),
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            label: label
        )
    }

    private func expectedUpdateCommand(
        data: Data,
        location: ClaudeKeychainItemLocation
    ) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U"
            + " -a \"\(location.accountName)\""
            + " -s \"\(location.serviceName)\""
            + " -l \"\(location.label)\""
            + " -X \"\(hex)\""
            + " \"\(location.keychainPath)\"\n"
    }

    private func expectedDirectArguments(
        data: Data,
        location: ClaudeKeychainItemLocation
    ) -> [String] {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return [
            "add-generic-password", "-U",
            "-a", location.accountName,
            "-s", location.serviceName,
            "-l", location.label,
            "-X", hex,
            location.keychainPath
        ]
    }

    private func readData(
        using backend: ClaudeSecurityToolCredentialBackend,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode = .nonInteractive,
        authorizeAccess: @escaping @Sendable (CredentialAccessMode) throws -> Void = { _ in },
        verifyBefore: @escaping @Sendable () throws -> Bool = { true },
        verifyAfter: @escaping @Sendable () throws -> Bool = { true }
    ) throws -> Data {
        try backend.readData(
            at: location,
            accessMode: accessMode,
            authorizeAccess: authorizeAccess,
            verifyBefore: verifyBefore,
            verifyAfter: verifyAfter
        )
    }

    private func updateData(
        _ data: Data,
        using backend: ClaudeSecurityToolCredentialBackend,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode = .nonInteractive,
        authorizeAccess: @escaping @Sendable (CredentialAccessMode) throws -> Void = { _ in },
        verifyBefore: @escaping @Sendable () throws -> Bool = { true },
        verifyAfter: @escaping @Sendable () throws -> Bool = { true },
        mutationAttempt: ClaudeCredentialWriteAttempt? = nil
    ) throws {
        try backend.updateData(
            data,
            at: location,
            accessMode: accessMode,
            authorizeAccess: authorizeAccess,
            verifyBefore: verifyBefore,
            verifyAfter: verifyAfter,
            mutationAttempt: mutationAttempt
        )
    }
}

private final class RecordingClaudeSecurityToolRunner:
    ClaudeSecurityToolRunning,
    @unchecked Sendable
{
    private let result: ClaudeSecurityToolResult
    private let error: Error?
    private(set) var invocations: [ClaudeSecurityToolInvocation] = []

    init(
        result: ClaudeSecurityToolResult = ClaudeSecurityToolResult(exitCode: 0),
        error: Error? = nil
    ) {
        self.result = result
        self.error = error
    }

    func run(
        _ invocation: ClaudeSecurityToolInvocation
    ) throws -> ClaudeSecurityToolResult {
        invocations.append(invocation)
        if let error {
            throw error
        }
        return result
    }
}

private enum RunnerError: Error {
    case failed
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
