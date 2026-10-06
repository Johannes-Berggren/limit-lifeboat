import Foundation
import LimitLifeboatCore

/// Settings state for the bundled `limit-lifeboat` command and Claude Code's
/// status line. Both are opt-in and only ever undo what they themselves did.
@MainActor
final class CommandLineIntegrationModel: ObservableObject {
    @Published private(set) var toolStatus: CommandLineToolInstaller.Status = .notInstalled
    @Published private(set) var statusLineStatus: ClaudeStatusLineInstaller.Status = .notSet
    @Published private(set) var error: String?

    private let toolInstaller = CommandLineToolInstaller()
    private let statusLineInstaller = ClaudeStatusLineInstaller()
    /// Nil when running from `swift run` or a build without the helper.
    let bundledTool = CommandLineToolInstaller.bundledTool()

    var linkPath: String { toolInstaller.linkURL.path }

    init() {
        refresh()
    }

    func refresh() {
        if let bundledTool {
            toolStatus = toolInstaller.status(bundledTool: bundledTool)
        }
        statusLineStatus = statusLineInstaller.status()
    }

    func setToolInstalled(_ installed: Bool) {
        error = nil
        guard let bundledTool else { return }
        do {
            if installed {
                try toolInstaller.install(bundledTool: bundledTool)
            } else {
                // The status line would point at a missing command.
                try statusLineInstaller.uninstall()
                try toolInstaller.uninstall()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func setStatusLineInstalled(_ installed: Bool) {
        error = nil
        guard let bundledTool else { return }
        do {
            if installed {
                try toolInstaller.install(bundledTool: bundledTool)
                // The link path, not the bundle path: it keeps working if the
                // app is moved and is re-linked.
                try statusLineInstaller.install(toolPath: toolInstaller.linkURL.path)
            } else {
                try statusLineInstaller.uninstall()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}
