import Darwin
import XCTest
@testable import LimitLifeboatCore

/// The control socket's file permissions, peer check and wire protocol.
final class ControlSocketTests: XCTestCase {
    private var directory: URL!
    private var socketURL: URL!
    private var server: ControlSocketServer?

    override func setUpWithError() throws {
        // Short: a Unix socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/llcs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socketURL = directory.appendingPathComponent(ControlProtocol.socketFileName)
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Records every intent the handler sees, and answers with a canned result.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _intents: [ControlIntent] = []
        private var _peers: [uid_t] = []
        var intents: [ControlIntent] { lock.lock(); defer { lock.unlock() }; return _intents }
        var peers: [uid_t] { lock.lock(); defer { lock.unlock() }; return _peers }
        func record(_ intent: ControlIntent) { lock.lock(); _intents.append(intent); lock.unlock() }
        func record(peer: uid_t) { lock.lock(); _peers.append(peer); lock.unlock() }
    }

    @discardableResult
    private func startServer(
        recorder: Recorder = Recorder(),
        allow: Bool = true,
        respond: (@Sendable (ControlIntent, String?) -> ControlResponse)? = nil
    ) throws -> Recorder {
        let policy = ControlPeer.Policy { uid in
            recorder.record(peer: uid)
            return allow && uid == geteuid()
        }
        let server = ControlSocketServer(socketURL: socketURL, policy: policy) { intent, id in
            recorder.record(intent)
            if let respond { return respond(intent, id) }
            return .success(ControlResult(command: "refresh", accounts: []), id: id)
        }
        try server.start()
        self.server = server
        return recorder
    }

