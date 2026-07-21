import Foundation
import LimitLifeboatCore

/// The app-owned portion of a Claude profile needed to re-resolve a queued
/// credential operation. `generation` lets the app discard a value captured
/// before another login, switch, or credential reconciliation completed.
public struct ClaudeSessionProfileSnapshot: Sendable, Equatable {
    public var id: UUID
    public var label: String
    public var generation: UInt64

    public init(id: UUID, label: String, generation: UInt64 = 0) {
        self.id = id
        self.label = label
        self.generation = generation
    }
}

/// Resolves profiles from current app state. Implementations must not return a
/// value captured when the request was enqueued.
public protocol ClaudeSessionProfileResolving: Sendable {
    func profile(id: UUID) async -> ClaudeSessionProfileSnapshot?
    func activePausedProfile() async -> ClaudeSessionProfileSnapshot?
}

public enum ClaudeSessionCredentialOperationResult: Sendable, Equatable {
    case completed
    case needsLogin(reason: String)
    case authorizationRequired(reason: String)
    case deferred(reason: String)
    case failed(reason: String)
}

/// Credential work is injected so the coordinator can be exercised without
/// Keychain access or a token endpoint. The two methods deliberately keep the
/// scheduled read-only path distinct from an explicit Retry rotation intent.
public protocol ClaudeSessionCredentialOperating: Sendable {
    func performScheduledRead() async
    func performRetry(
        for profile: ClaudeSessionProfileSnapshot,
        intent: ClaudeRotationIntent
    ) async -> ClaudeSessionCredentialOperationResult
    func performSwitch(
        to profile: ClaudeSessionProfileSnapshot,
        intent: ClaudeRotationIntent
    ) async -> ClaudeSessionCredentialOperationResult
}

public protocol ClaudeSessionClock: Sendable {
    func now() async -> Date
}

public struct SystemClaudeSessionClock: ClaudeSessionClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }
}

public enum ClaudeSessionWorkflowStatus: Sendable, Equatable {
    case completed
    case needsLogin(reason: String)
    case authorizationRequired(reason: String)
    case deferred(reason: String)
    case failed(reason: String)
    case noLongerAvailable(reason: String)
}

public enum ClaudeSessionWorkflowOrigin: String, Sendable, Equatable {
    case row
    case notification
    case userSwitch
}

public struct ClaudeSessionWorkflowOutcome: Sendable, Equatable {
    public var origin: ClaudeSessionWorkflowOrigin
    public var requestedProfileID: UUID?
    public var resolvedProfile: ClaudeSessionProfileSnapshot?
    public var status: ClaudeSessionWorkflowStatus
    public var resolvedAt: Date

    public init(
        origin: ClaudeSessionWorkflowOrigin,
        requestedProfileID: UUID?,
        resolvedProfile: ClaudeSessionProfileSnapshot?,
        status: ClaudeSessionWorkflowStatus,
        resolvedAt: Date
    ) {
        self.origin = origin
        self.requestedProfileID = requestedProfileID
        self.resolvedProfile = resolvedProfile
        self.status = status
        self.resolvedAt = resolvedAt
    }
}

public struct ClaudeSessionNotificationOutcome: Sendable, Equatable {
    /// Stale payload context retained only for diagnostics. It is never used as
    /// the credential target.
    public var embeddedProfileID: UUID?
    public var workflowOutcome: ClaudeSessionWorkflowOutcome

    public init(
        embeddedProfileID: UUID?,
        workflowOutcome: ClaudeSessionWorkflowOutcome
    ) {
        self.embeddedProfileID = embeddedProfileID
        self.workflowOutcome = workflowOutcome
    }
}

public protocol ClaudeSessionNotificationPublishing: Sendable {
    func publish(_ outcome: ClaudeSessionNotificationOutcome) async
}

public struct DiscardingClaudeSessionNotificationPublisher: ClaudeSessionNotificationPublishing {
    public init() {}

    public func publish(_ outcome: ClaudeSessionNotificationOutcome) async {}
}

/// Retry flights deliberately distinguish a row's stable profile target from
/// a notification's provider-scoped active target. Sharing this key with the
/// executable keeps production coalescing aligned with the injected app-level
/// race tests.
public enum ClaudeSessionRetryFlightKey: Hashable, Sendable {
    case profile(UUID)
    case activePausedNotification(Provider)
}

