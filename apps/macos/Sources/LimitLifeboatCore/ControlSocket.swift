import Darwin
import Foundation

// The app control socket: how `limit-lifeboat refresh` and `switch` ask the
// running app to act.
//
// Security model (see SECURITY.md and docs/cli.md):
// - A Unix domain socket, `control.sock`, in the app's Application Support
//   folder. The folder is forced to 0700 and the socket to 0600, both owned
//   by the user, so no other account can reach it through the filesystem.
// - Every connection's peer is checked with getpeereid() (LOCAL_PEERCRED)
//   and dropped unless its effective uid is the app's own. The client checks
//   the server the same way, plus the socket's owner and mode, before it
//   sends anything.
// - The socket only carries intents: `refresh [accountId]` and
//   `switch <accountId>`. No credential, token or file path ever crosses it.
//   The app runs both through its existing refresh and switch workflows,
//   with their gating, preflight and rollback; there is no new credential
//   write path. Capture, rename and remove are not offered.
// - Bounded: one request per connection, at most 16 KiB, read within 5 s, and
//   a few connections at a time.
//
// Wire format: one UTF-8 JSON object per line, newline-terminated, in each
// direction, then the server closes the connection.

// MARK: - Protocol

public enum ControlProtocol {
    public static let version = 1
    public static let socketFileName = "control.sock"
    public static let maxRequestBytes = 16 * 1024
    public static let maxResponseBytes = 1024 * 1024
    /// sockaddr_un.sun_path is 104 bytes on Darwin, including the NUL.
    public static let maxPathBytes = 103
}

public enum ControlCommand: String, Codable, CaseIterable, Sendable {
    case refresh
    case `switch`
}

public struct ControlRequest: Codable, Equatable, Sendable {
    /// Protocol version; must be `ControlProtocol.version`.
    public var v: Int
    /// Optional, echoed back in the response.
    public var id: String?
    /// `refresh` or `switch`. A string so an unknown command gets a typed
    /// `unknown_command` error rather than a decode failure.
    public var command: String
    /// `refresh`: optional, refresh only this account. `switch`: required.
    public var accountId: String?

    public init(v: Int = ControlProtocol.version, id: String? = nil, command: String, accountId: String? = nil) {
        self.v = v
        self.id = id
        self.command = command
        self.accountId = accountId
    }
}

public struct ControlError: Codable, Equatable, Error, Sendable {
    /// Stable, snake_case. Server-side: `bad_request`, `unsupported_version`,
    /// `unknown_command`, `account_not_found`, `busy`, `refresh_failed`,
    /// `switch_failed`, `needs_login`, `authorization_required`, `deferred`.
    /// Client-side: `app_not_running`, `insecure_socket`, `timeout`,
    /// `protocol_error`.
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static let appNotRunning = ControlError(
        code: "app_not_running",
        message: "Limit Lifeboat isn't running. Open Lifeboat, then try again."
    )
}

/// One account after the command, as the app sees it.
public struct ControlAccountOutcome: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var label: String
    public var isActive: Bool
    /// When the account's reading was last refreshed, if ever.
    public var lastRefreshed: Date?
    public var ageSeconds: Int?
    /// The account's current problems (`AccountIssue.Source.app`); empty
    /// when the refresh succeeded.
    public var issues: [AccountIssue]

    public init(
        id: String, provider: String, label: String, isActive: Bool,
        lastRefreshed: Date?, ageSeconds: Int?, issues: [AccountIssue]
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.isActive = isActive
        self.lastRefreshed = lastRefreshed
        self.ageSeconds = ageSeconds
        self.issues = issues
    }
}

public struct ControlResult: Codable, Equatable, Sendable {
    public var command: String
    /// `refresh`: every account refreshed (one with an id, all otherwise).
    /// `switch`: the account now active.
    public var accounts: [ControlAccountOutcome]
    /// `switch` only: the previously active account of that provider.
    public var previousAccountId: String?
    /// `switch` only: the target was already active; nothing changed.
    public var alreadyActive: Bool?
    /// `refresh` only: a full refresh was already running, so this request
    /// joined its result rather than starting another.
    public var coalesced: Bool?

