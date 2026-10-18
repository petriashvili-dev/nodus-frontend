import Foundation
import SwiftData
import os

/// Talks to the server and applies responses through `LocalStore`, off the
/// main actor (docs/03-outbox-and-sync.md).
///
/// - `flushOutbox` sends queued operations in order per entity, with the
///   same `Idempotency-Key` on every retry and a new operation after a
///   business error.
/// - `pull` applies a snapshot or Delta Sync pages; changes and the cursor
///   are saved in one transaction.
/// - `refreshFeed` caches `GET /feed` (what the thread shows) and the
///   occurrence window (what notifications are planned from).
actor SyncEngine: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor

    nonisolated struct Events: Sendable {
        /// A profile arrived (sync `user`, consent response).
        var profile: @Sendable (UserProfileDTO) -> Void = { _ in }
        /// AI access was refused; the profile should be reloaded.
        var accessRefused: @Sendable () -> Void = {}
    }

    private let api: APIClient
    private let session: AuthSession
    private let events: Events
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.nodus", category: "Sync")

    private let store: any LocalStore

    init(
        container: ModelContainer,
        api: APIClient,
        session: AuthSession,
        events: Events = Events(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        store = SwiftDataLocalStore(context: context)
        self.api = api
        self.session = session
        self.events = events
        self.now = now
    }

    // MARK: - Cycle

    nonisolated enum CycleResult: Sendable, Equatable {
        case completed
        case offline
        case sessionEnded
    }

    /// One full cycle: account check, Outbox, pull, feed.
    func runCycle(timeZone: TimeZone) async -> CycleResult {
        do {
            try await prepareAccount()
            try queueLegacyNodesIfNeeded()
            try queueTimeZoneIfNeeded(timeZone)
            guard try await flushOutbox() else { return .offline }
            try await pull()
            try await refreshFeed(timeZone: timeZone)
            return .completed
        } catch let error as APIError where error.isOffline {
            return .offline
        } catch APIError.sessionEnded {
            return .sessionEnded
        } catch {
            logger.error("Sync cycle failed: \(String(describing: type(of: error)), privacy: .public)")
            return .offline
        }
    }

    // MARK: - Account

    /// A different account than the one this cache belongs to (recovery, a
    /// replaced anonymous account) cannot reuse the cursor or the queue.
    /// The device's knots are kept and uploaded again to the new account.
    private func prepareAccount() async throws {
        _ = try await session.accessToken()
        guard let userId = await session.userId else { return }
        let metadata = try metadata()
        guard metadata.userId != userId else { return }
        if metadata.userId != nil {
            logger.notice("Account changed; the local cache is re-uploaded")
            try store.deleteAll(OutboxOperation.self)
            try store.deleteAll(ServerOccurrence.self)
            for node in try store.fetch(ReminderNode.self) {
                node.serverVersion = 0
                node.ownerId = nil
                node.memberCount = 1
            }
            metadata.cursor = nil
            metadata.didQueueLegacyNodes = false
            metadata.sentTimeZone = nil
        }
        metadata.userId = userId
        try store.save()
    }

    /// Knots saved before the backend existed (or re-uploaded after an
    /// account change) have no server copy yet: queue their creation once,
    /// keeping their ids so the server and the device agree on identity.
    private func queueLegacyNodesIfNeeded() throws {
        let metadata = try metadata()
        guard !metadata.didQueueLegacyNodes else { return }
        let queued = Set(try store.fetch(OutboxOperation.self).compactMap(\.entityId))
        let nodes = try store.fetch(ReminderNode.self).filter { $0.serverVersion == 0 }
        let moment = now()
        for node in nodes where !queued.contains(node.id) {
            if node.timeZoneIdentifier.isEmpty {
                node.timeZoneIdentifier = TimeZone.current.identifier
            }
            let body = NodeMapper.createBody(id: node.id, fields: Self.fields(of: node))
            store.insert(OutboxOperation(
                kind: .createNode, method: .post, path: "nodes",
                body: try APICoding.encoder.encode(body), entityId: node.id, now: moment
            ))
            // A completed one-time knot stays completed; the server accepts
            // completion moments up to 30 days old.
            if !node.isRepeating, node.status == .completed {
                let completedAt = max(node.completedAt ?? moment, moment.addingTimeInterval(-29 * 24 * 60 * 60))
                store.insert(OutboxOperation(
                    kind: .untie, method: .put, path: "nodes/\(node.id.uuidString)/occurrences/once/untie",
                    body: try APICoding.encoder.encode(UntieBody(completedAt: completedAt)),
                    entityId: node.id, now: moment
                ))
            }
        }
        metadata.didQueueLegacyNodes = true
        try store.save()
    }

    /// The device zone changed (a flight, the first launch): nodes are
    /// moved to it on the server, keeping local times. Queued after any
    /// pending edits so they are sent first.
    private func queueTimeZoneIfNeeded(_ zone: TimeZone) throws {
        let metadata = try metadata()
        guard metadata.sentTimeZone != zone.identifier else { return }
        let existing = try store.fetch(OutboxOperation.self)
            .filter { $0.kind == .setTimezone && !$0.hasBeenSent }
        existing.forEach(store.delete)
        store.insert(OutboxOperation(
            kind: .setTimezone, method: .put, path: "me/timezone",
            body: try APICoding.encoder.encode(["timezone": zone.identifier]),
            entityId: nil, now: now()
        ))
        try store.save()
    }

    // MARK: - Outbox

    /// Sends everything that can be sent now. Returns `false` when the
    /// network is unavailable.
    @discardableResult
    func flushOutbox() async throws -> Bool {
        try resetInterruptedOperations()
        while let operation = try nextSendableOperation() {
            switch await send(operation) {
            case .sent, .rejected, .retryLater:
                // A postponed operation blocks only its own entity.
                continue
            case .offline:
                return false
            case .stop:
                return true
            }
        }
        return true
    }

    private enum SendOutcome {
        case sent
        case rejected
        case retryLater
        case offline
        /// The session ended; nothing can be sent until sign-in.
        case stop
    }

    /// An operation left `inFlight` by a crash is sent again with the same
    /// key; the server will not run it twice.
    private func resetInterruptedOperations() throws {
        let inFlight = OutboxOperation.Status.inFlight.rawValue
        let interrupted = try store.fetch(OutboxOperation.self).filter { $0.statusRaw == inFlight }
        guard !interrupted.isEmpty else { return }
        interrupted.forEach { $0.status = .pending }
        try store.save()
    }

    /// The oldest operation whose entity has nothing unfinished before it.
    private func nextSendableOperation() throws -> OutboxOperation? {
        let all = try store.fetch(OutboxOperation.self).sorted { $0.createdAt < $1.createdAt }
        let moment = now()
        var blockedEntities = Set<UUID>()
        for operation in all {
            switch operation.status {
            case .failed:
                continue
            case .blockedConflict:
                if let entity = operation.entityId { blockedEntities.insert(entity) }
                continue
            case .pending, .retryableFailure, .inFlight:
                if let entity = operation.entityId {
                    guard !blockedEntities.contains(entity) else { continue }
                    blockedEntities.insert(entity)
                }
                if operation.nextAttemptAt <= moment {
                    return operation
                }
            }
        }
        return nil
    }

    private func send(_ operation: OutboxOperation) async -> SendOutcome {
        do {
            try freezeExpectedVersion(operation)
            operation.status = .inFlight
            operation.hasBeenSent = true
            operation.attempts += 1
            try store.save()

            var query: [URLQueryItem] = []
            if operation.httpMethod == .delete, let version = operation.expectedVersion, operation.needsExpectedVersion {
                query.append(URLQueryItem(name: "expected_version", value: String(version)))
            }
            let request = APIRequest<EmptyResponse>(
                method: operation.httpMethod,
                path: operation.path,
                query: query,
                body: operation.body,
                idempotencyKey: operation.idempotencyKey
            )
            let (data, _) = try await api.data(request)
            try handleSuccess(of: operation, data: data)
            return .sent
        } catch let error as APIError {
            return handleFailure(of: operation, error: error)
        } catch {
            logger.error("Outbox operation \(operation.kindRaw, privacy: .public) failed locally")
            return markRetryable(operation, code: "local_error")
        }
    }

    /// `expected_version` is decided at the first send and then never
    /// changes: retries must repeat the exact body.
    private func freezeExpectedVersion(_ operation: OutboxOperation) throws {
        guard operation.needsExpectedVersion, !operation.hasBeenSent,
              operation.kind == .updateNode, let body = operation.body else { return }
        var update = try APICoding.decoder.decode(UpdateNodeBody.self, from: body)
        update.expectedVersion = operation.expectedVersion ?? 0
        operation.body = try APICoding.encoder.encode(update)
    }

    private func handleSuccess(of operation: OutboxOperation, data: Data) throws {
        switch operation.kind {
        case .createNode, .updateNode:
            let dto = try APICoding.decoder.decode(NodeDTO.self, from: data)
            advanceExpectedVersion(after: operation, to: dto.version)
            store.delete(operation)
            try apply(dto, respectingOverlay: true)
        case .untie, .retie:
            let state = try APICoding.decoder.decode(OccurrenceStateDTO.self, from: data)
            store.delete(operation)
            try apply(state)
        case .setTimezone:
            if let body = operation.body,
               let sent = try? APICoding.decoder.decode([String: String].self, from: body)["timezone"] {
                try metadata().sentTimeZone = sent
            }
            store.delete(operation)
        case .setAIConsent, .updateProfile:
            if let profile = try? APICoding.decoder.decode(UserProfileDTO.self, from: data) {
                events.profile(profile)
            }
            store.delete(operation)
        case .confirmAIDrafts:
            let response = try APICoding.decoder.decode(ConfirmDraftsResponse.self, from: data)
            store.delete(operation)
            try apply(response.job)
            for node in response.created?.nodes ?? [] {
                try apply(node, respectingOverlay: false)
            }
        case .cancelAIDrafts:
            if let job = try? APICoding.decoder.decode(AIDraftJobDTO.self, from: data) {
                try apply(job)
            }
            store.delete(operation)
        case .markSuggestionShown, .dismissSuggestion:
            if let suggestion = try? APICoding.decoder.decode(SuggestionDTO.self, from: data) {
                try apply(suggestion)
            }
            store.delete(operation)
        case .acceptSuggestion:
            if let response = try? APICoding.decoder.decode(AcceptSuggestionResponse.self, from: data) {
                try apply(response.suggestion)
                try apply(response.node, respectingOverlay: false)
            }
            store.delete(operation)
        case .confirmConnection:
            if let connection = try? APICoding.decoder.decode(ConnectionDTO.self, from: data) {
                try apply(connection)
            }
            store.delete(operation)
        case .addMember:
            if let node = try? APICoding.decoder.decode(NodeDTO.self, from: data) {
                store.delete(operation)
                try apply(node, respectingOverlay: true)
            } else {
                store.delete(operation)
            }
        case .removeConnection, .removeMember, .deleteNode, nil:
            store.delete(operation)
        }
        try store.save()
    }

    /// A chain of own edits: each next operation is based on the version
    /// the previous one produced.
    private func advanceExpectedVersion(after operation: OutboxOperation, to version: Int) {
        guard let entity = operation.entityId,
              let later = try? store.fetch(OutboxOperation.self).filter({ $0.entityId == entity }) else { return }
        for next in later where next.id != operation.id && next.needsExpectedVersion && !next.hasBeenSent {
            next.expectedVersion = version
        }
    }

    private func handleFailure(of operation: OutboxOperation, error: APIError) -> SendOutcome {
        if case .sessionEnded = error {
            operation.status = .pending
            try? store.save()
            return .stop
        }
        // Still unauthorized after a refresh: an auth hiccup, not a verdict
        // on the operation.
        if error.isRetryableWithSameKey || error.status == 401 {
            return markRetryable(operation, code: error.code ?? (error.isOffline ? "offline" : nil))
        }

        let code = error.code
        logger.notice("Outbox \(operation.kindRaw, privacy: .public) rejected: \(code ?? "-", privacy: .public)")
        do {
            switch (error.status, code) {
            case (409, "node_already_exists"):
                // The create already happened (a lost response); the next
                // pull brings the canonical node.
                store.delete(operation)
            case (409, "version_conflict"):
                try resolveConflict(operation, error: error)
            case (_, _) where operation.kind == .confirmAIDrafts && error.code != "job_not_ready":
                // `400` from node validation, `404` gone, `403` refused:
                // nothing was created.
                try rollBackConfirmation(operation)
                operation.status = .failed
                operation.lastErrorCode = code
                if error.code == "feature_not_available" || error.code == "ai_consent_required" {
                    events.accessRefused()
                }
            case (404, _):
                try rollBack(operation)
                store.delete(operation)
            case (403, "feature_not_available"), (403, "ai_consent_required"):
                operation.status = .failed
                operation.lastErrorCode = code
                events.accessRefused()
            default:
                // Validation, forbidden, quota, a reused key: the server
                // keeps this answer for the key, so the operation is final.
                if operation.kind == .acceptSuggestion,
                   let body = operation.body,
                   let accepted = try? APICoding.decoder.decode(AcceptSuggestionBody.self, from: body),
                   let optimisticNode = try node(id: accepted.node.id) {
                    store.delete(optimisticNode)
                }
                operation.status = .failed
                operation.lastErrorCode = code
                if let entity = operation.entityId, let node = try node(id: entity) {
                    node.syncIssueRaw = "rejected"
                }
            }
            try store.save()
        } catch {
            logger.error("Could not record an Outbox failure")
        }
        return .rejected
    }

    private func markRetryable(_ operation: OutboxOperation, code: String?) -> SendOutcome {
        operation.status = .retryableFailure
        operation.lastErrorCode = code
        // 1 s, 2 s, 4 s… up to 5 minutes, with jitter.
        let base = min(pow(2, Double(max(operation.attempts - 1, 0))), 300)
        operation.nextAttemptAt = now().addingTimeInterval(base * Double.random(in: 0.8...1.2))
        try? store.save()
        return code == "offline" ? .offline : .retryLater
    }

    /// `409 version_conflict`: the server's `current` becomes the canonical
    /// node. A private node gets the user's edit re-applied on top of it as
    /// a new operation; a shared node waits for the user to choose
    /// (docs/ios/02-outbox-and-errors.md, "Конфликт версий").
    private func resolveConflict(_ operation: OutboxOperation, error: APIError) throws {
        guard case let .server(_, _, body, _) = error,
              let current = try? APICoding.decoder.decode(VersionConflictBody.self, from: body).current else {
            // A race without `current`: pull, then try again as a new operation.
            try requeue(operation, expectedVersion: nil)
            return
        }
        let isShared = (current.members?.count ?? 1) > 1
        if isShared {
            try apply(current, respectingOverlay: false)
            operation.status = .blockedConflict
            operation.lastErrorCode = "version_conflict"
            if let node = try node(id: current.id) {
                node.syncIssueRaw = "conflict"
            }
        } else {
            try apply(current, respectingOverlay: true)
            try requeue(operation, expectedVersion: current.version)
        }
    }

    /// The same intent as a new operation with a new key.
    private func requeue(_ operation: OutboxOperation, expectedVersion: Int?) throws {
        let copy = OutboxOperation(
            kind: operation.kind ?? .updateNode,
            method: operation.httpMethod,
            path: operation.path,
            body: operation.body,
            entityId: operation.entityId,
            needsExpectedVersion: operation.needsExpectedVersion,
            now: operation.createdAt
        )
        copy.expectedVersion = expectedVersion ?? operation.expectedVersion
        if operation.kind == .updateNode, let body = operation.body {
            var update = try APICoding.decoder.decode(UpdateNodeBody.self, from: body)
            update.expectedVersion = nil
            copy.body = try APICoding.encoder.encode(update)
        }
        store.delete(operation)
        store.insert(copy)
    }

    /// `404`: the node or occurrence is gone on the server (deleted, access
    /// lost, the rule changed). Undo the local change; the pull that follows
    /// restores the truth.
    private func rollBack(_ operation: OutboxOperation) throws {
        guard let entity = operation.entityId else { return }
        switch operation.kind {
        case .untie, .retie:
            let key = Self.occurrenceKey(inPath: operation.path)
            let overlays = try store.fetch(ReminderOccurrenceState.self).filter { $0.reminderId == entity && $0.key == key }
            overlays.forEach(store.delete)
        case .updateNode, .deleteNode:
            if let node = try node(id: entity) {
                store.delete(node)
            }
            try deleteOccurrences(of: entity)
        default:
            break
        }
    }

    /// A rejected confirmation created nothing on the server: the knots shown
    /// optimistically go away and the drafts are ready to review again.
    private func rollBackConfirmation(_ operation: OutboxOperation) throws {
        guard let body = operation.body,
              let confirmation = try? APICoding.decoder.decode(ConfirmDraftsBody.self, from: body) else { return }
        for created in confirmation.nodes {
            if let node = try node(id: created.id) { store.delete(node) }
        }
        if let jobId = operation.entityId, let job = try draftJob(id: jobId), job.status == .confirmed {
            job.status = .ready
        }
    }

    // MARK: - Pull

    func pull() async throws {
        let metadata = try metadata()
        guard let cursor = metadata.cursor else {
            try await applySnapshot()
            return
        }
        var next = cursor
        while true {
            let page: SyncPageDTO
            do {
                page = try await api.send(APIRequest<SyncPageDTO>(
                    method: .get, path: "sync",
                    query: [URLQueryItem(name: "cursor", value: String(next)), URLQueryItem(name: "limit", value: "500")]
                ))
            } catch let error as APIError where error.status == 410 {
                try await applySnapshot()
                return
            }
            for change in page.changes.sorted(by: { $0.revision < $1.revision }) {
                try apply(change)
            }
            try self.metadata().cursor = page.nextCursor
            try self.metadata().lastSuccessAt = now()
            try store.save()
            next = page.nextCursor
            guard page.hasMore else { return }
        }
    }

    /// Replaces the server copy of everything, keeping pending operations
    /// and the changes they carry.
    private func applySnapshot() async throws {
        let snapshot = try await api.send(APIRequest<SnapshotDTO>(method: .get, path: "sync/snapshot"))
        let serverIds = Set(snapshot.nodes.map(\.id))
        let pendingEntities = try unfinishedEntities()
        for node in try store.fetch(ReminderNode.self)
        where node.serverVersion > 0 && !serverIds.contains(node.id) && !pendingEntities.contains(node.id) {
            try deleteOccurrences(of: node.id)
            store.delete(node)
        }
        for dto in snapshot.nodes {
            try apply(dto, respectingOverlay: true)
        }
        for job in snapshot.aiDraftJobs ?? [] {
            try apply(job)
        }
        if let connections = snapshot.connections {
            let ids = Set(connections.map(\.id))
            for stale in try store.fetch(Connection.self) where !ids.contains(stale.id) {
                store.delete(stale)
            }
            for connection in connections {
                try apply(connection)
            }
        }
        if let suggestions = snapshot.suggestions {
            let ids = Set(suggestions.map(\.id))
            for stale in try store.fetch(Suggestion.self) where !ids.contains(stale.id) {
                store.delete(stale)
            }
            for suggestion in suggestions {
                try apply(suggestion)
            }
        }
        if let jobs = snapshot.importJobs {
            let ids = Set(jobs.map(\.id))
            for stale in try store.fetch(ImportJob.self) where !ids.contains(stale.id) {
                store.delete(stale)
            }
            for job in jobs { try apply(job) }
        }
        if let user = snapshot.user {
            events.profile(user)
        }
        let metadata = try metadata()
        metadata.cursor = snapshot.cursor
        metadata.lastSuccessAt = now()
        try store.save()
    }

    private func apply(_ change: SyncChangeDTO) throws {
        switch (change.entityType, change.operation) {
        case ("node", "upsert"):
            if let dto = try change.data?.decode(NodeDTO.self) {
                try apply(dto, respectingOverlay: true)
            }
        case ("node", "delete"):
            // Deleted, or no longer shared with this user.
            guard let id = UUID(uuidString: change.entityId) else { return }
            if let node = try node(id: id), try !unfinishedEntities().contains(id) || node.isShared {
                store.delete(node)
            }
            try deleteOccurrences(of: id)
        case ("occurrence_state", "upsert"):
            if let state = try change.data?.decode(OccurrenceStateDTO.self) {
                try apply(state)
            }
        case ("user", "upsert"):
            if let profile = try change.data?.decode(UserProfileDTO.self) {
                events.profile(profile)
            }
        case ("connection", "upsert"):
            if let connection = try change.data?.decode(ConnectionDTO.self) {
                try apply(connection)
            }
        case ("connection", "delete"):
            if let id = UUID(uuidString: change.entityId), let connection = try connection(id: id) {
                store.delete(connection)
            }
        case ("ai_draft_job", "upsert"):
            if let job = try change.data?.decode(AIDraftJobDTO.self) {
                try apply(job)
            }
        case ("ai_draft_job", "delete"):
            if let id = UUID(uuidString: change.entityId), let job = try draftJob(id: id) {
                store.delete(job)
            }
        case ("suggestion", "upsert"):
            if let suggestion = try change.data?.decode(SuggestionDTO.self) {
                try apply(suggestion)
            }
        case ("suggestion", "delete"):
            if let id = UUID(uuidString: change.entityId), let suggestion = try suggestion(id: id) {
                store.delete(suggestion)
            }
        case ("import_job", "upsert"):
            if let job = try change.data?.decode(ImportJobDTO.self) {
                try apply(job)
            }
        case ("import_job", "delete"):
            if let id = UUID(uuidString: change.entityId), let job = try importJob(id: id) {
                store.delete(job)
            }
        default:
            // Unknown types from a newer server are skipped.
            break
        }
    }

    // MARK: - Applying server state

    /// Writes the canonical node. With pending local operations for it, the
    /// user's change stays on top (overlay) until those operations finish;
    /// only the server bookkeeping is updated.
    private func apply(_ dto: NodeDTO, respectingOverlay: Bool) throws {
        let hasOverlay = respectingOverlay ? try unfinishedEntities().contains(dto.id) : false
        let node: ReminderNode
        if let existing = try self.node(id: dto.id) {
            node = existing
        } else {
            let decoded = NodeMapper.decode(dto, now: now())
            node = ReminderNode(
                id: dto.id,
                title: decoded.fields.title,
                note: decoded.fields.note,
                scheduledAt: decoded.fields.scheduledAt,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            store.insert(node)
        }
        node.serverVersion = dto.version
        node.ownerId = dto.ownerId
        node.memberCount = max(dto.members?.count ?? 1, 1)
        node.membersData = dto.members.flatMap { try? APICoding.encoder.encode($0) }

        if !hasOverlay {
            let decoded = NodeMapper.decode(dto, now: now())
            node.title = decoded.fields.title
            node.note = decoded.fields.note
            node.scheduledAt = decoded.fields.scheduledAt
            node.originDate = decoded.fields.originDate
            node.repeatSchedule = decoded.fields.repeatSchedule
            node.timeZoneIdentifier = dto.timezone
            node.isUndated = decoded.isUndated
            node.status = decoded.status
            node.completedAt = decoded.completedAt
            node.updatedAt = dto.updatedAt
            node.syncIssueRaw = nil
        }

        if let occurrences = dto.occurrences {
            // The horizon of this node is replaced as a whole; feed entries
            // stay until the next feed refresh.
            let nodeId = dto.id
            let existing = try store.fetch(ServerOccurrence.self).filter { $0.nodeId == nodeId }
            let incoming = Set(occurrences.map { ServerOccurrence.identifier(nodeId: nodeId, key: $0.key) })
            for occurrence in existing where !incoming.contains(occurrence.id) {
                if occurrence.isInFeed {
                    occurrence.isInHorizon = false
                } else {
                    store.delete(occurrence)
                }
            }
            for occurrence in occurrences {
                try upsert(occurrence, inFeed: nil, inHorizon: true)
            }
        }
    }

    private func apply(_ state: OccurrenceStateDTO) throws {
        let id = ServerOccurrence.identifier(nodeId: state.nodeId, key: state.key)
        if let occurrence = try store.fetch(ServerOccurrence.self).first(where: { $0.id == id }) {
            occurrence.stateRaw = state.state
            occurrence.completedAt = state.completedAt
        }
        let nodeId = state.nodeId
        if state.key == "once", let node = try node(id: nodeId), try !unfinishedEntities().contains(nodeId) {
            node.status = state.state == "untied" ? .completed : .active
            node.completedAt = state.completedAt
        }
        // The server now knows; a local overlay with no operation behind it
        // would hide later changes from other devices.
        guard try !unfinishedEntities().contains(nodeId) else { return }
        let key = state.key
        let overlays = try store.fetch(ReminderOccurrenceState.self).filter { $0.reminderId == nodeId && $0.key == key }
        overlays.forEach(store.delete)
    }

    @discardableResult
    private func upsert(_ dto: OccurrenceDTO, inFeed: Bool?, inHorizon: Bool?) throws -> ServerOccurrence {
        let id = ServerOccurrence.identifier(nodeId: dto.nodeId, key: dto.key)
        let occurrence: ServerOccurrence
        if let existing = try store.fetch(ServerOccurrence.self).first(where: { $0.id == id }) {
            occurrence = existing
        } else {
            occurrence = ServerOccurrence(nodeId: dto.nodeId, key: dto.key)
            store.insert(occurrence)
        }
        occurrence.title = dto.title
        occurrence.note = dto.description
        occurrence.localDate = dto.date
        occurrence.localTime = dto.time
        occurrence.scheduledAt = dto.scheduledAt
        occurrence.years = dto.years
        occurrence.stateRaw = dto.state
        occurrence.completedAt = dto.completedAt
        occurrence.isPast = dto.isPast
        if let inFeed { occurrence.isInFeed = inFeed }
        if let inHorizon { occurrence.isInHorizon = inHorizon }
        return occurrence
    }

    // MARK: - Feed and occurrence window

    /// The thread is the server's feed: today's occurrences plus the next
    /// one of every series, however far away (AGENTS.md, rule 3).
    func refreshFeed(timeZone: TimeZone) async throws {
        let calendar = NodeMapper.calendar(in: timeZone)
        let today = now()
        let from = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let feedTo = calendar.date(byAdding: .day, value: 365, to: today) ?? today
        let windowTo = calendar.date(byAdding: .day, value: 45, to: today) ?? today
        let fromString = LocalDate.string(from: from, calendar: calendar)

        let feed = try await api.send(APIRequest<FeedDTO>(method: .get, path: "feed", query: [
            URLQueryItem(name: "from", value: fromString),
            URLQueryItem(name: "to", value: LocalDate.string(from: feedTo, calendar: calendar)),
        ]))
        let window = try await api.send(APIRequest<OccurrenceWindowDTO>(method: .get, path: "occurrences", query: [
            URLQueryItem(name: "from", value: fromString),
            URLQueryItem(name: "to", value: LocalDate.string(from: windowTo, calendar: calendar)),
        ]))

        for occurrence in try store.fetch(ServerOccurrence.self) {
            occurrence.isInFeed = false
            occurrence.isInHorizon = false
        }
        for item in feed.items {
            try upsert(item.occurrence, inFeed: true, inHorizon: nil)
        }
        for occurrence in window.occurrences {
            try upsert(occurrence, inFeed: nil, inHorizon: true)
        }
        try store.deleteAll(ServerOccurrence.self) { !$0.isInFeed && !$0.isInHorizon }
        try store.save()
    }

    /// Recovery, logout, deletion: everything of the previous account goes,
    /// including its unsent operations. `userId` is the account the empty
    /// cache now belongs to, so nothing is re-uploaded into it.
    func wipeLocalData(for userId: UUID?) throws {
        try store.deleteAll(OutboxOperation.self)
        try store.deleteAll(ServerOccurrence.self)
        try store.deleteAll(ReminderOccurrenceState.self)
        try store.deleteAll(ReminderOccurrenceOverride.self)
        try store.deleteAll(AIDraftJob.self)
        try store.deleteAll(Connection.self)
        try store.deleteAll(Suggestion.self)
        try store.deleteAll(ImportJob.self)
        try store.deleteAll(ReminderNode.self)
        let metadata = try metadata()
        metadata.cursor = nil
        metadata.userId = userId
        metadata.didQueueLegacyNodes = true
        metadata.sentTimeZone = nil
        metadata.lastSuccessAt = nil
        try store.save()
    }

    /// The last applied revision; SSE compares its signals with it.
    func currentCursor() -> Int? {
        try? metadata().cursor
    }

    /// When the earliest postponed operation may be sent again.
    func nextRetryDate() throws -> Date? {
        let retryable = OutboxOperation.Status.retryableFailure.rawValue
        let pending = OutboxOperation.Status.pending.rawValue
        return try store.fetch(OutboxOperation.self)
            .filter { $0.statusRaw == retryable || $0.statusRaw == pending }
            .min(by: { $0.nextAttemptAt < $1.nextAttemptAt })?.nextAttemptAt
    }

    // MARK: - Helpers

    nonisolated struct FailedOperation: Sendable, Identifiable {
        var id: UUID
        var kind: String
        var errorCode: String?
        var createdAt: Date
        var entityId: UUID?
    }

    func failedOperations() throws -> [FailedOperation] {
        let failed = OutboxOperation.Status.failed.rawValue
        return try store.fetch(OutboxOperation.self)
            .filter { $0.statusRaw == failed }
            .sorted { $0.createdAt > $1.createdAt }
            .map {
            FailedOperation(id: $0.id, kind: $0.kindRaw, errorCode: $0.lastErrorCode, createdAt: $0.createdAt, entityId: $0.entityId)
        }
    }

    func retryFailedOperation(_ id: UUID) throws {
        guard let operation = try store.fetch(OutboxOperation.self).first(where: { $0.id == id }),
              operation.status == .failed,
              operation.lastErrorCode != "feature_not_available",
              operation.lastErrorCode != "ai_consent_required" else { return }
        let next = OutboxOperation(
            kind: operation.kind ?? .updateNode,
            method: operation.httpMethod,
            path: operation.path,
            body: operation.body,
            entityId: operation.entityId,
            needsExpectedVersion: operation.needsExpectedVersion,
            now: now()
        )
        if let entity = operation.entityId, operation.needsExpectedVersion {
            let currentNode = try node(id: entity)
            next.expectedVersion = currentNode?.serverVersion ?? operation.expectedVersion
            if operation.kind == .updateNode, let body = operation.body {
                var update = try APICoding.decoder.decode(UpdateNodeBody.self, from: body)
                update.expectedVersion = nil
                next.body = try APICoding.encoder.encode(update)
            }
        }
        store.delete(operation)
        store.insert(next)
        if let entity = operation.entityId, let node = try node(id: entity) { node.syncIssueRaw = nil }
        try store.save()
    }

    func cancelFailedOperation(_ id: UUID) throws {
        guard let operation = try store.fetch(OutboxOperation.self).first(where: { $0.id == id }),
              operation.status == .failed else { return }
        if operation.kind == .createNode, let entity = operation.entityId, let node = try node(id: entity) {
            store.delete(node)
            try deleteOccurrences(of: entity)
        } else if operation.kind == .acceptSuggestion,
                  let body = operation.body,
                  let accepted = try? APICoding.decoder.decode(AcceptSuggestionBody.self, from: body),
                  let node = try node(id: accepted.node.id) {
            store.delete(node)
        } else if operation.kind == .confirmAIDrafts {
            try rollBackConfirmation(operation)
        } else {
            try rollBack(operation)
        }
        if let entity = operation.entityId, let node = try node(id: entity) { node.syncIssueRaw = nil }
        store.delete(operation)
        try store.save()
    }

    private func metadata() throws -> SyncMetadata {
        if let existing = try store.fetch(SyncMetadata.self).first {
            return existing
        }
        let created = SyncMetadata()
        store.insert(created)
        return created
    }

    private func connection(id: UUID) throws -> Connection? {
        try store.fetch(Connection.self).first(where: { $0.id == id })
    }

    private func apply(_ dto: ConnectionDTO) throws {
        guard dto.status != "removed" else {
            if let existing = try connection(id: dto.id) { store.delete(existing) }
            return
        }
        if let existing = try connection(id: dto.id) {
            existing.apply(dto)
        } else {
            let created = Connection(id: dto.id, userId: dto.userId)
            created.apply(dto)
            store.insert(created)
        }
    }

    private func draftJob(id: UUID) throws -> AIDraftJob? {
        try store.fetch(AIDraftJob.self).first(where: { $0.id == id })
    }

    private func suggestion(id: UUID) throws -> Suggestion? {
        try store.fetch(Suggestion.self).first(where: { $0.id == id })
    }

    private func apply(_ dto: SuggestionDTO) throws {
        if let existing = try suggestion(id: dto.id) {
            existing.apply(dto)
        } else {
            store.insert(Suggestion(dto))
        }
    }

    private func importJob(id: UUID) throws -> ImportJob? {
        try store.fetch(ImportJob.self).first(where: { $0.id == id })
    }

    private func apply(_ dto: ImportJobDTO) throws {
        if let existing = try importJob(id: dto.id) {
            existing.apply(dto)
        } else {
            store.insert(ImportJob(dto))
        }
    }

    /// A server job; a confirmation still on its way keeps the local
    /// `confirmed` state.
    private func apply(_ dto: AIDraftJobDTO) throws {
        let job: AIDraftJob
        if let existing = try draftJob(id: dto.id) {
            job = existing
        } else {
            // Created on another device or from Siri before this device
            // knew the text.
            job = AIDraftJob(transcript: "", timeZone: TimeZone(identifier: dto.timezone ?? "") ?? .current, referenceTime: dto.referenceTime ?? dto.createdAt ?? now())
            job.id = dto.id
            store.insert(job)
        }
        let isConfirming = try unfinishedEntities().contains(dto.id)
        if isConfirming && job.status == .confirmed && dto.status == "ready" { return }
        job.apply(dto)
    }

    private func node(id: UUID) throws -> ReminderNode? {
        try store.fetch(ReminderNode.self).first(where: { $0.id == id })
    }

    /// Entities with an operation that is still on its way.
    private func unfinishedEntities() throws -> Set<UUID> {
        let failed = OutboxOperation.Status.failed.rawValue
        let operations = try store.fetch(OutboxOperation.self).filter { $0.statusRaw != failed }
        return Set(operations.compactMap(\.entityId))
    }

    private func deleteOccurrences(of nodeId: UUID) throws {
        try store.deleteAll(ServerOccurrence.self) { $0.nodeId == nodeId }
    }

    static func occurrenceKey(inPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "occurrences"), parts.indices.contains(index + 1) else { return nil }
        return String(parts[index + 1])
    }

    static func fields(of node: ReminderNode) -> NodeMapper.LocalFields {
        NodeMapper.LocalFields(
            title: node.title,
            note: node.note,
            scheduledAt: node.scheduledAt,
            originDate: node.originDate,
            repeatSchedule: node.repeatSchedule,
            timeZone: node.timeZone
        )
    }
}
