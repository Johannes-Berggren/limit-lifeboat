import Darwin
import Foundation

public struct CodexAccountUsageResult: Equatable, Sendable {
    public var snapshot: UsageSnapshot
    public var accountInfo: CodexAccountInfo
    public var updatedAuthJSON: Data

    public init(snapshot: UsageSnapshot, accountInfo: CodexAccountInfo, updatedAuthJSON: Data) {
        self.snapshot = snapshot
        self.accountInfo = accountInfo
        self.updatedAuthJSON = updatedAuthJSON
    }
}

public enum CodexResetRedemptionOutcome: String, Codable, Equatable, Sendable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit

    public var consumedReset: Bool {
        self == .reset || self == .alreadyRedeemed
    }
}

/// Result of one logical reset redemption. A consumed reset can be returned
/// without a refreshed snapshot when the consume response was authoritative
/// but the required follow-up rate-limit read failed.
public struct CodexResetRedemptionResult: Equatable, Sendable {
    public var outcome: CodexResetRedemptionOutcome
    public var refreshedUsage: CodexAccountUsageResult?
    public var updatedAuthJSON: Data
    public var refreshFailureReason: String?

    public init(
        outcome: CodexResetRedemptionOutcome,
        refreshedUsage: CodexAccountUsageResult?,
        updatedAuthJSON: Data,
        refreshFailureReason: String? = nil
    ) {
        self.outcome = outcome
        self.refreshedUsage = refreshedUsage
        self.updatedAuthJSON = updatedAuthJSON
        self.refreshFailureReason = refreshFailureReason
    }
}

public enum CodexAccountUsageError: Error, LocalizedError, Equatable, Sendable {
    case requiresLogin(reason: String)
    case unsupported(reason: String)
    case unavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .requiresLogin(let reason), .unsupported(let reason), .unavailable(let reason):
            return reason
        }
    }
}

/// A reset request can fail after Codex has legitimately rotated the isolated
/// credential. Carry that safe rotation back to the caller so it can still be
/// persisted with the same fingerprint compare-and-swap as a successful read.
public struct CodexResetRedemptionError: Error, LocalizedError, Equatable, Sendable {
    public var failure: CodexAccountUsageError
    public var updatedAuthJSON: Data?

    public init(failure: CodexAccountUsageError, updatedAuthJSON: Data?) {
        self.failure = failure
        self.updatedAuthJSON = updatedAuthJSON
    }

    public var errorDescription: String? {
        failure.localizedDescription
    }
}

struct CodexRateLimitWindowReading: Equatable, Sendable {
    var name: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}

struct CodexCreditsReading: Equatable, Sendable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

struct CodexRateLimitReading: Equatable, Sendable {
    var windows: [CodexRateLimitWindowReading]
    var credits: CodexCreditsReading?
    var planType: String?
    var reachedType: String?
    var resetAvailability: CodexRateLimitResetAvailability? = nil
}

enum CodexUsageAppServerOutcome: Equatable, Sendable {
    case success(accountEmail: String?, rateLimits: CodexRateLimitReading)
    case requiresLogin(reason: String)
    case unavailable(reason: String)
}

enum CodexResetAppServerOutcome: Equatable, Sendable {
    case success(
        accountEmail: String?,
        outcome: CodexResetRedemptionOutcome,
        rateLimits: CodexRateLimitReading
    )
    case completedWithoutRefresh(
        accountEmail: String?,
        outcome: CodexResetRedemptionOutcome,
        reason: String
    )
    case requiresLogin(reason: String)
    case unsupported(reason: String)
    case unavailable(reason: String)
}

protocol CodexUsageAppServerRunning {
    func readUsage(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        timeout: TimeInterval
    ) async -> CodexUsageAppServerOutcome

    func redeemReset(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        idempotencyKey: String,
        expectedAccountEmail: String?,
        timeout: TimeInterval
    ) async -> CodexResetAppServerOutcome
}

extension CodexUsageAppServerRunning {
    func redeemReset(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        idempotencyKey: String,
        expectedAccountEmail: String?,
        timeout: TimeInterval
    ) async -> CodexResetAppServerOutcome {
        .unsupported(reason: "This Codex usage runner does not support reset redemption.")
    }
}