    public init(
        command: String, accounts: [ControlAccountOutcome], previousAccountId: String? = nil,
        alreadyActive: Bool? = nil, coalesced: Bool? = nil
    ) {
        self.command = command
        self.accounts = accounts
        self.previousAccountId = previousAccountId
        self.alreadyActive = alreadyActive
        self.coalesced = coalesced
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String?
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlError?

    public static func success(_ result: ControlResult, id: String?) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: true, result: result, error: nil)
    }

    public static func failure(_ error: ControlError, id: String?) -> ControlResponse {
        ControlResponse(v: ControlProtocol.version, id: id, ok: false, result: nil, error: error)
    }
}

/// A request that passed validation.
public enum ControlIntent: Equatable, Sendable {
    case refresh(accountID: UUID?)
    case switchTo(accountID: UUID)

    public static func validate(_ request: ControlRequest) -> Result<ControlIntent, ControlError> {
        guard request.v == ControlProtocol.version else {
            return .failure(ControlError(code: "unsupported_version", message: "This app speaks control protocol \(ControlProtocol.version)."))
        }
        guard let command = ControlCommand(rawValue: request.command) else {
            return .failure(ControlError(code: "unknown_command", message: "Unknown command. Use refresh or switch."))
        }
        let accountID: UUID?
        if let raw = request.accountId {
            guard let parsed = UUID(uuidString: raw) else {
                return .failure(ControlError(code: "bad_request", message: "accountId must be an account id from `limit-lifeboat list --json`."))
            }
            accountID = parsed
        } else {
            accountID = nil
        }
        switch command {
        case .refresh:
            return .success(.refresh(accountID: accountID))
        case .switch:
            guard let accountID else {
                return .failure(ControlError(code: "bad_request", message: "switch needs an account id."))
            }
            return .success(.switchTo(accountID: accountID))
        }
    }
}

enum ControlCoding {
    static func encodeLine<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = (try? encoder.encode(value)) ?? Data(#"{"ok":false,"v":1}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - Peer credentials

public enum ControlPeer {
    /// The effective uid of the process on the other end of a connected Unix
    /// socket, from the kernel (getpeereid is LOCAL_PEERCRED on Darwin).
    public static func effectiveUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    /// Who may connect: only the same user. Injectable for tests, which
    /// cannot connect as another user.
    public struct Policy: Sendable {
        public let allows: @Sendable (uid_t) -> Bool

        public init(allows: @escaping @Sendable (uid_t) -> Bool) {
            self.allows = allows
        }

        public static let sameUser = Policy { $0 == geteuid() }
    }
}

// MARK: - Socket file checks

public enum ControlSocketFile {
    public enum Problem: Error, Equatable, CustomStringConvertible {
        case pathTooLong
        case directoryNotOwned
        case notASocket
        case notOwned
        case insecureMode(mode_t)
        case alreadyListening
        case system(String, Int32)

        public var description: String {
            switch self {
            case .pathTooLong: return "The control socket path is too long."
            case .directoryNotOwned: return "The Application Support folder is not owned by this user."
            case .notASocket: return "Something other than a socket is in the control socket's place."
            case .notOwned: return "The control socket is not owned by this user."
            case .insecureMode(let mode): return "The control socket is mode \(String(mode & 0o7777, radix: 8)), not 600."
            case .alreadyListening: return "Another Limit Lifeboat is already listening on the control socket."
            case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))."
            }
        }
    }

    /// The socket must be a socket, ours, and 0600 — checked with lstat, so a
    /// symlink is never followed.
    public static func verify(_ path: String) -> Problem? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .system("lstat", errno) }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { return .notASocket }
        guard info.st_uid == geteuid() else { return .notOwned }
        guard (info.st_mode & 0o777) == 0o600 else { return .insecureMode(info.st_mode) }
        return nil
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count <= ControlProtocol.maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// A write to a peer that hung up must fail with EPIPE, not kill the
    /// process with SIGPIPE. Set it before anything else: on Darwin,
    /// setsockopt fails once the peer has shut the connection down.
    @discardableResult
    static func disableSIGPIPE(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Reads up to the first newline, EOF, `limit` bytes, or `timeout`.
    ///
    /// The timeout is a deadline for the whole line, not per read():
    /// SO_RCVTIMEO alone restarts on every byte, so a peer trickling one byte
    /// every few seconds could hold a connection (and one of the server's few
    /// slots) for hours. On expiry errno is EAGAIN.
    static func readLine(_ fd: Int32, limit: Int, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        errno = 0
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                errno = EAGAIN
                break
            }
            // Never 0: a zero SO_RCVTIMEO means "wait forever".
            setTimeouts(fd, seconds: max(remaining, 0.001))
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                let line = data[data.startIndex..<newline]
                return line.count <= limit ? line : nil
            }
        }
        return data.count > limit || data.isEmpty ? nil : data
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

