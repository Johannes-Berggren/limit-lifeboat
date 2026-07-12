import AppKit
import Foundation

/// Owns the macOS-specific mechanics for opening Terminal and launching a
/// command. Login workflow decisions remain in `AppState`; Apple Events and
/// temporary command-file fallback no longer do.
@MainActor
final class TerminalCommandLauncher {
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    private let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func open() {
        workspace.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Returns nil on success or a user-facing explanation on failure.
    func runViaAutomation(_ command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let scriptSource = """
        tell application "Terminal"
            do script "\(escaped)"
            activate
        end tell
        """

        var errorInfo: NSDictionary?
        if NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo) != nil {
            return nil
        }
        let code = errorInfo?[NSAppleScript.errorNumber] as? Int
        if code == -1743 {
            return "Terminal automation is turned off for LLMUsageMonitor. Enable it in System Settings → Privacy & Security → Automation to log in with one click."
        }
        if let message = errorInfo?[NSAppleScript.errorMessage] as? String, !message.isEmpty {
            return "Could not drive Terminal: \(message)"
        }
        return "Could not drive Terminal to run the login command."
    }

    /// Automation-free fallback: opens a temporary executable `.command` file.
    func runViaCommandFile(_ command: String) -> Bool {
        let scriptURL = fileManager.temporaryDirectory
            .appendingPathComponent("llm-usage-monitor-login-\(UUID().uuidString).command")
        let contents = "#!/bin/zsh\n\(command)\n"
        do {
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open(
            [scriptURL],
            withApplicationAt: terminalURL,
            configuration: configuration,
            completionHandler: nil
        )
        return true
    }
}
