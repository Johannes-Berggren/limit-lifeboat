import Foundation
import LimitLifeboatCore
import OSLog

/// Builds a plain-text report of this run's app log entries for bug reports.
/// Only entries written by this process under the app's subsystem are
/// included. os_log privacy redaction does NOT apply when a process reads its
/// own store, so the safety guarantee lives in the log statements themselves:
/// they must never interpolate tokens, emails, or account labels — accounts
/// are referenced by their internal UUIDs only (see `AppLog`).
enum DiagnosticsReport {
    static func generate(now: Date = Date()) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Limit Lifeboat diagnostics",
            "Version: \(AppInfo.version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Generated: \(formatter.string(from: now))",
            ""
        ]

        let entries = try store.getEntries()
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == AppLog.subsystem }
        if entries.isEmpty {
            lines.append("No log entries have been recorded in this session yet.")
        }
        for entry in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(label(for: entry.level)): \(entry.composedMessage)")
        }
        return lines.joined(separator: "\n")
    }

    private static func label(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "log"
        @unknown default: return "log"
        }
    }
}