// MARK: - Server

/// Listens on `control.sock` and hands validated requests to the app.
public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlIntent, _ requestID: String?) async -> ControlResponse

    public static let readTimeout: TimeInterval = 5
    public static let maxConcurrentConnections = 4

    public let socketURL: URL
    private let handler: Handler
    private let policy: ControlPeer.Policy
    private let queue = DispatchQueue(label: "com.limitlifeboat.control-socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var activeConnections = 0
    private var stopped = false

    /// The whole request must arrive within this; tests shorten it.
    private let readTimeout: TimeInterval

    public init(
        socketURL: URL,
        policy: ControlPeer.Policy = .sameUser,
        readTimeout: TimeInterval = ControlSocketServer.readTimeout,
        handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.readTimeout = readTimeout
        self.policy = policy
        self.handler = handler
    }

    deinit { stop() }

    /// Prepares the folder (0700, ours), replaces a stale socket, binds at
    /// 0600, verifies the result, and starts accepting. Fails closed: any
    /// check that does not pass leaves no socket behind.
    public func start() throws {
        let path = socketURL.path
        guard let address = ControlSocketFile.makeAddress(path) else {
            throw ControlSocketFile.Problem.pathTooLong
        }
        try Self.prepareDirectory(socketURL.deletingLastPathComponent())
        try Self.removeStaleSocket(at: path, address: address)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketFile.Problem.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        ControlSocketFile.disableSIGPIPE(fd)

        // The folder is already 0700, so nobody else can reach the socket
        // even in the instant before chmod. The umask makes bind create it
        // 0600 in the first place; chmod and verify make sure.
        let previousMask = umask(0o177)
        var bindAddress = address
        let bound = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno
        umask(previousMask)
        guard bound == 0 else {
            close(fd)
            throw ControlSocketFile.Problem.system("bind", bindErrno)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ControlSocketFile.Problem.system("chmod", code)
        }
        if let problem = ControlSocketFile.verify(path) {
            close(fd)
            unlink(path)
            throw problem
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ControlSocketFile.Problem.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    /// Stops accepting and removes the socket file, if it is still ours.
    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped, let source else { return }
        source.cancel()
        self.source = nil
        if ControlSocketFile.verify(socketURL.path) == nil {
            unlink(socketURL.path)
        }
    }

    static func prepareDirectory(_ directory: URL) throws {
        let path = directory.path
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw ControlSocketFile.Problem.system("mkdir", errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ControlSocketFile.Problem.system("lstat", errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw ControlSocketFile.Problem.directoryNotOwned
        }
        if (info.st_mode & 0o777) != 0o700, chmod(path, 0o700) != 0 {
            throw ControlSocketFile.Problem.system("chmod", errno)
        }
    }

    /// A socket left by a crash is removed. One that still answers belongs to
    /// a running instance and is left alone. Anything that is not our socket
    /// is never deleted.
    static func removeStaleSocket(at path: String, address: sockaddr_un) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw ControlSocketFile.Problem.notASocket }
        guard info.st_uid == geteuid() else { throw ControlSocketFile.Problem.notOwned }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            ControlSocketFile.disableSIGPIPE(probe)
            defer { close(probe) }
            if ControlSocketFile.connect(probe, to: address) == 0 {
                throw ControlSocketFile.Problem.alreadyListening
            }
        }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Gone already (say, the stale-socket probe of a second launch).
            guard ControlSocketFile.disableSIGPIPE(client) else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)

            // The peer check comes before reading a single byte.
            guard let uid = ControlPeer.effectiveUID(of: client), policy.allows(uid) else {
                close(client)
                continue
            }
            lock.lock()
            let admitted = activeConnections < Self.maxConcurrentConnections
            if admitted { activeConnections += 1 }
            lock.unlock()
            guard admitted else {
                ControlSocketFile.setTimeouts(client, seconds: 1)
                _ = ControlSocketFile.writeAll(client, ControlCoding.encodeLine(ControlResponse.failure(
                    ControlError(code: "busy", message: "Limit Lifeboat is handling other requests. Try again shortly."), id: nil
                )))
                close(client)
                continue
            }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        let handler = self.handler
        let readTimeout = self.readTimeout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed = Self.parse(ControlSocketFile.readLine(
                client, limit: ControlProtocol.maxRequestBytes, timeout: readTimeout
            ))

            let finish: (ControlResponse) -> Void = { response in
                // A long refresh may outlive the read timeout; give the write
                // its own short budget.
                ControlSocketFile.setTimeouts(client, seconds: 5)
                _ = ControlSocketFile.writeAll(client, ControlCoding.encodeLine(response))
                close(client)
                guard let self else { return }
                self.lock.lock()
                self.activeConnections -= 1
                self.lock.unlock()
            }
            switch parsed {
            case .failure(let rejection):
                finish(rejection)
            case .success(let request):
                Task { finish(await handler(request.intent, request.id)) }
            }
        }
    }

    /// Bytes on the wire to a validated intent, or the error response.
    static func parse(_ line: Data?) -> Result<(intent: ControlIntent, id: String?), ControlResponse> {
        guard let line else {
            return .failure(.failure(ControlError(code: "bad_request", message: "Send one JSON request line of at most 16 KiB."), id: nil))
        }
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            return .failure(.failure(ControlError(code: "bad_request", message: "The request is not valid JSON for this protocol."), id: nil))
        }
        switch ControlIntent.validate(request) {
        case .success(let intent): return .success((intent, request.id))
        case .failure(let error): return .failure(.failure(error, id: request.id))
        }
    }
}

