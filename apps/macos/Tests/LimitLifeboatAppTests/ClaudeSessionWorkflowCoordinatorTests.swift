import Foundation
import LimitLifeboatAppWorkflows
import LimitLifeboatCore
import XCTest

final class ClaudeSessionWorkflowCoordinatorTests: XCTestCase {
    func testProductionAdmissionPolicyKeepsScheduledReadAheadOfMutation() {
        XCTAssertFalse(
            ClaudeSessionOperationAdmissionPolicy.allowsMutation(
                scheduledReadInProgress: true,
                reconciliationInProgress: false,
                mutationInProgress: false
            )
        )
        XCTAssertFalse(
            ClaudeSessionOperationAdmissionPolicy.allowsMutation(
                scheduledReadInProgress: false,
                reconciliationInProgress: true,
                mutationInProgress: false
            )
        )
        XCTAssertFalse(
            ClaudeSessionOperationAdmissionPolicy.allowsMutation(
                scheduledReadInProgress: false,
                reconciliationInProgress: false,
                mutationInProgress: true
            )
        )
        XCTAssertTrue(
            ClaudeSessionOperationAdmissionPolicy.allowsMutation(
                scheduledReadInProgress: false,
                reconciliationInProgress: false,
                mutationInProgress: false
            )
        )
    }

