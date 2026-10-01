import Foundation

/// Where the Codex CLI keeps its login, from `cli_auth_credentials_store` in
/// `~/.codex/config.toml`. Switching works by swapping `~/.codex/auth.json`, so
/// only the file store can be switched: `keyring` (and `auto`, which picks the
/// macOS Keychain when it is available) keep the login in a "Codex Auth"
/// Keychain item, and `ephemeral` keeps it in memory only.
public enum CodexCredentialStoreMode: Equatable, Sendable {
    case file
    case keyring
    case auto
    case ephemeral
    case unrecognized(String)

    public var supportsFileSwitching: Bool {
        self == .file
    }

    /// Reads the top-level setting. A missing file or key means Codex's
    /// default, which is the file store.
    public static func current(homeDirectory: URL) -> CodexCredentialStoreMode {
        let configURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .file }
        return parse(configTOML: text)
    }

    /// Minimal TOML scan: only keys before the first table header are
    /// top-level, and that is the only place Codex reads this setting from.
    static func parse(configTOML text: String) -> CodexCredentialStoreMode {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "cli_auth_credentials_store" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch value.lowercased() {
            case "file": return .file
            case "keyring": return .keyring
            case "auto": return .auto
            case "ephemeral": return .ephemeral
            default: return .unrecognized(value)
            }
        }
        return .file
    }

    var configValue: String {
        switch self {
        case .file: return "file"
        case .keyring: return "keyring"
        case .auto: return "auto"
        case .ephemeral: return "ephemeral"
        case .unrecognized(let raw): return raw
        }
    }
}
