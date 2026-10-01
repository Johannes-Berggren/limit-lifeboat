import AppKit
import Combine
import Foundation
import LimitLifeboatCore

/// A census row: the process-tree view of a session plus, for Claude, what its
/// transcript says about model, context size and last activity.
struct AgentSessionRow: Identifiable, Equatable {
    let session: AgentSession
    let activity: ClaudeSessionActivity?

    var id: Int32 { session.id }
}

/// Watches running Claude Code / Codex sessions and system memory, and warns
/// before starting another session is likely to exhaust the Mac's memory.
@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var rows: [AgentSessionRow] = []
    @Published private(set) var memory: SystemMemoryStatus?
    @Published private(set) var assessment: MemoryGuardAssessment = .empty
    /// Recent memory-used readings for the optional memory graph; empty while
    /// the graph is off.
    @Published private(set) var trend = MemoryTrend()
    @Published private(set) var isPromptHookInstalled = false
    @Published private(set) var promptHookError: String?
    /// Sessions held at their next tool call, by pid.
    @Published private(set) var parked: [Int32: SessionParkState.Entry] = [:]
    /// Parked sessions whose hook is actually waiting — they reached a tool
    /// call — as opposed to still finishing the turn they were in.
    @Published private(set) var waitingPIDs: Set<Int32> = []
    /// Projects (working directories) marked important: never parked.
    @Published private(set) var starredProjects: Set<String>
    @Published private(set) var isParkHookInstalled = false
    @Published private(set) var parkError: String?
    private(set) var lastParkedAt: Date?

    private let settings: SettingsStore
    private let stateDirectory: URL
    let insightStore: SessionInsightStore
    private let aggregator = SessionInsightAggregator()
    private let coldCachePolicy = ColdCacheAlertPolicy()
    /// Pids already warned about in their current idle spell.
    private var coldCacheWarnedPIDs: Set<Int32> = []
    private var lastSampledAt: Date?
    /// Which transcript each running session is reading, kept across scans.
    private var transcriptBindings = ClaudeTranscriptReader.Bindings()
    private var hasCompletedFirstSample = false
    private let hookInstaller = ClaudeHookInstaller()
    private let parkHookInstaller = ClaudeHookInstaller(hook: SessionParkHookScript.hook)
    private static let starredProjectsKey = "starredSessionProjects"
    private let notify: (MemoryGuardAssessment) -> Void
    private let notifyColdCache: ([ColdCacheAlertPolicy.Candidate]) -> Void
    private let policy = MemoryGuardPolicy()
    private let planner = MemoryGuardAlertPlanner()
    private var lastNotified: MemoryGuardAlertPlanner.Record?
    private var scanTask: Task<Void, Never>?
    private var trendTask: Task<Void, Never>?
    private var graphSetting: AnyCancellable?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isScanning = false
    /// A scan requested while one is running — above all a memory-pressure
    /// event — runs as soon as it finishes instead of being dropped.
    private var rescanRequested = false

    init(
        settings: SettingsStore,
        stateDirectory: URL,
        notify: @escaping (MemoryGuardAssessment) -> Void,
        notifyColdCache: @escaping ([ColdCacheAlertPolicy.Candidate]) -> Void
    ) {
        self.settings = settings
        self.stateDirectory = stateDirectory
        self.insightStore = SessionInsightStore(applicationSupportDirectory: stateDirectory)
        self.notify = notify
        self.notifyColdCache = notifyColdCache
        self.starredProjects = Set(UserDefaults.standard.stringArray(forKey: Self.starredProjectsKey) ?? [])
    }

    private var stateFileURL: URL {
        stateDirectory.appendingPathComponent(MemoryGuardState.fileName)
    }

    private var hookScriptURL: URL {
        stateDirectory.appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(MemoryGuardHookScript.fileName)
    }

    private var parkStateURL: URL {
        stateDirectory.appendingPathComponent(SessionParkState.fileName)
    }

    private var parkHookScriptURL: URL {
        stateDirectory.appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(SessionParkHookScript.fileName)
    }

    private var parkWaitingDirectory: URL {
        stateDirectory.appendingPathComponent("hooks/parked", isDirectory: true)
    }

    func start() {
        guard scanTask == nil else { return }
        // Load past samples so the weekly digest sees more than this launch.
        try? insightStore.load()
        switch hookInstaller.status(expectedScriptPath: hookScriptURL.path) {
        case .notInstalled:
            break
        case .installed:
            // Keep an installed script current with this build's version.
            try? writeHookScript()
        case .needsRepair:
            // The hook points at a script path that is no longer ours; left
            // alone it would fail on every prompt. Reinstall at today's path.
            setPromptHookInstalled(true)
        }
        refreshPromptHookStatus()
        // A previous launch may have left sessions parked; this one starts
        // with none, and says so before the hook's staleness check would.
        writeParkState(now: Date())
        if parkHookInstaller.status(expectedScriptPath: parkHookScriptURL.path) != .notInstalled {
            try? installParkHook()
        }
        isParkHookInstalled = parkHookInstaller.status(expectedScriptPath: parkHookScriptURL.path) == .installed
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                // Cheap enough to watch closely while agents run; otherwise
                // only a slow heartbeat until the next session appears.
                let busy = self.map { !$0.rows.isEmpty || $0.assessment.level > .ok || !$0.parked.isEmpty } ?? false
                try? await Task.sleep(nanoseconds: UInt64(busy ? 20 : 90) * 1_000_000_000)
            }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.scan()
            }
        }
        source.resume()
        pressureSource = source

        graphSetting = settings.$memoryGraphEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.setTrendSampling(enabled)
            }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        graphSetting = nil
        setTrendSampling(false)
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// The graph needs a finer cadence than the census, but only a single
    /// cheap kernel read — so it gets its own loop, and only while it is on.
    private func setTrendSampling(_ enabled: Bool) {
        trendTask?.cancel()
        trendTask = nil
        guard enabled else {
            trend = MemoryTrend()
            return
        }
        trendTask = Task { [weak self] in
            while !Task.isCancelled {
                if let status = SystemMemoryReader().read() {
                    self?.trend.append(status, at: Date())
                }
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
    }

    func scan() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        defer { isScanning = false }

        repeat {
            rescanRequested = false
            await performScan()
        } while rescanRequested
    }

    private func performScan() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bindings = transcriptBindings
        let (rows, memory, updatedBindings) = await Task.detached(priority: .utility) {
            Self.readCensus(excluding: ownPID, bindings: bindings)
        }.value
        transcriptBindings = updatedBindings

        let now = Date()
        // Publish rows and assessment together: fresh rows beside a stale or
        // empty assessment would read as "11 sessions · 0 MB · Memory OK".
        guard let memory else { return }
        self.rows = rows
        self.memory = memory
        // A pressure-triggered scan should show on the graph right away.
        if settings.memoryGraphEnabled {
            trend.append(memory, at: now)
        }

        var lastActivity: [Int32: Date] = [:]
        for row in rows {
            if let activity = row.activity {
                lastActivity[row.id] = activity.lastActivityAt
            }
        }
        let assessment = policy.assess(
            memory: memory,
            sessions: rows.map(\.session),
            lastActivity: lastActivity,
            now: now
        )
        self.assessment = assessment
        try? MemoryGuardState(assessment: assessment, now: now).write(to: stateFileURL)

        recordSample(rows: rows, now: now)
        refreshParks(rows: rows, now: now)

        if assessment.level == .ok {
            lastNotified = nil
        } else if settings.memoryGuardAlertsEnabled,
                  planner.shouldNotify(assessment, lastNotified: lastNotified, now: now) {
            lastNotified = .init(level: assessment.level, notifiedAt: now)
            notify(assessment)
        }
    }

    /// Samples every few minutes for the weekly digest, and warns once when a
    /// session has been idle long enough to lose its prompt cache.
    private func recordSample(rows: [AgentSessionRow], now: Date) {
        let entries = rows.map { row in
            SessionSample.Entry(
                pid: row.session.pid,
                provider: row.session.provider,
                project: row.session.projectName,
                model: row.activity?.model,
                contextTokens: row.activity?.contextTokens ?? 0,
                idleSeconds: row.activity.map { Int(now.timeIntervalSince($0.lastActivityAt)) },
                cacheTTLSeconds: row.activity?.cacheTTLSeconds
            )
        }

        // Re-arm a session once it wakes up or disappears: a pid still idle
        // past the threshold stays warned, everything else is dropped.
        coldCacheWarnedPIDs = coldCacheWarnedPIDs.intersection(
            Set(entries.filter { ($0.idleSeconds ?? 0) >= coldCachePolicy.idleSeconds }.map(\.pid))
        )

        let candidates = coldCachePolicy.candidates(entries: entries, alreadyWarned: coldCacheWarnedPIDs)
        if !candidates.isEmpty {
            coldCacheWarnedPIDs.formUnion(candidates.map(\.pid))
            // On the first scan of a launch, sessions that were already idle
            // for hours are recorded silently: their cache is long gone, so
            // "finish now to avoid it" would be advice about a past event.
            if settings.cacheAlertsEnabled, hasCompletedFirstSample {
                notifyColdCache(candidates)
            }
        }
        hasCompletedFirstSample = true

        let due = lastSampledAt.map { now.timeIntervalSince($0) >= Double(aggregator.sampleMinutes * 60) } ?? true
        guard due, !entries.isEmpty else { return }
        lastSampledAt = now
        try? insightStore.append(SessionSample(timestamp: now, entries: entries))
    }

    /// Adds or removes the Claude Code hook that holds new sessions while
    /// memory is critical. Touches only Limit Lifeboat's own hook entry.
    func setPromptHookInstalled(_ installed: Bool) {
        promptHookError = nil
        do {
            if installed {
                try writeHookScript()
                try hookInstaller.install(scriptPath: hookScriptURL.path)
            } else {
                try hookInstaller.uninstall()
            }
        } catch {
            promptHookError = error.localizedDescription
        }
        refreshPromptHookStatus()
    }

    /// Only an entry pointing at this build's script counts as installed, so
    /// Settings never shows a drifted, failing hook as working.
    private func refreshPromptHookStatus() {
        isPromptHookInstalled = hookInstaller.status(expectedScriptPath: hookScriptURL.path) == .installed
    }

    private func writeHookScript() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hookScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = MemoryGuardHookScript.contents(
            stateFile: stateFileURL,
            heldDirectory: stateDirectory.appendingPathComponent("hooks/held", isDirectory: true)
        )
        try Data(script.utf8).write(to: hookScriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
    }

    // MARK: - Parking

    func isStarred(_ row: AgentSessionRow) -> Bool {
        row.session.workingDirectory.map(starredProjects.contains) ?? false
    }

    func setStarred(_ starred: Bool, for row: AgentSessionRow) {
        guard let directory = row.session.workingDirectory else { return }
        if starred {
            starredProjects.insert(directory)
            // Marking something important while it is parked means "let it run".
            for other in rows where other.session.workingDirectory == directory {
                parked[other.id] = nil
            }
            writeParkState(now: Date())
        } else {
            starredProjects.remove(directory)
        }
        UserDefaults.standard.set(starredProjects.sorted(), forKey: Self.starredProjectsKey)
    }

    /// Only Claude Code runs the park hook.
    func canPark(_ row: AgentSessionRow) -> Bool {
        row.session.provider == .claude
    }

    func park(
        pids: [Int32],
        reason: SessionParkState.Reason,
        releaseAt: Date? = nil,
        profileID: UUID? = nil
    ) {
        parkError = nil
        do {
            try installParkHook()
        } catch {
            parkError = error.localizedDescription
            return
        }
        let now = Date()
        for row in rows where pids.contains(row.id) && canPark(row) && !isStarred(row) {
            parked[row.id] = SessionParkState.Entry(
                pid: row.session.pid,
                startedAt: row.session.startedAt,
                project: row.session.projectName,
                reason: reason,
                parkedAt: now,
                releaseAt: releaseAt,
                profileID: profileID
            )
        }
        lastParkedAt = now
        writeParkState(now: now)
    }

    func resume(_ pid: Int32) {
        parked[pid] = nil
        writeParkState(now: Date())
    }

    /// Resumes every park matching `predicate` (all of them by default).
    func resumeAll(where predicate: (SessionParkState.Entry) -> Bool = { _ in true }) {
        let before = parked.count
        parked = parked.filter { !predicate($0.value) }
        if parked.count != before {
            writeParkState(now: Date())
        }
    }

    /// Drops parks for sessions that exited (or whose pid was reused) and
    /// those whose quota has come back, then rewrites the state: the write is
    /// also the heartbeat that tells the hook the app is still running.
    private func refreshParks(rows: [AgentSessionRow], now: Date) {
        let live = Dictionary(rows.map { ($0.id, $0.session.startedAt) }, uniquingKeysWith: { first, _ in first })
        parked = parked.filter { pid, entry in
            guard let startedAt = live[pid], abs(startedAt.timeIntervalSince(entry.startedAt)) < 1 else {
                return false
            }
            return entry.releaseAt.map { $0 > now } ?? true
        }
        writeParkState(now: now)
    }

    private func writeParkState(now: Date) {
        let entries = parked.values.sorted { $0.pid < $1.pid }
        try? SessionParkState(parked: entries, now: now).write(to: parkStateURL)
        let markers = (try? FileManager.default.contentsOfDirectory(atPath: parkWaitingDirectory.path)) ?? []
        waitingPIDs = Set(markers.compactMap(Int32.init)).intersection(parked.keys)
    }

    private func installParkHook() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: parkHookScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = SessionParkHookScript.contents(stateFile: parkStateURL, waitingDirectory: parkWaitingDirectory)
        try Data(script.utf8).write(to: parkHookScriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parkHookScriptURL.path)
        if parkHookInstaller.status(expectedScriptPath: parkHookScriptURL.path) != .installed {
            try parkHookInstaller.install(scriptPath: parkHookScriptURL.path)
        }
        isParkHookInstalled = true
    }

    /// Removes the park hook from Claude Code, resuming anything parked.
    func uninstallParkHook() {
        resumeAll()
        do {
            try parkHookInstaller.uninstall()
            parkError = nil
        } catch {
            parkError = error.localizedDescription
        }
        isParkHookInstalled = parkHookInstaller.status(expectedScriptPath: parkHookScriptURL.path) == .installed
    }

    func revealInFinder(_ row: AgentSessionRow) {
        guard let directory = row.session.workingDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    /// SIGTERM lets the CLI shut down its children and flush the transcript,
    /// so the conversation can be resumed later. Never automatic.
    func confirmAndQuit(_ row: AgentSessionRow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(row.session.provider.displayName) session in \(row.session.projectName)?"
        alert.informativeText = "This frees about \(MemoryFormatting.bytes(row.session.footprintBytes)). Any work in progress in that session stops; the conversation can be resumed later with --resume."
        alert.addButton(withTitle: "Quit Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModalActivating() == .alertFirstButtonReturn else { return }
        // The row can be a scan old and the dialog sat open; never signal a
        // pid that has since exited and been reused by something else.
        guard SystemProcessTable().isStillRunning(row.session) else {
            Task { await scan() }
            return
        }
        kill(row.session.pid, SIGTERM)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await scan()
        }
    }

    nonisolated private static func readCensus(
        excluding ownPID: Int32,
        bindings: ClaudeTranscriptReader.Bindings
    ) -> ([AgentSessionRow], SystemMemoryStatus?, ClaudeTranscriptReader.Bindings) {
        let table = SystemProcessTable()
        let sessions = AgentSessionCensusBuilder().sessions(
            from: table.records(),
            excludingDescendantsOf: ownPID,
            workingDirectory: table.workingDirectory(pid:)
        )
        var bindings = bindings
        let activities = ClaudeTranscriptReader().activities(for: sessions, bindings: &bindings)
        let rows = sessions.map { AgentSessionRow(session: $0, activity: activities[$0.pid]) }
        return (rows, SystemMemoryReader().read(), bindings)
    }
}