    func testDuplicateRetryRequestsForSameProfileCoalesce() async {
        let profile = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Claude Team",
            generation: 1
        )
        let resolver = FakeClaudeSessionProfileResolver(profiles: [profile])
        let retryGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(retryGate: retryGate)
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials
        )

        let first = await coordinator.enqueueRetry(profileID: profile.id)
        await retryGate.waitUntilEntered()
        let duplicate = await coordinator.enqueueRetry(profileID: profile.id)

        let inFlightCount = await coordinator.inFlightRetryCount
        XCTAssertEqual(inFlightCount, 1)

        await retryGate.release()
        let firstOutcome = await first.value
        let duplicateOutcome = await duplicate.value

        XCTAssertEqual(firstOutcome, duplicateOutcome)
        XCTAssertEqual(firstOutcome.status, .completed)
        let invocations = await credentials.recordedRetryInvocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.profile, profile)
        XCTAssertEqual(invocations.first?.intent, .userRetry)
    }

    func testScheduledReadFinishesBeforeQueuedRetryReResolvesProfile() async {
        let profileID = UUID()
        let originallyQueued = ClaudeSessionProfileSnapshot(
            id: profileID,
            label: "Before reconciliation",
            generation: 1
        )
        let reconciled = ClaudeSessionProfileSnapshot(
            id: profileID,
            label: "After reconciliation",
            generation: 2
        )
        let events = TestEventRecorder()
        let resolver = FakeClaudeSessionProfileResolver(
            profiles: [originallyQueued],
            events: events
        )
        let scheduledGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(
            scheduledGate: scheduledGate,
            events: events
        )
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials
        )

        let scheduled = await coordinator.enqueueScheduledRead()
        await scheduledGate.waitUntilEntered()
        let retry = await coordinator.enqueueRetry(profileID: profileID)
        await resolver.upsert(reconciled)
        await scheduledGate.release()

        await scheduled.value
        let outcome = await retry.value

        XCTAssertEqual(outcome.resolvedProfile, reconciled)
        let invocations = await credentials.recordedRetryInvocations()
        XCTAssertEqual(invocations.map(\.profile), [reconciled])
        let recordedEvents = await events.values()
        XCTAssertEqual(
            recordedEvents,
            [
                "scheduled-start",
                "scheduled-finish",
                "resolve-profile-2",
                "retry-2"
            ]
        )
    }

    func testRemovalWhileRetryIsQueuedReturnsDeterministicUnavailableOutcome() async {
        let profile = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Removed account",
            generation: 8
        )
        let fixedNow = Date(timeIntervalSince1970: 1_900_000_000)
        let resolver = FakeClaudeSessionProfileResolver(profiles: [profile])
        let scheduledGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(
            scheduledGate: scheduledGate
        )
        let clock = FakeClaudeSessionClock(now: fixedNow)
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials,
            clock: clock
        )

        _ = await coordinator.enqueueScheduledRead()
        await scheduledGate.waitUntilEntered()
        let retry = await coordinator.enqueueRetry(profileID: profile.id)
        await resolver.remove(profileID: profile.id)
        await scheduledGate.release()

        let outcome = await retry.value

        XCTAssertEqual(outcome.origin, .row)
        XCTAssertEqual(outcome.requestedProfileID, profile.id)
        XCTAssertNil(outcome.resolvedProfile)
        XCTAssertEqual(outcome.resolvedAt, fixedNow)
        XCTAssertEqual(
            outcome.status,
            .noLongerAvailable(reason: "That Claude account is no longer available.")
        )
        let invocations = await credentials.recordedRetryInvocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testRemovalWhileUserSwitchIsQueuedStopsBeforeCredentialMutation() async {
        let target = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Switch target",
            generation: 4
        )
        let fixedNow = Date(timeIntervalSince1970: 1_950_000_000)
        let resolver = FakeClaudeSessionProfileResolver(profiles: [target])
        let scheduledGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(
            scheduledGate: scheduledGate
        )
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials,
            clock: FakeClaudeSessionClock(now: fixedNow)
        )

        _ = await coordinator.enqueueScheduledRead()
        await scheduledGate.waitUntilEntered()
        let userSwitch = await coordinator.enqueueUserSwitch(profileID: target.id)
        await resolver.remove(profileID: target.id)
        await scheduledGate.release()

        let outcome = await userSwitch.value

        XCTAssertEqual(outcome.origin, .userSwitch)
        XCTAssertEqual(outcome.requestedProfileID, target.id)
        XCTAssertNil(outcome.resolvedProfile)
        XCTAssertEqual(outcome.resolvedAt, fixedNow)
        XCTAssertEqual(
            outcome.status,
            .noLongerAvailable(
                reason: "That Claude account is no longer available to switch to."
            )
        )
        let switchInvocations = await credentials.recordedSwitchInvocations()
        XCTAssertTrue(switchInvocations.isEmpty)
    }

    func testNotificationRefreshIgnoresStalePayloadAndReResolvesActivePausedProfile() async {
        let originallyEmbedded = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Previously active",
            generation: 3
        )
        let activeWhenExecuted = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Currently paused",
            generation: 9
        )
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = FakeClaudeSessionProfileResolver(
            profiles: [originallyEmbedded, activeWhenExecuted],
            activePausedProfileID: originallyEmbedded.id
        )
        let scheduledGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(
            scheduledGate: scheduledGate
        )
        let clock = FakeClaudeSessionClock(now: fixedNow)
        let notifications = FakeClaudeSessionNotificationPublisher()
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials,
            clock: clock,
            notifications: notifications
        )

        _ = await coordinator.enqueueScheduledRead()
        await scheduledGate.waitUntilEntered()
        let notificationRefresh = await coordinator.enqueueNotificationRefresh(
            embeddedProfileID: originallyEmbedded.id
        )
        await resolver.setActivePausedProfileID(activeWhenExecuted.id)
        await scheduledGate.release()

        let outcome = await notificationRefresh.value

        XCTAssertEqual(outcome.origin, .notification)
        XCTAssertNil(outcome.requestedProfileID)
        XCTAssertEqual(outcome.resolvedProfile, activeWhenExecuted)
        XCTAssertEqual(outcome.status, .completed)
        XCTAssertEqual(outcome.resolvedAt, fixedNow)
        let invocations = await credentials.recordedRetryInvocations()
        XCTAssertEqual(invocations.map(\.profile), [activeWhenExecuted])
        XCTAssertEqual(invocations.map(\.intent), [.userRetry])

        let published = await notifications.recordedOutcomes()
        XCTAssertEqual(
            published,
            [
                ClaudeSessionNotificationOutcome(
                    embeddedProfileID: originallyEmbedded.id,
                    workflowOutcome: outcome
                )
            ]
        )
    }

    func testRowAndNotificationRetriesDoNotCoalesceAcrossTargetSemantics() async {
        let rowProfile = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Row target",
            generation: 1
        )
        let activeWhenNotificationRuns = ClaudeSessionProfileSnapshot(
            id: UUID(),
            label: "Current paused target",
            generation: 2
        )
        let resolver = FakeClaudeSessionProfileResolver(
            profiles: [rowProfile, activeWhenNotificationRuns],
            activePausedProfileID: rowProfile.id
        )
        let scheduledGate = AsyncSuspensionGate()
        let credentials = FakeClaudeSessionCredentialOperations(
            scheduledGate: scheduledGate
        )
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials
        )

        _ = await coordinator.enqueueScheduledRead()
        await scheduledGate.waitUntilEntered()
        let rowRetry = await coordinator.enqueueRetry(profileID: rowProfile.id)
        let notificationRetry = await coordinator.enqueueNotificationRefresh(
            embeddedProfileID: rowProfile.id
        )
        let inFlightCount = await coordinator.inFlightRetryCount
        XCTAssertEqual(inFlightCount, 2)

        await resolver.setActivePausedProfileID(activeWhenNotificationRuns.id)
        await scheduledGate.release()

        let rowOutcome = await rowRetry.value
        let notificationOutcome = await notificationRetry.value
        XCTAssertEqual(rowOutcome.resolvedProfile, rowProfile)
        XCTAssertEqual(
            notificationOutcome.resolvedProfile,
            activeWhenNotificationRuns
        )
        let invocations = await credentials.recordedRetryInvocations()
        XCTAssertEqual(
            invocations.map(\.profile),
            [rowProfile, activeWhenNotificationRuns]
        )
        XCTAssertEqual(invocations.map(\.intent), [.userRetry, .userRetry])
    }

    func testNotificationWithoutCurrentPausedProfilePublishesNoLongerNeeded() async {
        let embeddedProfileID = UUID()
        let fixedNow = Date(timeIntervalSince1970: 2_100_000_000)
        let resolver = FakeClaudeSessionProfileResolver(profiles: [])
        let credentials = FakeClaudeSessionCredentialOperations()
        let notifications = FakeClaudeSessionNotificationPublisher()
        let coordinator = makeCoordinator(
            resolver: resolver,
            credentials: credentials,
            clock: FakeClaudeSessionClock(now: fixedNow),
            notifications: notifications
        )

        let outcome = await coordinator.refreshFromNotification(
            embeddedProfileID: embeddedProfileID
        )

        XCTAssertEqual(
            outcome.status,
            .noLongerAvailable(
                reason: "The paused Claude account was removed, switched, or has already recovered."
            )
        )
        XCTAssertEqual(outcome.resolvedAt, fixedNow)
        let published = await notifications.recordedOutcomes()
        XCTAssertEqual(published.first?.embeddedProfileID, embeddedProfileID)
        XCTAssertEqual(published.first?.workflowOutcome, outcome)
        XCTAssertEqual(published.count, 1)
    }

    private func makeCoordinator(
        resolver: FakeClaudeSessionProfileResolver,
        credentials: FakeClaudeSessionCredentialOperations,
        clock: any ClaudeSessionClock = FakeClaudeSessionClock(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ),
        notifications: any ClaudeSessionNotificationPublishing = FakeClaudeSessionNotificationPublisher()
    ) -> ClaudeSessionWorkflowCoordinator {
        ClaudeSessionWorkflowCoordinator(
            profiles: resolver,
            credentials: credentials,
            clock: clock,
            notifications: notifications
        )
    }
}

