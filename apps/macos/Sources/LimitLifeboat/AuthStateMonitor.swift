import Darwin
import Foundation
import LimitLifeboatCore

/// Watches directories rather than auth files themselves because both CLIs
/// commonly update credentials with an atomic rename, which replaces the file
/// descriptor. Events are debounced so a multi-file Claude update can settle.
final class AuthStateMonitor {
    private struct FileSignature: Equatable {
        var exists: Bool
        var modificationDate: Date?
        var size: UInt64?
        var fileNumber: UInt64?
    }

    private struct WatchKey: Hashable {
        var provider: Provider
        var directory: URL
    }

    private struct WatchEntry {
        var source: DispatchSourceFileSystemObject
        var fileNumber: UInt64?
    }

    private var sources: [WatchKey: WatchEntry] = [:]
    private var pending: [Provider: DispatchWorkItem] = [:]
    private var targets: [Provider: [URL]] = [:]
    private var signatures: [URL: FileSignature] = [:]
    private let queue = DispatchQueue(label: "LimitLifeboat.auth-watch")
    private let onChange: @Sendable (Provider) -> Void
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        onChange: @escaping @Sendable (Provider) -> Void
    ) {
        self.onChange = onChange
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.standardizedFileURL

        let claudeJSON = homeDirectory.appendingPathComponent(".claude.json")
        let claudeConfig = homeDirectory
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            .appendingPathComponent("config.json")
        let codexAuth = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        targets = [
            .claude: [claudeJSON, claudeConfig],
            .codex: [codexAuth]
        ]
        for url in targets.values.flatMap({ $0 }) {
            signatures[url] = signature(of: url)
        }

        // Begin at the closest existing ancestor for every target. Event
        // handling continuously moves these watches down as missing
        // directories appear and rearms them after atomic directory replaces.
        // Exact target signatures still gate onChange, so unrelated home
        // directory writes never become authentication changes.
        reconcileWatches(for: .claude)
        reconcileWatches(for: .codex)
    }

    deinit {
        pending.values.forEach { $0.cancel() }
        sources.values.forEach { $0.source.cancel() }
    }

    private func installWatch(directory: URL, provider: Provider) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconcileWatches(for: provider)
            self.debounce(provider)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        let key = WatchKey(provider: provider, directory: directory)
        sources[key] = WatchEntry(
            source: source,
            fileNumber: directoryFileNumber(directory)
        )
    }

    private func reconcileWatches(for provider: Provider) {
        let providerTargets = targets[provider] ?? []
        let desired = AuthWatchCoverage.directories(
            for: providerTargets,
            homeDirectory: homeDirectory,
            directoryExists: isDirectory
        )
        let existingKeys = sources.keys.filter { $0.provider == provider }
        for key in existingKeys {
            let currentFileNumber = directoryFileNumber(key.directory)
            if !desired.contains(key.directory)
                || currentFileNumber != sources[key]?.fileNumber {
                sources.removeValue(forKey: key)?.source.cancel()
            }
        }
        let installed = Set(sources.keys.filter { $0.provider == provider }.map(\.directory))
        for directory in desired.subtracting(installed) {
            installWatch(directory: directory, provider: provider)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func directoryFileNumber(_ url: URL) -> UInt64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func debounce(_ provider: Provider) {
        pending[provider]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.refreshSignaturesAndDetectChange(for: provider) else {
                return
            }
            self.onChange(provider)
        }
        pending[provider] = work
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func refreshSignaturesAndDetectChange(for provider: Provider) -> Bool {
        var changed = false
        for url in targets[provider] ?? [] {
            let current = signature(of: url)
            if signatures[url] != current {
                signatures[url] = current
                changed = true
            }
        }
        return changed
    }

    private func signature(of url: URL) -> FileSignature {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return FileSignature(exists: false, modificationDate: nil, size: nil, fileNumber: nil)
        }
        return FileSignature(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
