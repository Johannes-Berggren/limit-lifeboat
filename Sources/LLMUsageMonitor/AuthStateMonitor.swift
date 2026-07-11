import Darwin
import Foundation
import LLMUsageMonitorCore

/// Watches directories rather than auth files themselves because both CLIs
/// commonly update credentials with an atomic rename, which replaces the file
/// descriptor. Events are debounced so a multi-file Claude update can settle.
final class AuthStateMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: [Provider: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "LLMUsageMonitor.auth-watch")
    private let onChange: @Sendable (Provider) -> Void

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, onChange: @escaping @Sendable (Provider) -> Void) {
        self.onChange = onChange
        watch(directory: homeDirectory, provider: .claude)
        watch(directory: homeDirectory.appendingPathComponent(".codex", isDirectory: true), provider: .codex)
        watch(
            directory: homeDirectory.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
            provider: .claude
        )
    }

    deinit {
        pending.values.forEach { $0.cancel() }
        sources.forEach { $0.cancel() }
    }

    private func watch(directory: URL, provider: Provider) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.debounce(provider) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func debounce(_ provider: Provider) {
        pending[provider]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange(provider) }
        pending[provider] = work
        queue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }
}