    private func mode(_ path: String) -> (type: mode_t, permissions: mode_t, owner: uid_t) {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0, "lstat \(path)")
        return (info.st_mode & S_IFMT, info.st_mode & 0o777, info.st_uid)
    }

    private func send(_ request: ControlRequest) -> Result<ControlResponse, ControlError> {
        ControlSocketClient.send(request, to: socketURL, timeout: 5)
    }

    /// Sends raw bytes, for requests the typed client cannot produce.
    private func sendRaw(_ bytes: Data) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        ControlSocketFile.disableSIGPIPE(fd)
        let address = try XCTUnwrap(ControlSocketFile.makeAddress(socketURL.path))
        XCTAssertEqual(ControlSocketFile.connect(fd, to: address), 0)
        ControlSocketFile.setTimeouts(fd, seconds: 5)
        _ = ControlSocketFile.writeAll(fd, bytes)
        let line = ControlSocketFile.readLine(fd, limit: ControlProtocol.maxResponseBytes) ?? Data()
        return String(decoding: line, as: UTF8.self)
    }

    // MARK: - Permissions

    func testSocketIs0600AndFolderIsForcedTo0700() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try startServer()

        let folder = mode(directory.path)
        XCTAssertEqual(folder.permissions, 0o700, "folder must be 0700")
        XCTAssertEqual(folder.owner, geteuid())

        let socket = mode(socketURL.path)
        XCTAssertEqual(socket.type, S_IFSOCK)
        XCTAssertEqual(socket.permissions, 0o600, "socket must be 0600")
        XCTAssertEqual(socket.owner, geteuid())
        XCTAssertNil(ControlSocketFile.verify(socketURL.path))
    }

    func testMissingFolderIsCreated0700() throws {
        try startServer()
        XCTAssertEqual(mode(directory.path).permissions, 0o700)
    }

    func testStopRemovesTheSocket() throws {
        try startServer()
        server?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testStaleSocketFromACrashIsReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Bound, never listened, closed: what a crashed app leaves behind.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(ControlSocketFile.makeAddress(socketURL.path))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(stale)

        XCTAssertNoThrow(try startServer())
        XCTAssertEqual(mode(socketURL.path).permissions, 0o600)
    }

    func testNeverDeletesSomethingThatIsNotASocket() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: socketURL)

        XCTAssertThrowsError(try startServer()) { error in
            XCTAssertEqual(error as? ControlSocketFile.Problem, .notASocket)
        }
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "keep me")
    }

    func testSecondServerDoesNotStealALiveSocket() throws {
        try startServer()
        let second = ControlSocketServer(socketURL: socketURL) { _, id in .failure(ControlError.appNotRunning, id: id) }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? ControlSocketFile.Problem, .alreadyListening)
        }
        // The first one still answers.
        XCTAssertNoThrow(try send(ControlRequest(command: "refresh")).get())
    }

    func testTooLongAPathIsRefused() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + "/control.sock")
        let server = ControlSocketServer(socketURL: long) { _, id in .failure(ControlError.appNotRunning, id: id) }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? ControlSocketFile.Problem, .pathTooLong)
        }
    }

    // MARK: - Peer check

    func testPeerCheckSeesTheConnectingUser() throws {
        let recorder = try startServer()
        _ = try send(ControlRequest(command: "refresh")).get()
        XCTAssertEqual(recorder.peers, [geteuid()], "getpeereid must report the client's euid")
    }

    func testRejectedPeerIsDroppedBeforeAnyRequestIsRead() throws {
        // Tests cannot connect as another user, so the policy stands in for
        // "this uid is not the app's": it must close without answering.
        let recorder = try startServer(allow: false)
        let result = send(ControlRequest(command: "switch", accountId: UUID().uuidString))

        guard case .failure(let error) = result else { return XCTFail("a rejected peer got an answer: \(result)") }
        XCTAssertEqual(error.code, "protocol_error")
        XCTAssertEqual(recorder.intents, [], "the handler must never run for a rejected peer")
        XCTAssertEqual(recorder.peers.count, 1)
    }

    func testSameUserPolicyAcceptsOnlyTheEffectiveUID() {
        XCTAssertTrue(ControlPeer.Policy.sameUser.allows(geteuid()))
        XCTAssertFalse(ControlPeer.Policy.sameUser.allows(geteuid() &+ 1))
    }

    // MARK: - Client checks

    func testClientReportsAppNotRunningWithoutASocket() {
        let result = send(ControlRequest(command: "refresh"))
        XCTAssertEqual(result.failureCode, "app_not_running")
        XCTAssertEqual(result.failure?.message.contains("Open Lifeboat"), true)
        XCTAssertFalse(ControlSocketClient.isListening(at: socketURL))
    }

    func testClientReportsAppNotRunningForAStaleSocket() throws {
        try startServer()
        // Simulate a crash: the file stays, nobody listens.
        let path = socketURL.path
        server?.stop()
        server = nil
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(ControlSocketFile.makeAddress(path))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        chmod(path, 0o600)

        XCTAssertEqual(send(ControlRequest(command: "refresh")).failureCode, "app_not_running")
    }

    func testClientRefusesASocketOthersCouldUse() throws {
        try startServer()
        chmod(socketURL.path, 0o666)
        XCTAssertEqual(send(ControlRequest(command: "refresh")).failureCode, "insecure_socket")
    }

    func testClientRefusesSomethingThatIsNotASocket() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: socketURL)
        XCTAssertEqual(send(ControlRequest(command: "refresh")).failureCode, "insecure_socket")
    }

    // MARK: - Protocol

    func testRefreshRoundTripEchoesTheRequestID() throws {
        let account = UUID()
        let recorder = try startServer { intent, id in
            .success(ControlResult(command: "refresh", accounts: [
                ControlAccountOutcome(id: account.uuidString, provider: "claude", label: "Work", isActive: true,
                                      lastRefreshed: nil, ageSeconds: nil, issues: [])
            ]), id: id)
        }

        let response = try send(ControlRequest(id: "abc", command: "refresh", accountId: account.uuidString)).get()

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.v, ControlProtocol.version)
        XCTAssertEqual(response.id, "abc")
        XCTAssertEqual(response.result?.accounts.first?.id, account.uuidString)
        XCTAssertEqual(recorder.intents, [.refresh(accountID: account)])
    }

    func testRefreshWithoutAnAccountRefreshesAll() throws {
        let recorder = try startServer()
        _ = try send(ControlRequest(command: "refresh")).get()
        XCTAssertEqual(recorder.intents, [.refresh(accountID: nil)])
    }

    func testSwitchCarriesItsTarget() throws {
        let account = UUID()
        let recorder = try startServer()
        _ = try send(ControlRequest(command: "switch", accountId: account.uuidString)).get()
        XCTAssertEqual(recorder.intents, [.switchTo(accountID: account)])
    }

    func testHandlerErrorsArriveTyped() throws {
        try startServer { _, id in .failure(ControlError(code: "switch_failed", message: "nope"), id: id) }
        let response = try send(ControlRequest(command: "switch", accountId: UUID().uuidString)).get()
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, ControlError(code: "switch_failed", message: "nope"))
        XCTAssertNil(response.result)
    }

    func testInvalidRequestsAreRejectedBeforeTheHandler() throws {
        let recorder = try startServer()
        let cases: [(ControlRequest, String)] = [
            (ControlRequest(command: "switch"), "bad_request"),
            (ControlRequest(command: "switch", accountId: "not-a-uuid"), "bad_request"),
            (ControlRequest(command: "capture"), "unknown_command"),
            (ControlRequest(command: "remove", accountId: UUID().uuidString), "unknown_command"),
            (ControlRequest(command: "rename", accountId: UUID().uuidString), "unknown_command"),
            (ControlRequest(v: 99, command: "refresh"), "unsupported_version"),
        ]
        for (request, code) in cases {
            let response = try send(request).get()
            XCTAssertFalse(response.ok, "\(request)")
            XCTAssertEqual(response.error?.code, code, "\(request)")
        }
        XCTAssertEqual(recorder.intents, [])
    }

    func testMalformedAndOversizedRequestsAreBadRequests() throws {
        let recorder = try startServer()
        XCTAssertTrue(try sendRaw(Data("not json\n".utf8)).contains(#""code":"bad_request""#))
        var huge = Data(#"{"v":1,"command":"refresh","id":""#.utf8)
        huge.append(Data(repeating: UInt8(ascii: "a"), count: ControlProtocol.maxRequestBytes + 10))
        huge.append(Data("\"}\n".utf8))
        XCTAssertTrue(try sendRaw(huge).contains(#""code":"bad_request""#))
        XCTAssertEqual(recorder.intents, [])
    }

    func testResponseIsOneJSONLine() throws {
        try startServer()
        let line = try sendRaw(Data(#"{"v":1,"command":"refresh","id":"x"}"#.utf8 + [UInt8(ascii: "\n")]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["id"] as? String, "x")
        XCTAssertEqual(object["v"] as? Int, 1)
    }

    func testValidateMapsCommands() {
        let id = UUID()
        XCTAssertEqual(try ControlIntent.validate(ControlRequest(command: "refresh")).get(), .refresh(accountID: nil))
        XCTAssertEqual(try ControlIntent.validate(ControlRequest(command: "refresh", accountId: id.uuidString)).get(), .refresh(accountID: id))
        XCTAssertEqual(try ControlIntent.validate(ControlRequest(command: "switch", accountId: id.uuidString)).get(), .switchTo(accountID: id))
        XCTAssertEqual(Set(ControlCommand.allCases.map(\.rawValue)), ["refresh", "switch"], "capture, rename and remove stay app-only")
    }
}

private extension Result where Failure == ControlError {
    var failure: ControlError? {
        if case .failure(let error) = self { return error }
        return nil
    }

    var failureCode: String? { failure?.code }
}