private actor AsyncSuspensionGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor TestEventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor FakeClaudeSessionProfileResolver: ClaudeSessionProfileResolving {
    private var profiles: [UUID: ClaudeSessionProfileSnapshot]
    private var activePausedProfileID: UUID?
    private let events: TestEventRecorder?

    init(
        profiles: [ClaudeSessionProfileSnapshot],
        activePausedProfileID: UUID? = nil,
        events: TestEventRecorder? = nil
    ) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.activePausedProfileID = activePausedProfileID
        self.events = events
    }

    func profile(id: UUID) async -> ClaudeSessionProfileSnapshot? {
        let profile = profiles[id]
        if let profile {
            await events?.append("resolve-profile-\(profile.generation)")
        }
        return profile
    }

    func activePausedProfile() async -> ClaudeSessionProfileSnapshot? {
        guard let activePausedProfileID else { return nil }
        let profile = profiles[activePausedProfileID]
        if let profile {
            await events?.append("resolve-active-paused-\(profile.generation)")
        }
        return profile
    }

    func upsert(_ profile: ClaudeSessionProfileSnapshot) {
        profiles[profile.id] = profile
    }

    func remove(profileID: UUID) {
        profiles[profileID] = nil
        if activePausedProfileID == profileID {
            activePausedProfileID = nil
        }
    }

    func setActivePausedProfileID(_ profileID: UUID?) {
        activePausedProfileID = profileID
    }
}

