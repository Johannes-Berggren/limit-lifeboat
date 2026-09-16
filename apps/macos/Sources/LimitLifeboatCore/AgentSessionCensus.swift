import Darwin
import Foundation

/// One row of the system process table, reduced to what the census needs.
public struct ProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let executablePath: String
    /// Only filled for interpreter processes (node), where the executable
    /// alone cannot tell a Claude Code install apart from any other script.
    public let arguments: [String]
    public let startedAt: Date
    public let footprintBytes: UInt64

    public init(
        pid: Int32,
        parentPID: Int32,
        executablePath: String,
        arguments: [String] = [],
        startedAt: Date,
        footprintBytes: UInt64
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
        self.startedAt = startedAt
        self.footprintBytes = footprintBytes
    }
}

/// A running Claude Code or Codex agent, with the memory of its whole process
/// tree (MCP servers, shells and dev servers it spawned) attributed to it —
/// those children are routinely larger than the agent process itself.
public struct AgentSession: Equatable, Sendable, Identifiable {
    public let pid: Int32
    public let provider: Provider
    public let workingDirectory: String?
    public let startedAt: Date
    public let footprintBytes: UInt64
    public let processCount: Int

    public var id: Int32 { pid }

    public var projectName: String {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            return provider.displayName
        }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    public init(
        pid: Int32,
        provider: Provider,
        workingDirectory: String?,
        startedAt: Date,
        footprintBytes: UInt64,
        processCount: Int
    ) {
        self.pid = pid
        self.provider = provider
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.footprintBytes = footprintBytes
        self.processCount = processCount
    }
}

public enum AgentProcessClassifier {
    /// Whether an interpreter process needs its arguments read to classify.
    public static func needsArguments(executablePath: String) -> Bool {
        let name = basename(executablePath)
        return name == "node" || name == "bun"
    }

    public static func provider(executablePath: String, arguments: [String]) -> Provider? {
        let name = basename(executablePath)
        // The native installer symlinks ~/.local/bin/claude to a binary named
        // after its version (…/claude/versions/2.1.272).
        if name == "claude" || executablePath.contains("/claude/versions/") {
            return .claude
        }
        if name == "codex" {
            return .codex
        }
        if needsArguments(executablePath: executablePath) {
            let script = arguments.dropFirst().first ?? ""
            if script.contains("@anthropic-ai/claude-code") {
                return .claude
            }
            if script.contains("@openai/codex") {
                return .codex
            }
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

public struct AgentSessionCensusBuilder {
    public init() {}

    /// Groups the process table into agent sessions. Processes descending from
    /// `excludedAncestorPID` (Limit Lifeboat's own usage probes) are ignored,
    /// and an agent nested inside another agent's tree is folded into the
    /// outermost one rather than double-counted.
    public func sessions(
        from records: [ProcessRecord],
        excludingDescendantsOf excludedAncestorPID: Int32?,
        workingDirectory: (Int32) -> String?
    ) -> [AgentSession] {
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for record in records where record.parentPID != record.pid {
            children[record.parentPID, default: []].append(record.pid)
        }

        func ancestors(of pid: Int32) -> [Int32] {
            var result: [Int32] = []
            var seen: Set<Int32> = [pid]
            var current = byPID[pid]?.parentPID
            while let parent = current, parent > 0, seen.insert(parent).inserted {
                result.append(parent)
                current = byPID[parent]?.parentPID
            }
            return result
        }

        var providers: [Int32: Provider] = [:]
        for record in records {
            if let provider = AgentProcessClassifier.provider(
                executablePath: record.executablePath,
                arguments: record.arguments
            ) {
                providers[record.pid] = provider
            }
        }

        var sessions: [AgentSession] = []
        for (pid, provider) in providers {
            guard let record = byPID[pid] else { continue }
            let lineage = ancestors(of: pid)
            if let excludedAncestorPID, pid == excludedAncestorPID || lineage.contains(excludedAncestorPID) {
                continue
            }
            if lineage.contains(where: { providers[$0] != nil }) {
                continue
            }

            var footprint: UInt64 = 0
            var count = 0
            var stack = [pid]
            var visited: Set<Int32> = []
            while let next = stack.popLast() {
                guard visited.insert(next).inserted, let member = byPID[next] else { continue }
                footprint += member.footprintBytes
                count += 1
                stack.append(contentsOf: children[next] ?? [])
            }

            sessions.append(AgentSession(
                pid: pid,
                provider: provider,
                workingDirectory: workingDirectory(pid),
                startedAt: record.startedAt,
                footprintBytes: footprint,
                processCount: count
            ))
        }
        return sessions.sorted { $0.footprintBytes > $1.footprintBytes }
    }
}

/// Live reads of the macOS process table via libproc. Only processes owned by
/// the current user are readable, which is exactly the set of agent sessions.
public struct SystemProcessTable: Sendable {
    public init() {}

    public func records() -> [ProcessRecord] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }

        return pids.prefix(Int(count)).compactMap { pid -> ProcessRecord? in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
                return nil
            }
            let path = executablePath(pid: pid)
            let arguments = AgentProcessClassifier.needsArguments(executablePath: path)
                ? self.arguments(pid: pid)
                : []
            return ProcessRecord(
                pid: pid,
                parentPID: Int32(info.pbi_ppid),
                executablePath: path,
                arguments: arguments,
                startedAt: Date(
                    timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                        + TimeInterval(info.pbi_start_tvusec) / 1_000_000
                ),
                footprintBytes: footprint(pid: pid)
            )
        }
    }

    public func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private func executablePath(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private func footprint(pid: Int32) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    /// argv via KERN_PROCARGS2: an argc word, the exec path, NUL padding,
    /// then the NUL-separated arguments.
    private func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return []
        }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var result: [String] = []
        while index < size, result.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