extension ControlResponse: Error {}

// MARK: - Client

public enum ControlSocketClient {
    /// Default socket location for an app's Application Support folder name.
    public static func socketURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(ControlProtocol.socketFileName)
    }

    /// Sends one request and waits up to `timeout` for the response.
    public static func send(_ request: ControlRequest, to socketURL: URL, timeout: TimeInterval) -> Result<ControlResponse, ControlError> {
        switch connect(socketURL) {
        case .failure(let error):
            return .failure(error)
        case .success(let fd):
            defer { close(fd) }
            ControlSocketFile.setTimeouts(fd, seconds: timeout)
            guard ControlSocketFile.writeAll(fd, ControlCoding.encodeLine(request)) else {
                return .failure(ControlError(code: "protocol_error", message: "Could not send the request to Limit Lifeboat."))
            }
            guard let line = ControlSocketFile.readLine(fd, limit: ControlProtocol.maxResponseBytes, timeout: timeout) else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .failure(ControlError(code: "timeout", message: "Limit Lifeboat did not answer within \(Int(timeout)) seconds. It may still finish; check `limit-lifeboat status`."))
                }
                return .failure(ControlError(code: "protocol_error", message: "Limit Lifeboat closed the connection without answering."))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let response = try? decoder.decode(ControlResponse.self, from: line) else {
                return .failure(ControlError(code: "protocol_error", message: "Limit Lifeboat sent a response this CLI does not understand."))
            }
            return .success(response)
        }
    }

    /// Whether the app is listening: connects, checks the peer, and hangs up
    /// without sending a request.
    public static func isListening(at socketURL: URL) -> Bool {
        guard case .success(let fd) = connect(socketURL) else { return false }
        close(fd)
        return true
    }

    private static func connect(_ socketURL: URL) -> Result<Int32, ControlError> {
        let path = socketURL.path
        guard let address = ControlSocketFile.makeAddress(path) else {
            return .failure(ControlError(code: "protocol_error", message: "The control socket path is too long."))
        }
        var info = stat()
        if lstat(path, &info) != 0 {
            return .failure(.appNotRunning)
        }
        // Refuse a socket someone else could have planted or could read.
        if let problem = ControlSocketFile.verify(path) {
            return .failure(ControlError(code: "insecure_socket", message: "Refusing to use the control socket: \(problem)"))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(ControlError(code: "protocol_error", message: "Could not create a socket."))
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        ControlSocketFile.disableSIGPIPE(fd)
        guard ControlSocketFile.connect(fd, to: address) == 0 else {
            close(fd)
            // A socket file with nobody behind it: the app quit or crashed.
            return .failure(.appNotRunning)
        }
        guard let uid = ControlPeer.effectiveUID(of: fd), uid == geteuid() else {
            close(fd)
            return .failure(ControlError(code: "insecure_socket", message: "The control socket is served by another user."))
        }
        return .success(fd)
    }
}