/// Reads current ChatGPT/Codex quota through Codex's stable app-server API.
/// Every call uses a private copied CODEX_HOME: the live CLI login is never
/// selected, replaced, or exposed to the subprocess through its normal home.
public struct CodexAccountUsageService {
    private let runner: any CodexUsageAppServerRunning
    private let fileManager: FileManager
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.runner = CodexUsageAppServerProcessRunner()
        self.fileManager = .default
        self.timeout = timeout
    }

    init(
        runner: any CodexUsageAppServerRunning,
        fileManager: FileManager = .default,
        timeout: TimeInterval = 20
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.timeout = timeout
    }

    public func fetchSnapshot(
        for profile: AccountProfile,
        authJSON: Data,
        executableURL: URL,
        expectedIdentity: AccountIdentity?,
        now: Date = Date()
    ) async throws -> CodexAccountUsageResult {
        guard profile.provider == .codex else {
            throw CodexAccountUsageError.unavailable(reason: "Codex usage was requested for a different provider.")
        }
        guard Self.hasSubscriptionTokens(authJSON) else {
            throw CodexAccountUsageError.requiresLogin(
                reason: "The saved Codex account has no usable ChatGPT credentials."
            )
        }

        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("limit-lifeboat-codex-usage-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryHome.path)
        } catch {
            throw CodexAccountUsageError.unavailable(
                reason: "Could not prepare an isolated Codex usage check."
            )
        }
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let authURL = temporaryHome.appendingPathComponent("auth.json")
        do {
            try authJSON.write(to: authURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        } catch {
            throw CodexAccountUsageError.unavailable(
                reason: "Could not prepare the saved Codex login for a usage check."
            )
        }

        var forceRefresh = false
        var successfulResult: (accountEmail: String?, rateLimits: CodexRateLimitReading)?
        while successfulResult == nil {
            switch await runner.readUsage(
                executableURL: executableURL,
                codexHome: temporaryHome,
                forceRefresh: forceRefresh,
                timeout: timeout
            ) {
            case .success(let returnedEmail, let reading):
                successfulResult = (returnedEmail, reading)
            case .requiresLogin(let reason):
                if !forceRefresh {
                    // A normal account/rate-limit read can reject an expired
                    // access token even while its refresh token is healthy.
                    // Ask Codex to rotate once before declaring the login dead.
                    forceRefresh = true
                    continue
                }
                throw CodexAccountUsageError.requiresLogin(reason: reason)
            case .unavailable(let reason):
                throw CodexAccountUsageError.unavailable(reason: reason)
            }
        }
        let accountEmail = successfulResult?.accountEmail
        guard let rateLimits = successfulResult?.rateLimits else {
            throw CodexAccountUsageError.unavailable(
                reason: "Codex account recovery ended without a usage result."
            )
        }

        let updatedAuthJSON: Data
        do {
            updatedAuthJSON = try Data(contentsOf: authURL)
        } catch {
            throw CodexAccountUsageError.unavailable(
                reason: "Codex returned usage but its refreshed credentials were unreadable."
            )
        }
        guard Self.hasSubscriptionTokens(updatedAuthJSON) else {
            throw CodexAccountUsageError.requiresLogin(
                reason: "The saved Codex account no longer contains a ChatGPT login."
            )
        }

        return try Self.makeUsageResult(
            profile: profile,
            rateLimits: rateLimits,
            accountEmail: accountEmail,
            updatedAuthJSON: updatedAuthJSON,
            expectedIdentity: expectedIdentity,
            now: now
        )
    }

    /// Consumes one earned reset after a fresh, identity-verified usage read.
    /// The caller owns idempotency-key persistence and must reuse the same key
    /// when retrying one logical attempt.
    public func redeemReset(
        for profile: AccountProfile,
        authJSON: Data,
        executableURL: URL,
        expectedIdentity: AccountIdentity?,
        idempotencyKey: String,
        now: Date = Date()
    ) async throws -> CodexResetRedemptionResult {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAccountUsageError.unavailable(reason: "A reset attempt requires an idempotency key.")
        }

        // This verifies the isolated credential against the saved profile
        // before the irreversible consume request is ever sent. It also gives
        // the consume process the newest token generation.
        let verified = try await fetchSnapshot(
            for: profile,
            authJSON: authJSON,
            executableURL: executableURL,
            expectedIdentity: expectedIdentity,
            now: now
        )

        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("limit-lifeboat-codex-reset-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryHome,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryHome.path)
        } catch {
            throw CodexResetRedemptionError(
                failure: .unavailable(reason: "Could not prepare an isolated Codex reset request."),
                updatedAuthJSON: verified.updatedAuthJSON
            )
        }
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let authURL = temporaryHome.appendingPathComponent("auth.json")
        do {
            try verified.updatedAuthJSON.write(to: authURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        } catch {
            throw CodexResetRedemptionError(
                failure: .unavailable(reason: "Could not prepare the saved Codex login for a reset request."),
                updatedAuthJSON: verified.updatedAuthJSON
            )
        }

        var forceRefresh = false
        while true {
            let appServerOutcome = await runner.redeemReset(
                executableURL: executableURL,
                codexHome: temporaryHome,
                forceRefresh: forceRefresh,
                idempotencyKey: idempotencyKey,
                expectedAccountEmail: verified.accountInfo.identity?.email ?? expectedIdentity?.email,
                timeout: timeout
            )

            let updatedAuthJSON: Data
            do {
                updatedAuthJSON = try Data(contentsOf: authURL)
            } catch {
                throw CodexResetRedemptionError(
                    failure: .unavailable(
                        reason: "Codex handled the reset request but its refreshed credentials were unreadable."
                    ),
                    updatedAuthJSON: verified.updatedAuthJSON
                )
            }
            guard Self.hasSubscriptionTokens(updatedAuthJSON) else {
                throw CodexResetRedemptionError(
                    failure: .requiresLogin(
                        reason: "The saved Codex account no longer contains a ChatGPT login."
                    ),
                    updatedAuthJSON: nil
                )
            }

            switch appServerOutcome {
            case .success(let accountEmail, let outcome, let rateLimits):
                let refreshed = try Self.makeUsageResult(
                    profile: profile,
                    rateLimits: rateLimits,
                    accountEmail: accountEmail,
                    updatedAuthJSON: updatedAuthJSON,
                    expectedIdentity: expectedIdentity,
                    now: now
                )
                return CodexResetRedemptionResult(
                    outcome: outcome,
                    refreshedUsage: refreshed,
                    updatedAuthJSON: updatedAuthJSON
                )
            case .completedWithoutRefresh(let accountEmail, let outcome, let reason):
                _ = try Self.validatedAccountInfo(
                    rateLimits: nil,
                    accountEmail: accountEmail,
                    updatedAuthJSON: updatedAuthJSON,
                    expectedIdentity: expectedIdentity,
                    now: now
                )
                return CodexResetRedemptionResult(
                    outcome: outcome,
                    refreshedUsage: nil,
                    updatedAuthJSON: updatedAuthJSON,
                    refreshFailureReason: reason
                )
            case .requiresLogin(let reason):
                if !forceRefresh {
                    forceRefresh = true
                    continue
                }
                throw CodexResetRedemptionError(
                    failure: .requiresLogin(reason: reason),
                    updatedAuthJSON: updatedAuthJSON
                )
            case .unsupported(let reason):
                throw CodexResetRedemptionError(
                    failure: .unsupported(reason: reason),
                    updatedAuthJSON: updatedAuthJSON
                )
            case .unavailable(let reason):
                throw CodexResetRedemptionError(
                    failure: .unavailable(reason: reason),
                    updatedAuthJSON: updatedAuthJSON
                )
            }
        }
    }

    private static func makeUsageResult(
        profile: AccountProfile,
        rateLimits: CodexRateLimitReading,
        accountEmail: String?,
        updatedAuthJSON: Data,
        expectedIdentity: AccountIdentity?,
        now: Date
    ) throws -> CodexAccountUsageResult {
        let accountInfo = try validatedAccountInfo(
            rateLimits: rateLimits,
            accountEmail: accountEmail,
            updatedAuthJSON: updatedAuthJSON,
            expectedIdentity: expectedIdentity,
            now: now
        )
        return CodexAccountUsageResult(
            snapshot: makeSnapshot(profile: profile, reading: rateLimits, now: now),
            accountInfo: accountInfo,
            updatedAuthJSON: updatedAuthJSON
        )
    }

    private static func validatedAccountInfo(
        rateLimits: CodexRateLimitReading?,
        accountEmail: String?,
        updatedAuthJSON: Data,
        expectedIdentity: AccountIdentity?,
        now: Date
    ) throws -> CodexAccountInfo {
        let decodedInfo = CodexIdentityReader.accountInfo(fromAuthJSON: updatedAuthJSON, now: now)
            ?? CodexAccountInfo()
        if let accountEmail {
            guard decodedInfo.identity?.email?.caseInsensitiveCompare(accountEmail) == .orderedSame else {
                throw CodexAccountUsageError.unavailable(
                    reason: "Codex returned usage for an identity that did not match its refreshed credentials."
                )
            }
        }
        if let expectedIdentity {
            guard let returnedIdentity = decodedInfo.identity,
                  expectedIdentity.matches(returnedIdentity) else {
                throw CodexAccountUsageError.unavailable(
                    reason: "Codex returned usage for a different saved account."
                )
            }
        }
        let planLabel = rateLimits.flatMap { CodexIdentityReader.planLabel(forPlanType: $0.planType) }
            ?? decodedInfo.planLabel
        return CodexAccountInfo(identity: decodedInfo.identity, planLabel: planLabel)
    }

    static func makeSnapshot(
        profile: AccountProfile,
        reading: CodexRateLimitReading,
        now: Date
    ) -> UsageSnapshot {
        let windows = reading.windows.map { item in
            UsageSnapshotFactory.window(
                descriptor: CodexUsageWindowCatalog.descriptor(
                    name: item.name,
                    windowMinutes: item.windowMinutes
                ),
                usedPercent: item.usedPercent,
                resetDate: item.resetsAt,
                resetDescription: item.resetsAt.map {
                    "in \(DurationPhrase.short($0.timeIntervalSince(now)))"
                }
            )
        }
        let selected = reading.windows.max(by: { $0.usedPercent < $1.usedPercent })
        var messageParts: [String] = []
        if let selected {
            messageParts.append("Codex reports \(Int(selected.usedPercent.rounded()))% used")
        } else {
            messageParts.append("Codex returned no rate-limit windows")
        }
        if let planType = reading.planType, !planType.isEmpty {
            messageParts.append("plan: \(planType)")
        }
        var snapshot = UsageSnapshotFactory.snapshot(
            accountID: profile.id,
            provider: .codex,
            windows: windows,
            creditStatus: creditStatus(reading),
            codexRateLimitResetAvailability: reading.resetAvailability,
            codexRateLimitReachedType: reading.reachedType,
            source: "Codex app server",
            lastRefreshed: now,
            message: messageParts.joined(separator: " - ")
        )
        // The server can report an account/workspace-level exhausted state
        // even when its last sampled percentages have not reached 100. Keep
        // those exact percentages, but carry the authoritative state through
        // the existing risk fields used by rows, alerts, and switch advice.
        if reading.reachedType?.isEmpty == false {
            snapshot.riskLevel = .depleted
            for index in snapshot.windows.indices {
                snapshot.windows[index].riskLevel = .depleted
            }
        }
        return snapshot
    }

    private static func creditStatus(_ reading: CodexRateLimitReading) -> String? {
        if let reachedType = reading.reachedType, !reachedType.isEmpty {
            return "Rate limit reached: \(reachedType)."
        }
        guard let credits = reading.credits else { return nil }
        if credits.unlimited {
            return "Usage credits are unlimited."
        }
        guard credits.hasCredits else { return nil }
        if let balance = credits.balance, !balance.isEmpty {
            return "Usage credits available: \(balance)."
        }
        return "Usage credits are available."
    }

    private static func hasSubscriptionTokens(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String else {
            return false
        }
        return !accessToken.isEmpty && !refreshToken.isEmpty
    }
}

final class CodexUsageAppServerResponseAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var accountEmail: String?
    private var receivedAccount = false
    private var rateLimits: CodexRateLimitReading?
    private var storedOutcome: CodexUsageAppServerOutcome?

    var outcome: CodexUsageAppServerOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcome
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else {
                continue
            }
            switch id {
            case 1:
                if object["error"] != nil {
                    storedOutcome = .unavailable(
                        reason: "This Codex version could not initialize live usage checks."
                    )
                }
            case 2:
                if let failure = Self.classifyFailure(object) {
                    storedOutcome = failure
                } else if let result = object["result"] as? [String: Any],
                          let account = result["account"] as? [String: Any],
                          account["type"] as? String == "chatgpt" {
                    accountEmail = account["email"] as? String
                    receivedAccount = true
                } else if let result = object["result"] as? [String: Any],
                          result["requiresOpenaiAuth"] as? Bool == true {
                    storedOutcome = .requiresLogin(
                        reason: "Codex could not find a usable ChatGPT login for this account."
                    )
                } else {
                    storedOutcome = .unavailable(
                        reason: "Codex returned an unexpected account response."
                    )
                }
            case 3:
                if let failure = Self.classifyFailure(object) {
                    storedOutcome = failure
                } else if let result = object["result"] as? [String: Any],
                          let reading = Self.parseRateLimits(result) {
                    rateLimits = reading
                } else {
                    storedOutcome = .unavailable(
                        reason: "Codex returned an unreadable rate-limit response."
                    )
                }
            default:
                break
            }
            if storedOutcome != nil {
                return true
            }
            if receivedAccount, let rateLimits {
                storedOutcome = .success(accountEmail: accountEmail, rateLimits: rateLimits)
                return true
            }
        }
        return false
    }

    static func parseRateLimits(_ result: [String: Any]) -> CodexRateLimitReading? {
        let selected: [String: Any]?
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            selected = codex
        } else {
            selected = result["rateLimits"] as? [String: Any]
        }
        guard let selected else { return nil }

        var windows: [CodexRateLimitWindowReading] = []
        for name in ["primary", "secondary"] {
            guard let raw = selected[name] as? [String: Any],
                  let usedPercent = finiteNumber(raw["usedPercent"]) else {
                continue
            }
            windows.append(
                CodexRateLimitWindowReading(
                    name: name,
                    usedPercent: usedPercent,
                    windowMinutes: integer(raw["windowDurationMins"]),
                    resetsAt: finiteNumber(raw["resetsAt"]).map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        guard !windows.isEmpty else { return nil }

        let credits = (selected["credits"] as? [String: Any]).map { raw in
            CodexCreditsReading(
                hasCredits: raw["hasCredits"] as? Bool ?? false,
                unlimited: raw["unlimited"] as? Bool ?? false,
                balance: raw["balance"] as? String
            )
        }
        let resetAvailability = parseResetAvailability(result["rateLimitResetCredits"])
        return CodexRateLimitReading(
            windows: windows,
            credits: credits,
            planType: selected["planType"] as? String,
            reachedType: selected["rateLimitReachedType"] as? String,
            resetAvailability: resetAvailability
        )
    }

    private static func parseResetAvailability(_ value: Any?) -> CodexRateLimitResetAvailability? {
        guard let raw = value as? [String: Any],
              let availableCount = integer(raw["availableCount"]) else {
            return nil
        }

        let details: [CodexRateLimitResetCredit]?
        if raw["credits"] is NSNull || raw["credits"] == nil {
            details = nil
        } else if let rows = raw["credits"] as? [[String: Any]] {
            details = rows.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty,
                      let resetType = row["resetType"] as? String,
                      let status = row["status"] as? String,
                      let grantedAt = finiteNumber(row["grantedAt"]) else {
                    return nil
                }
                return CodexRateLimitResetCredit(
                    id: id,
                    resetType: resetType,
                    status: status,
                    grantedAt: Date(timeIntervalSince1970: grantedAt),
                    expiresAt: finiteNumber(row["expiresAt"]).map(Date.init(timeIntervalSince1970:)),
                    title: row["title"] as? String,
                    description: row["description"] as? String
                )
            }
        } else {
            details = nil
        }
        return CodexRateLimitResetAvailability(
            availableCount: availableCount,
            credits: details
        )
    }

    static func classifyFailure(_ response: [String: Any]) -> CodexUsageAppServerOutcome? {
        guard let error = response["error"] else { return nil }
        let errorData = try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys])
        let normalized = errorData.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
        let authenticationMarkers = [
            "authentication required",
            "invalid_grant",
            "token_invalidated",
            "refresh token was already used",
            "refresh token has already been used",
            "invalid refresh token",
            "refresh token is invalid",
            "refresh token has expired",
            "refresh token expired",
            "token expired",
            "token revoked",
            "sign in again",
            "login again",
            "unauthorized",
            "401"
        ]
        if authenticationMarkers.contains(where: normalized.contains) {
            return .requiresLogin(reason: "Codex could not refresh this account. Sign in again to continue using it.")
        }
        return .unavailable(reason: "Codex could not read this account's usage right now.")
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let parsed = number(value), parsed.isFinite else { return nil }
        return parsed
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let parsed = finiteNumber(value),
              parsed.rounded(.towardZero) == parsed,
              let integer = Int(exactly: parsed) else {
            return nil
        }
        return integer
    }
}

