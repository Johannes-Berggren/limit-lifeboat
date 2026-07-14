import Darwin
import Dispatch
import Foundation

public enum RunningExecutableIntegrityError: Error, LocalizedError, Equatable {
    case unavailable(path: String)
    case replaced(path: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "The running app executable no longer exists at \(path). Quit and relaunch Limit Lifeboat before accessing credentials."
        case .replaced(let path):
            return "The running app executable was replaced at \(path). Quit and relaunch Limit Lifeboat before accessing credentials."
        }
    }
}

/// Captures the on-disk identity of the running executable. Keychain ACL
/// evaluation needs that exact code to remain available while the process is
/// alive; deleting or replacing a development bundle makes authorization fail
/// even though the old process can continue executing from its open image.
public struct RunningExecutableIntegrityGuard: Sendable {
    public let executableURL: URL

    private let device: UInt64
    private let inode: UInt64

    public init(executableURL: URL) throws {
        let identity = try Self.identity(at: executableURL)
        self.executableURL = executableURL
        self.device = identity.device
        self.inode = identity.inode
    }

    public func validate() throws {
        let current: (device: UInt64, inode: UInt64)
        do {
            current = try Self.identity(at: executableURL)
        } catch {
            throw RunningExecutableIntegrityError.unavailable(path: executableURL.path)
        }

        guard current.device == device, current.inode == inode else {
            throw RunningExecutableIntegrityError.replaced(path: executableURL.path)
        }
    }

    private static func identity(at url: URL) throws -> (device: UInt64, inode: UInt64) {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw RunningExecutableIntegrityError.unavailable(path: url.path)
        }
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw RunningExecutableIntegrityError.unavailable(path: url.path)
        }
        return (device, inode)
    }
}

/// Delivers at most one callback when the executable inode is deleted,
/// renamed, or revoked. Credential stores still perform their own synchronous
/// integrity preflight so a filesystem-event delivery race cannot reach
/// Keychain.
public final class RunningExecutableMonitor: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let onInvalidation: () -> Void
    private var hasInvalidated = false

    public init(
        executableURL: URL,
        queue: DispatchQueue = .main,
        onInvalidation: @escaping () -> Void
    ) throws {
        let descriptor = open(executableURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw RunningExecutableIntegrityError.unavailable(path: executableURL.path)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke],
            queue: queue
        )
        self.source = source
        self.onInvalidation = onInvalidation

        source.setEventHandler { [weak self] in
            guard let self, !self.hasInvalidated else {
                return
            }
            self.hasInvalidated = true
            self.source.cancel()
            self.onInvalidation()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
