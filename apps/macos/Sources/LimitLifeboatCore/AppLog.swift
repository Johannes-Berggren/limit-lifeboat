import Foundation
import os

/// Central `os.Logger` handles, one per functional area. Entries land in the
/// unified log (Console.app, `log show`) under the app's bundle identifier
/// and are collected by the Settings window's "Copy Diagnostics" action.
///
/// Because that action reads this process's own log store, os_log's
/// `.private` redaction does not protect it — a process sees its own values
/// unredacted. So the rule is stricter than privacy annotations: never
/// interpolate tokens, emails, or account labels into a log message. Refer
/// to accounts by their profile UUID and to providers by display name.
public enum AppLog {
    public static let subsystem = LegacyInstallIdentity.currentBundleIdentifier

    /// CLI login switching: capture, restore, rollback.
    public static let switching = Logger(subsystem: subsystem, category: "switching")
    /// Usage refresh: API fetches, local readers, the /usage CLI probe.
    public static let usage = Logger(subsystem: subsystem, category: "usage")
    /// Credential snapshots, Keychain access, live-login reconciliation.
    public static let credentials = Logger(subsystem: subsystem, category: "credentials")
    /// The persisted usage-history store behind burn-rate estimates.
    public static let history = Logger(subsystem: subsystem, category: "history")
    /// Profile and snapshot persistence in Application Support.
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
