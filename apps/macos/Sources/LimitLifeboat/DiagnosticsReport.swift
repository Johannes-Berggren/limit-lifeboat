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
    static func generate(
        now: Date = Date(),
        applicationSupportDirectory: URL? = nil
    ) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Limit Lifeboat diagnostics",
            "Version: \(AppInfo.version)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Generated: \(formatter.string(from: now))",
            ""
        ]

        // The persisted event log first: it survives relaunches, so the event
        // that caused an overnight logout is still here even after the unified
        // log's current-process scope has been reset.
        if let applicationSupportDirectory {
            lines.append(contentsOf: persistedEventLines(applicationSupportDirectory: applicationSupportDirectory))
            lines.append("")
        }

        lines.append("This session's log entries:")
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

    /// Reads the durable app-events log directly (a fresh read-only store, off
    /// the live @MainActor one) and renders it via the Core formatter.
    private static func persistedEventLines(applicationSupportDirectory: URL) -> [String] {
        let store = AppEventStore(applicationSupportDirectory: applicationSupportDirectory)
        do {
            try store.load()
        } catch {
            return ["Recent app events (persisted): could not read the event log — \(error.localizedDescription)"]
        }
        let events = store.recentEvents()
        guard !events.isEmpty else {
            return ["Recent app events (persisted): none recorded yet."]
        }
        return ["Recent app events (persisted):"] + AppEventStore.diagnosticsLines(for: events)
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
