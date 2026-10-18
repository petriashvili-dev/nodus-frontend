import Foundation
import SwiftData
import os

/// Talks to the server on behalf of the local store, off the main actor
/// with its own `ModelContext` (docs/03-outbox-and-sync.md).
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

    private var modelContext: ModelContext { modelExecutor.modelContext }

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
            try modelContext.delete(model: OutboxOperation.self)
            try modelContext.delete(model: ServerOccurrence.self)
            for node in try modelContext.fetch(FetchDescriptor<ReminderNode>()) {
                node.serverVersion = 0
                node.ownerId = nil
                node.memberCount = 1
            }
            metadata.cursor = nil
            metadata.didQueueLegacyNodes = false
            metadata.sentTimeZone = nil
        }
        metadata.userId = userId
        try modelContext.save()
    }

    /// Knots saved before the backend existed (or re-uploaded after an
    /// account change) have no server copy yet: queue their creation once,
    /// keeping their ids so the server and the device agree on identity.
    private func queueLegacyNodesIfNeeded() throws {
        let metadata = try metadata()
        guard !metadata.didQueueLegacyNodes else { return }
        let queued = Set(try modelContext.fetch(FetchDescriptor<OutboxOperation>()).compactMap(\.entityId))
        let nodes = try modelContext.fetch(FetchDescriptor<ReminderNode>(predicate: #Predicate { $0.serverVersion == 0 }))
        let moment = now()
        for node in nodes where !queued.contains(node.id) {
            if node.timeZoneIdentifier.isEmpty {
                node.timeZoneIdentifier = TimeZone.current.identifier
            }
            let body = NodeMapper.createBody(id: node.id, fields: Self.fields(of: node))
            modelContext.insert(OutboxOperation(
                kind: .createNode, method: .post, path: "nodes",
                body: try APICoding.encoder.encode(body), entityId: node.id, now: moment
            ))
            // A completed one-time knot stays completed; the server accepts
            // completion moments up to 30 days old.
            if !node.isRepeating, node.status == .completed {
                let completedAt = max(node.completedAt ?? moment, moment.addingTimeInterval(-29 * 24 * 60 * 60))
                modelContext.insert(OutboxOperation(
                    kind: .untie, method: .put, path: "nodes/\(node.id.uuidString)/occurrences/once/untie",
                    body: try APICoding.encoder.encode(UntieBody(completedAt: completedAt)),
                    entityId: node.id, now: moment
                ))
            }
        }
        metadata.didQueueLegacyNodes = true
        try modelContext.save()
    }

    /// The device zone changed (a flight, the first launch): nodes are
    /// moved to it on the server, keeping local times. Queued after any
    /// pending edits so they are sent first.
    private func queueTimeZoneIfNeeded(_ zone: TimeZone) throws {
        let metadata = try metadata()
        guard metadata.sentTimeZone != zone.identifier else { return }
        let existing = try modelContext.fetch(FetchDescriptor<OutboxOperation>())
            .filter { $0.kind == .setTimezone && !$0.hasBeenSent }
        existing.forEach(modelContext.delete)
        modelContext.insert(OutboxOperation(
            kind: .setTimezone, method: .put, path: "me/timezone",
            body: try APICoding.encoder.encode(["timezone": zone.identifier]),
            entityId: nil, now: now()
        ))
        try modelContext.save()
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
        let interrupted = try modelContext.fetch(FetchDescriptor<OutboxOperation>(predicate: #Predicate { $0.statusRaw == inFlight }))
        guard !interrupted.isEmpty else { return }
        interrupted.forEach { $0.status = .pending }
        try modelContext.save()
    }

    /// The oldest operation whose entity has nothing unfinished before it.
    private func nextSendableOperation() throws -> OutboxOperation? {
        let all = try modelContext.fetch(FetchDescriptor<OutboxOperation>(sortBy: [SortDescriptor(\.createdAt)]))
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
            try modelContext.save()

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
            modelContext.delete(operation)
            try apply(dto, respectingOverlay: true)
        case .untie, .retie:
            let state = try APICoding.decoder.decode(OccurrenceStateDTO.self, from: data)
            modelContext.delete(operation)
            try apply(state)
        case .setTimezone:
            if let body = operation.body,
               let sent = try? APICoding.decoder.decode([String: String].self, from: body)["timezone"] {
                try metadata().sentTimeZone = sent
            }
            modelContext.delete(operation)
        case .setAIConsent:
            if let profile = try? APICoding.decoder.decode(UserProfileDTO.self, from: data) {
                events.profile(profile)
            }
            modelContext.delete(operation)
        case .deleteNode, nil:
            modelContext.delete(operation)
        }
        try modelContext.save()
    }

    /// A chain of own edits: each next operation is based on the version
    /// the previous one produced.
    private func advanceExpectedVersion(after operation: OutboxOperation, to version: Int) {
        guard let entity = operation.entityId,
              let later = try? modelContext.fetch(FetchDescriptor<OutboxOperation>(predicate: #Predicate { $0.entityId == entity })) else { return }
        for next in later where next.id != operation.id && next.needsExpectedVersion && !next.hasBeenSent {
            next.expectedVersion = version
        }
    }

    private func handleFailure(of operation: OutboxOperation, error: APIError) -> SendOutcome {
        if case .sessionEnded = error {
            operation.status = .pending
            try? modelContext.save()
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
                modelContext.delete(operation)
            case (409, "version_conflict"):
                try resolveConflict(operation, error: error)
            case (404, _):
                try rollBack(operation)
                modelContext.delete(operation)
            case (403, "feature_not_available"), (403, "ai_consent_required"):
                operation.status = .failed
                operation.lastErrorCode = code
                events.accessRefused()
            default:
                // Validation, forbidden, quota, a reused key: the server
                // keeps this answer for the key, so the operation is final.
                operation.status = .failed
                operation.lastErrorCode = code
                if let entity = operation.entityId, let node = try node(id: entity) {
                    node.syncIssueRaw = "rejected"
                }
            }
            try modelContext.save()
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
        try? modelContext.save()
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
        modelContext.delete(operation)
        modelContext.insert(copy)
    }

    /// `404`: the node or occurrence is gone on the server (deleted, access
    /// lost, the rule changed). Undo the local change; the pull that follows
    /// restores the truth.
    private func rollBack(_ operation: OutboxOperation) throws {
        guard let entity = operation.entityId else { return }
        switch operation.kind {
        case .untie, .retie:
            let key = Self.occurrenceKey(inPath: operation.path)
            let overlays = try modelContext.fetch(FetchDescriptor<ReminderOccurrenceState>(predicate: #Predicate { $0.reminderId == entity }))
            overlays.filter { $0.key == key }.forEach(modelContext.delete)
        case .updateNode, .deleteNode:
            if let node = try node(id: entity) {
                modelContext.delete(node)
            }
            try deleteOccurrences(of: entity)
        default:
            break
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
            try modelContext.save()
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
        for node in try modelContext.fetch(FetchDescriptor<ReminderNode>())
        where node.serverVersion > 0 && !serverIds.contains(node.id) && !pendingEntities.contains(node.id) {
            try deleteOccurrences(of: node.id)
            modelContext.delete(node)
        }
        for dto in snapshot.nodes {
            try apply(dto, respectingOverlay: true)
        }
        if let user = snapshot.user {
            events.profile(user)
        }
        let metadata = try metadata()
        metadata.cursor = snapshot.cursor
        metadata.lastSuccessAt = now()
        try modelContext.save()
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
                modelContext.delete(node)
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
        default:
            // Connections, AI jobs, suggestions, imports and types from a
            // newer server are handled by their own features or skipped.
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
            modelContext.insert(node)
        }
        node.serverVersion = dto.version
        node.ownerId = dto.ownerId
        node.memberCount = max(dto.members?.count ?? 1, 1)

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
            let existing = try modelContext.fetch(FetchDescriptor<ServerOccurrence>(predicate: #Predicate { $0.nodeId == nodeId }))
            let incoming = Set(occurrences.map { ServerOccurrence.identifier(nodeId: nodeId, key: $0.key) })
            for occurrence in existing where !incoming.contains(occurrence.id) {
                if occurrence.isInFeed {
                    occurrence.isInHorizon = false
                } else {
                    modelContext.delete(occurrence)
                }
            }
            for occurrence in occurrences {
                try upsert(occurrence, inFeed: nil, inHorizon: true)
            }
        }
    }

    private func apply(_ state: OccurrenceStateDTO) throws {
        let id = ServerOccurrence.identifier(nodeId: state.nodeId, key: state.key)
        if let occurrence = try modelContext.fetch(FetchDescriptor<ServerOccurrence>(predicate: #Predicate { $0.id == id })).first {
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
        let overlays = try modelContext.fetch(FetchDescriptor<ReminderOccurrenceState>(predicate: #Predicate { $0.reminderId == nodeId }))
        overlays.filter { $0.key == key }.forEach(modelContext.delete)
    }

    @discardableResult
    private func upsert(_ dto: OccurrenceDTO, inFeed: Bool?, inHorizon: Bool?) throws -> ServerOccurrence {
        let id = ServerOccurrence.identifier(nodeId: dto.nodeId, key: dto.key)
        let occurrence: ServerOccurrence
        if let existing = try modelContext.fetch(FetchDescriptor<ServerOccurrence>(predicate: #Predicate { $0.id == id })).first {
            occurrence = existing
        } else {
            occurrence = ServerOccurrence(nodeId: dto.nodeId, key: dto.key)
            modelContext.insert(occurrence)
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

        for occurrence in try modelContext.fetch(FetchDescriptor<ServerOccurrence>()) {
            occurrence.isInFeed = false
            occurrence.isInHorizon = false
        }
        for item in feed.items {
            try upsert(item.occurrence, inFeed: true, inHorizon: nil)
        }
        for occurrence in window.occurrences {
            try upsert(occurrence, inFeed: nil, inHorizon: true)
        }
        try modelContext.delete(model: ServerOccurrence.self, where: #Predicate { !$0.isInFeed && !$0.isInHorizon })
        try modelContext.save()
    }

    /// When the earliest postponed operation may be sent again.
    func nextRetryDate() throws -> Date? {
        let retryable = OutboxOperation.Status.retryableFailure.rawValue
        let pending = OutboxOperation.Status.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.statusRaw == retryable || $0.statusRaw == pending },
            sortBy: [SortDescriptor(\.nextAttemptAt)]
        )).first?.nextAttemptAt
    }

    // MARK: - Helpers

    private func metadata() throws -> SyncMetadata {
        if let existing = try modelContext.fetch(FetchDescriptor<SyncMetadata>()).first {
            return existing
        }
        let created = SyncMetadata()
        modelContext.insert(created)
        return created
    }

    private func node(id: UUID) throws -> ReminderNode? {
        try modelContext.fetch(FetchDescriptor<ReminderNode>(predicate: #Predicate { $0.id == id })).first
    }

    /// Entities with an operation that is still on its way.
    private func unfinishedEntities() throws -> Set<UUID> {
        let failed = OutboxOperation.Status.failed.rawValue
        let operations = try modelContext.fetch(FetchDescriptor<OutboxOperation>(predicate: #Predicate { $0.statusRaw != failed }))
        return Set(operations.compactMap(\.entityId))
    }

    private func deleteOccurrences(of nodeId: UUID) throws {
        try modelContext.delete(model: ServerOccurrence.self, where: #Predicate { $0.nodeId == nodeId })
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