/// Shared admission rule used by the production app and the injected workflow
/// tests. A credential mutation queues behind both halves of a scheduled read:
/// the stability-confirmation probe and the provider's usage fetch.
public enum ClaudeSessionOperationAdmissionPolicy {
    public static func allowsMutation(
        scheduledReadInProgress: Bool,
        reconciliationInProgress: Bool,
        mutationInProgress: Bool
    ) -> Bool {
        !scheduledReadInProgress
            && !reconciliationInProgress
            && !mutationInProgress
    }
}

/// Serializes app-level Claude reads and explicit credential operations.
///
/// Scheduled reads remain read-only. A Retry queued behind any provider
/// operation waits for it, then resolves the profile again from current app
/// state. Duplicate Retry requests for the same profile share one task.
public actor ClaudeSessionWorkflowCoordinator {
    private struct WorkflowFlight {
        var id: UUID
        var task: Task<ClaudeSessionWorkflowOutcome, Never>
    }

    private let profiles: any ClaudeSessionProfileResolving
    private let credentials: any ClaudeSessionCredentialOperating
    private let clock: any ClaudeSessionClock
    private let notifications: any ClaudeSessionNotificationPublishing

    /// Every provider operation is appended to this tail. A completed task is
    /// cheap to await and retaining it avoids a mutation gap between enqueue
    /// calls that arrive in adjacent actor turns.
    private var providerOperationTail: Task<Void, Never>?
    private var retryFlights: [ClaudeSessionRetryFlightKey: WorkflowFlight] = [:]
    private var switchFlights: [UUID: WorkflowFlight] = [:]

    public init(
        profiles: any ClaudeSessionProfileResolving,
        credentials: any ClaudeSessionCredentialOperating,
        clock: any ClaudeSessionClock = SystemClaudeSessionClock(),
        notifications: any ClaudeSessionNotificationPublishing = DiscardingClaudeSessionNotificationPublisher()
    ) {
        self.profiles = profiles
        self.credentials = credentials
        self.clock = clock
        self.notifications = notifications
    }

    /// Enqueues a scheduled read without allowing it to inherit a Retry intent.
    /// Returning the task makes ordering deterministic for app orchestration and
    /// app-level tests.
    public func enqueueScheduledRead() -> Task<Void, Never> {
        let predecessor = providerOperationTail
        let credentials = credentials
        let task = Task {
            await predecessor?.value
            await credentials.performScheduledRead()
        }
        providerOperationTail = task
        return task
    }

    public func performScheduledRead() async {
        let task = enqueueScheduledRead()
        await task.value
    }

    /// Enqueues or joins a row Retry for one profile. The resolver is called
    /// only after earlier provider operations have finished.
    public func enqueueRetry(
        profileID: UUID
    ) -> Task<ClaudeSessionWorkflowOutcome, Never> {
        enqueueRetryFlight(
            key: .profile(profileID),
            origin: .row,
            requestedProfileID: profileID,
            embeddedProfileID: nil
        )
    }

    public func retry(profileID: UUID) async -> ClaudeSessionWorkflowOutcome {
        let task = enqueueRetry(profileID: profileID)
        return await task.value
    }

    /// A notification payload can be arbitrarily stale. The embedded UUID is
    /// retained for the outcome only; execution re-resolves the active paused
    /// account after all earlier provider work has completed.
    public func enqueueNotificationRefresh(
        embeddedProfileID: UUID?
    ) -> Task<ClaudeSessionWorkflowOutcome, Never> {
        enqueueRetryFlight(
            key: .activePausedNotification(.claude),
            origin: .notification,
            requestedProfileID: nil,
            embeddedProfileID: embeddedProfileID
        )
    }

    public func refreshFromNotification(
        embeddedProfileID: UUID?
    ) async -> ClaudeSessionWorkflowOutcome {
        let task = enqueueNotificationRefresh(embeddedProfileID: embeddedProfileID)
        return await task.value
    }

    public var inFlightRetryCount: Int {
        retryFlights.count
    }

    /// Enqueues or joins a user-clicked switch. The target is reloaded after
    /// earlier provider work; removal wins without calling the credential
    /// operation. Automatic switches intentionally use a separate app path so
    /// they can never inherit this user-authorized rotation intent.
    public func enqueueUserSwitch(
        profileID: UUID
    ) -> Task<ClaudeSessionWorkflowOutcome, Never> {
        if let existing = switchFlights[profileID] {
            return existing.task
        }

        let predecessor = providerOperationTail
        let profiles = profiles
        let credentials = credentials
        let clock = clock
        let flightID = UUID()
        let task = Task {
            await predecessor?.value
            guard let profile = await profiles.profile(id: profileID) else {
                return ClaudeSessionWorkflowOutcome(
                    origin: .userSwitch,
                    requestedProfileID: profileID,
                    resolvedProfile: nil,
                    status: .noLongerAvailable(
                        reason: "That Claude account is no longer available to switch to."
                    ),
                    resolvedAt: await clock.now()
                )
            }

            let result = await credentials.performSwitch(
                to: profile,
                intent: .userInitiatedSwitch
            )
            return ClaudeSessionWorkflowOutcome(
                origin: .userSwitch,
                requestedProfileID: profileID,
                resolvedProfile: profile,
                status: Self.workflowStatus(for: result),
                resolvedAt: await clock.now()
            )
        }

        switchFlights[profileID] = WorkflowFlight(id: flightID, task: task)
        providerOperationTail = Task {
            _ = await task.value
        }
        Task { [weak self] in
            _ = await task.value
            await self?.finishSwitchFlight(profileID: profileID, id: flightID)
        }
        return task
    }

    public func switchToProfile(
        profileID: UUID
    ) async -> ClaudeSessionWorkflowOutcome {
        let task = enqueueUserSwitch(profileID: profileID)
        return await task.value
    }

    private func enqueueRetryFlight(
        key: ClaudeSessionRetryFlightKey,
        origin: ClaudeSessionWorkflowOrigin,
        requestedProfileID: UUID?,
        embeddedProfileID: UUID?
    ) -> Task<ClaudeSessionWorkflowOutcome, Never> {
        if let existing = retryFlights[key] {
            return existing.task
        }

        let predecessor = providerOperationTail
        let profiles = profiles
        let credentials = credentials
        let clock = clock
        let notifications = notifications
        let flightID = UUID()
        let task = Task {
            await predecessor?.value

            let resolvedProfile: ClaudeSessionProfileSnapshot?
            switch key {
            case .profile(let profileID):
                resolvedProfile = await profiles.profile(id: profileID)
            case .activePausedNotification:
                resolvedProfile = await profiles.activePausedProfile()
            }

            let outcome: ClaudeSessionWorkflowOutcome
            if let resolvedProfile {
                let operationResult = await credentials.performRetry(
                    for: resolvedProfile,
                    intent: .userRetry
                )
                outcome = ClaudeSessionWorkflowOutcome(
                    origin: origin,
                    requestedProfileID: requestedProfileID,
                    resolvedProfile: resolvedProfile,
                    status: Self.workflowStatus(for: operationResult),
                    resolvedAt: await clock.now()
                )
            } else {
                let reason = origin == .notification
                    ? "The paused Claude account was removed, switched, or has already recovered."
                    : "That Claude account is no longer available."
                outcome = ClaudeSessionWorkflowOutcome(
                    origin: origin,
                    requestedProfileID: requestedProfileID,
                    resolvedProfile: nil,
                    status: .noLongerAvailable(reason: reason),
                    resolvedAt: await clock.now()
                )
            }

            if origin == .notification {
                await notifications.publish(
                    ClaudeSessionNotificationOutcome(
                        embeddedProfileID: embeddedProfileID,
                        workflowOutcome: outcome
                    )
                )
            }
            return outcome
        }

        retryFlights[key] = WorkflowFlight(id: flightID, task: task)
        providerOperationTail = Task {
            _ = await task.value
        }
        Task { [weak self] in
            _ = await task.value
            await self?.finishRetryFlight(key: key, id: flightID)
        }
        return task
    }

    private func finishRetryFlight(key: ClaudeSessionRetryFlightKey, id: UUID) {
        guard retryFlights[key]?.id == id else { return }
        retryFlights[key] = nil
    }

    private func finishSwitchFlight(profileID: UUID, id: UUID) {
        guard switchFlights[profileID]?.id == id else { return }
        switchFlights[profileID] = nil
    }

    private static func workflowStatus(
        for result: ClaudeSessionCredentialOperationResult
    ) -> ClaudeSessionWorkflowStatus {
        switch result {
        case .completed:
            return .completed
        case .needsLogin(let reason):
            return .needsLogin(reason: reason)
        case .authorizationRequired(let reason):
            return .authorizationRequired(reason: reason)
        case .deferred(let reason):
            return .deferred(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}