private struct RecordedRetryInvocation: Sendable, Equatable {
    var profile: ClaudeSessionProfileSnapshot
    var intent: ClaudeRotationIntent
}

private struct RecordedSwitchInvocation: Sendable, Equatable {
    var profile: ClaudeSessionProfileSnapshot
    var intent: ClaudeRotationIntent
}

private actor FakeClaudeSessionCredentialOperations: ClaudeSessionCredentialOperating {
    private let scheduledGate: AsyncSuspensionGate?
    private let retryGate: AsyncSuspensionGate?
    private let events: TestEventRecorder?
    private let retryResult: ClaudeSessionCredentialOperationResult
    private var retryInvocations: [RecordedRetryInvocation] = []
    private var switchInvocations: [RecordedSwitchInvocation] = []

    init(
        scheduledGate: AsyncSuspensionGate? = nil,
        retryGate: AsyncSuspensionGate? = nil,
        events: TestEventRecorder? = nil,
        retryResult: ClaudeSessionCredentialOperationResult = .completed
    ) {
        self.scheduledGate = scheduledGate
        self.retryGate = retryGate
        self.events = events
        self.retryResult = retryResult
    }

    func performScheduledRead() async {
        await events?.append("scheduled-start")
        await scheduledGate?.enterAndWait()
        await events?.append("scheduled-finish")
    }

    func performRetry(
        for profile: ClaudeSessionProfileSnapshot,
        intent: ClaudeRotationIntent
    ) async -> ClaudeSessionCredentialOperationResult {
        retryInvocations.append(
            RecordedRetryInvocation(profile: profile, intent: intent)
        )
        await events?.append("retry-\(profile.generation)")
        await retryGate?.enterAndWait()
        return retryResult
    }

    func performSwitch(
        to profile: ClaudeSessionProfileSnapshot,
        intent: ClaudeRotationIntent
    ) async -> ClaudeSessionCredentialOperationResult {
        switchInvocations.append(
            RecordedSwitchInvocation(profile: profile, intent: intent)
        )
        await events?.append("switch-\(profile.generation)")
        return retryResult
    }

    func recordedRetryInvocations() -> [RecordedRetryInvocation] {
        retryInvocations
    }

    func recordedSwitchInvocations() -> [RecordedSwitchInvocation] {
        switchInvocations
    }
}

private actor FakeClaudeSessionClock: ClaudeSessionClock {
    private var currentNow: Date

    init(now: Date) {
        currentNow = now
    }

    func now() async -> Date {
        currentNow
    }

    func setNow(_ now: Date) {
        currentNow = now
    }
}

private actor FakeClaudeSessionNotificationPublisher: ClaudeSessionNotificationPublishing {
    private var outcomes: [ClaudeSessionNotificationOutcome] = []

    func publish(_ outcome: ClaudeSessionNotificationOutcome) async {
        outcomes.append(outcome)
    }

    func recordedOutcomes() -> [ClaudeSessionNotificationOutcome] {
        outcomes
    }
}