/// Thread-safe JSONL inbox used by the reset flow, whose requests must be sent
/// sequentially so account verification completes before consumption and the
/// follow-up rate-limit read cannot race the consume request.
private final class CodexJSONRPCResponseInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [[String: Any]]] = [:]
    private var ended = false

    func append(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        if data.isEmpty {
            ended = true
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else {
                continue
            }
            responses[id, default: []].append(object)
        }
    }

    func finish() {
        condition.lock()
        ended = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: Int, deadline: Date) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if var queued = responses[id], !queued.isEmpty {
                let response = queued.removeFirst()
                responses[id] = queued
                return response
            }
            if ended || Date() >= deadline {
                return nil
            }
            _ = condition.wait(until: deadline)
        }
    }
}

struct CodexUsageAppServerProcessRunner: CodexUsageAppServerRunning {
    func readUsage(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        timeout: TimeInterval
    ) async -> CodexUsageAppServerOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runSynchronously(
                        executableURL: executableURL,
                        codexHome: codexHome,
                        forceRefresh: forceRefresh,
                        timeout: timeout
                    )
                )
            }
        }
    }

    func redeemReset(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        idempotencyKey: String,
        expectedAccountEmail: String?,
        timeout: TimeInterval
    ) async -> CodexResetAppServerOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runResetSynchronously(
                        executableURL: executableURL,
                        codexHome: codexHome,
                        forceRefresh: forceRefresh,
                        idempotencyKey: idempotencyKey,
                        expectedAccountEmail: expectedAccountEmail,
                        timeout: timeout
                    )
                )
            }
        }
    }

    private func runSynchronously(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        timeout: TimeInterval
    ) -> CodexUsageAppServerOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--stdio",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "analytics.enabled=false",
            "-c", "check_for_update_on_startup=false"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["RUST_LOG"] = "error"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let accumulator = CodexUsageAppServerResponseAccumulator()
        let completed = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty || accumulator.append(data) {
                completed.signal()
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in completed.signal() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return .unavailable(reason: "Could not start Codex for a live usage check.")
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "limit_lifeboat",
                        "title": "Limit Lifeboat",
                        "version": "1"
                    ],
                    "capabilities": [:]
                ]
            ],
            ["method": "initialized", "params": [:]],
            ["method": "account/read", "id": 2, "params": ["refreshToken": forceRefresh]],
            ["method": "account/rateLimits/read", "id": 3]
        ]
        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { continue }
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0a]))
        }

        let waitResult = completed.wait(timeout: .now() + timeout)
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        if let outcome = accumulator.outcome {
            return outcome
        }
        if waitResult == .timedOut {
            return .unavailable(reason: "Codex live usage check timed out.")
        }
        return .unavailable(reason: "Codex live usage check ended before returning a result.")
    }

    private func runResetSynchronously(
        executableURL: URL,
        codexHome: URL,
        forceRefresh: Bool,
        idempotencyKey: String,
        expectedAccountEmail: String?,
        timeout: TimeInterval
    ) -> CodexResetAppServerOutcome {
        let process = configuredProcess(executableURL: executableURL, codexHome: codexHome)
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let inbox = CodexJSONRPCResponseInbox()
        output.fileHandleForReading.readabilityHandler = { handle in
            inbox.append(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { _ in inbox.finish() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            return .unavailable(reason: "Could not start Codex for a reset request.")
        }
        defer {
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                usleep(100_000)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        writeMessage(
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "limit_lifeboat",
                        "title": "Limit Lifeboat",
                        "version": "1"
                    ],
                    "capabilities": [:]
                ]
            ],
            to: input.fileHandleForWriting
        )
        guard let initialize = inbox.waitForResponse(id: 1, deadline: deadline),
              initialize["error"] == nil else {
            return .unavailable(reason: "This Codex version could not initialize reset requests.")
        }
        writeMessage(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)

        writeMessage(
            ["method": "account/read", "id": 2, "params": ["refreshToken": forceRefresh]],
            to: input.fileHandleForWriting
        )
        guard let accountResponse = inbox.waitForResponse(id: 2, deadline: deadline) else {
            return .unavailable(reason: "Codex reset account verification timed out.")
        }
        if let failure = CodexUsageAppServerResponseAccumulator.classifyFailure(accountResponse) {
            return mapUsageFailure(failure)
        }
        guard let accountResult = accountResponse["result"] as? [String: Any],
              let account = accountResult["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else {
            return .requiresLogin(reason: "Codex could not find a usable ChatGPT login for this account.")
        }
        let accountEmail = account["email"] as? String
        if let expectedAccountEmail,
           accountEmail?.caseInsensitiveCompare(expectedAccountEmail) != .orderedSame {
            return .unavailable(
                reason: "Codex returned a different account before reset redemption."
            )
        }

        writeMessage(
            [
                "method": "account/rateLimitResetCredit/consume",
                "id": 3,
                "params": ["idempotencyKey": idempotencyKey]
            ],
            to: input.fileHandleForWriting
        )
        guard let consumeResponse = inbox.waitForResponse(id: 3, deadline: deadline) else {
            return .unavailable(
                reason: "Codex did not confirm whether the reset was used. Retry will safely reuse this attempt."
            )
        }
        if consumeResponse["error"] != nil {
            let normalized = normalizedError(consumeResponse)
            if normalized.contains("method not found")
                || normalized.contains("unsupported")
                || normalized.contains("-32601") {
                return .unsupported(
                    reason: "This Codex version does not support earned reset redemption. Update Codex and try again."
                )
            }
            if let failure = CodexUsageAppServerResponseAccumulator.classifyFailure(consumeResponse) {
                return mapUsageFailure(failure)
            }
            return .unavailable(reason: "Codex could not use an earned reset right now.")
        }
        guard let consumeResult = consumeResponse["result"] as? [String: Any],
              let rawOutcome = consumeResult["outcome"] as? String,
              let outcome = CodexResetRedemptionOutcome(rawValue: rawOutcome) else {
            return .unavailable(reason: "Codex returned an unreadable reset response.")
        }

        writeMessage(
            ["method": "account/rateLimits/read", "id": 4],
            to: input.fileHandleForWriting
        )
        guard let rateResponse = inbox.waitForResponse(id: 4, deadline: deadline) else {
            return .completedWithoutRefresh(
                accountEmail: accountEmail,
                outcome: outcome,
                reason: "The reset result was confirmed, but refreshed limits were not returned."
            )
        }
        if let failure = CodexUsageAppServerResponseAccumulator.classifyFailure(rateResponse) {
            let reason: String
            switch failure {
            case .requiresLogin(let value), .unavailable(let value):
                reason = value
            case .success:
                reason = "Codex could not refresh limits after using the reset."
            }
            return .completedWithoutRefresh(
                accountEmail: accountEmail,
                outcome: outcome,
                reason: reason
            )
        }
        guard let result = rateResponse["result"] as? [String: Any],
              let rateLimits = CodexUsageAppServerResponseAccumulator.parseRateLimits(result) else {
            return .completedWithoutRefresh(
                accountEmail: accountEmail,
                outcome: outcome,
                reason: "Codex confirmed the reset but returned unreadable refreshed limits."
            )
        }
        return .success(accountEmail: accountEmail, outcome: outcome, rateLimits: rateLimits)
    }

    private func configuredProcess(executableURL: URL, codexHome: URL) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "--stdio",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "analytics.enabled=false",
            "-c", "check_for_update_on_startup=false"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        environment["RUST_LOG"] = "error"
        process.environment = environment
        return process
    }

    private func writeMessage(_ message: [String: Any], to handle: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private func normalizedError(_ response: [String: Any]) -> String {
        guard let error = response["error"],
              let data = try? JSONSerialization.data(withJSONObject: error, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).lowercased()
    }

    private func mapUsageFailure(_ failure: CodexUsageAppServerOutcome) -> CodexResetAppServerOutcome {
        switch failure {
        case .requiresLogin(let reason):
            return .requiresLogin(reason: reason)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .success:
            return .unavailable(reason: "Codex returned an unexpected reset response.")
        }
    }
}
