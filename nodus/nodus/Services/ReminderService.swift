import Foundation
import os

/// The one place that changes knots. Every change is optimistic: the local
/// row and its Outbox operation are saved together, the UI updates at once,
/// and the server catches up through `SyncEngine` (docs/03-outbox-and-sync.md).
@MainActor
final class ReminderService {
    private let repository: NodeRepositoryProtocol
    private let notificationScheduler: NotificationScheduling
    private let validator: ReminderValidator
    private let repeatEngine: RepeatEngine
    /// Wakes the Outbox after a local change; offline it simply stays queued.
    private let didEnqueue: () -> Void
    private let now: () -> Date
    private let logger = Logger(subsystem: "app.nodus", category: "Reminder")

    init(
        repository: NodeRepositoryProtocol,
        notificationScheduler: NotificationScheduling,
        validator: ReminderValidator = ReminderValidator(),
        repeatEngine: RepeatEngine = RepeatEngine(),
        didEnqueue: @escaping () -> Void = {},
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        self.validator = validator
        self.repeatEngine = repeatEngine
        self.didEnqueue = didEnqueue
        self.now = now
    }

    @discardableResult
    func tie(_ draft: ReminderDraft, settings: SettingsSnapshot) async throws -> ReminderNode {
        try validator.validate(draft)
        let now = now()
        let node = ReminderNode(
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            scheduledAt: draft.scheduledAt,
            originDate: draft.repeatSchedule.isYearly ? draft.originDate : nil,
            repeatSchedule: draft.repeatSchedule,
            leadTimes: draft.leadTimes,
            createdAt: now,
            updatedAt: now
        )
        // New knots belong to the zone the device is in right now.
        node.timeZoneIdentifier = TimeZone.current.identifier
        repository.enqueue(try createOperation(for: node))
        try repository.saveNode(node)
        didEnqueue()
        await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
        return node
    }

    func update(node: ReminderNode, with draft: ReminderDraft, settings: SettingsSnapshot) async throws {
        try validator.validate(draft)
        node.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        node.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        node.scheduledAt = draft.scheduledAt
        node.originDate = draft.repeatSchedule.isYearly ? draft.originDate : nil
        node.repeatSchedule = draft.repeatSchedule
        node.leadTimes = draft.leadTimes
        node.updatedAt = now()
        try enqueueTemplateChange(for: node)
        try repository.saveChanges()
        didEnqueue()
        await notificationScheduler.cancelAll(nodeId: node.id)
        await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
    }

    @discardableResult
    func untie(node: ReminderNode, occurrenceDate: Date?) async throws -> ReminderOccurrenceState? {
        let completedAt = now()
        if node.isRepeating {
            // A recurring knot is never completed as a whole. Current
            // notifications carry the occurrence identity; the fallback is
            // deliberately limited to today for old deep links/notifications.
            guard let occurrenceDate = occurrenceDate ?? repeatEngine.occurrence(for: node, on: completedAt) else {
                throw ReminderError.noOccurrenceToday
            }
            let key = try occurrenceKey(for: node, at: occurrenceDate)
            let state = ReminderOccurrenceState(reminderId: node.id, occurrenceDate: occurrenceDate, status: .completed, completedAt: completedAt)
            state.key = key
            repository.enqueue(try untieOperation(nodeId: node.id, key: key, completedAt: completedAt))
            try repository.saveOccurrenceState(state)
            didEnqueue()
            await notificationScheduler.cancel(nodeId: node.id, occurrenceDate: occurrenceDate)
            return state
        } else {
            node.status = .completed
            node.completedAt = completedAt
            node.updatedAt = completedAt
            repository.enqueue(try untieOperation(nodeId: node.id, key: "once", completedAt: completedAt))
            try repository.saveChanges()
            didEnqueue()
            await notificationScheduler.cancel(nodeId: node.id, occurrenceDate: nil)
            return nil
        }
    }

    /// Restores a completed knot to the active thread. For recurring knots,
    /// completion belongs to one occurrence rather than the whole schedule.
    @discardableResult
    func activate(node: ReminderNode, occurrenceDate: Date?) async throws -> ReminderOccurrenceState? {
        if let occurrenceDate {
            let key = try occurrenceKey(for: node, at: occurrenceDate)
            let state = ReminderOccurrenceState(
                reminderId: node.id,
                occurrenceDate: occurrenceDate,
                status: .active,
                completedAt: nil
            )
            state.key = key
            repository.enqueue(retieOperation(nodeId: node.id, key: key))
            try repository.saveOccurrenceState(state)
            didEnqueue()
            return state
        } else {
            node.status = .active
            node.completedAt = nil
            node.updatedAt = now()
            repository.enqueue(retieOperation(nodeId: node.id, key: "once"))
            try repository.saveChanges()
            didEnqueue()
            return nil
        }
    }

    /// Moves a knot to a new moment. On the server this is a template edit
    /// (`PATCH`); a completed one-time knot is also tied again.
    func retie(node: ReminderNode, occurrenceDate _: Date?, to newDate: Date, settings: SettingsSnapshot) async throws {
        guard newDate > now() else { throw ReminderError.invalidDate }
        node.scheduledAt = newDate
        node.updatedAt = now()
        if !node.isRepeating && node.status == .completed {
            // Re-tying a completed one-off knot must also put it back on the
            // thread; otherwise its newly selected future date remains done.
            node.status = .active
            node.completedAt = nil
            try enqueueTemplateChange(for: node)
            repository.enqueue(retieOperation(nodeId: node.id, key: "once"))
        } else {
            try enqueueTemplateChange(for: node)
        }
        try repository.saveChanges()
        didEnqueue()
        await notificationScheduler.cancelAll(nodeId: node.id)
        await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
    }

    /// Device-local: the server has no per-occurrence hiding
    /// (docs/03-outbox-and-sync.md, "Только на устройстве").
    func hideOccurrence(node: ReminderNode, occurrenceDate: Date) throws {
        let override = ReminderOccurrenceOverride(reminderId: node.id, originalOccurrenceDate: occurrenceDate, isDeleted: true)
        try repository.saveOccurrenceOverride(override)
    }

    /// Device-local: the server has no pause.
    func pause(node: ReminderNode, until date: Date) async throws {
        guard node.isRepeating else { return }
        guard date > now() else { throw ReminderError.invalidDate }
        node.pausedUntil = date
        node.updatedAt = now()
        try repository.saveChanges()

        // Clear all previously queued occurrences right away. The timeline
        // reload that follows schedules only the first allowed occurrences
        // after the pause.
        await notificationScheduler.cancelAll(nodeId: node.id)
    }

    func resume(node: ReminderNode) async throws {
        guard node.isRepeating, node.pausedUntil != nil else { return }
        node.pausedUntil = nil
        node.updatedAt = now()
        try repository.saveChanges()
    }

    func delete(node: ReminderNode) async throws {
        logger.info("Deleting knot")
        await notificationScheduler.cancelAll(nodeId: node.id)
        let unsent = try repository.unsentOperations(for: node.id)
        if unsent.contains(where: { $0.kind == .createNode }) {
            // The server never saw this knot: forget its queue instead of
            // creating and immediately deleting it.
            unsent.forEach(repository.deleteOperation)
        } else {
            let operation = OutboxOperation(
                kind: .deleteNode,
                method: .delete,
                path: "nodes/\(node.id.uuidString)",
                body: nil,
                entityId: node.id,
                needsExpectedVersion: true,
                now: now()
            )
            operation.expectedVersion = node.serverVersion
            repository.enqueue(operation)
        }
        try repository.deleteNode(node)
        didEnqueue()
    }

    // MARK: - Outbox operations

    private func createOperation(for node: ReminderNode) throws -> OutboxOperation {
        let body = NodeMapper.createBody(id: node.id, fields: Self.fields(of: node))
        return OutboxOperation(
            kind: .createNode,
            method: .post,
            path: "nodes",
            body: try APICoding.encoder.encode(body),
            entityId: node.id,
            now: now()
        )
    }

    /// Several offline edits collapse into one operation while it has not
    /// been sent; an unsent create simply carries the latest template.
    private func enqueueTemplateChange(for node: ReminderNode) throws {
        let unsent = try repository.unsentOperations(for: node.id)
        if let create = unsent.first(where: { $0.kind == .createNode }) {
            create.body = try APICoding.encoder.encode(NodeMapper.createBody(id: node.id, fields: Self.fields(of: node)))
            return
        }
        let body = try APICoding.encoder.encode(NodeMapper.updateBody(fields: Self.fields(of: node)))
        if let update = unsent.last(where: { $0.kind == .updateNode }) {
            update.body = body
            return
        }
        let operation = OutboxOperation(
            kind: .updateNode,
            method: .patch,
            path: "nodes/\(node.id.uuidString)",
            body: body,
            entityId: node.id,
            needsExpectedVersion: true,
            now: now()
        )
        // The version the user saw while editing; later own responses
        // advance it (SyncEngine) so a chain of edits never conflicts with
        // itself.
        operation.expectedVersion = node.serverVersion
        repository.enqueue(operation)
    }

    private func untieOperation(nodeId: UUID, key: String, completedAt: Date) throws -> OutboxOperation {
        OutboxOperation(
            kind: .untie,
            method: .put,
            path: "nodes/\(nodeId.uuidString)/occurrences/\(key)/untie",
            body: try APICoding.encoder.encode(UntieBody(completedAt: completedAt)),
            entityId: nodeId,
            now: now()
        )
    }

    private func retieOperation(nodeId: UUID, key: String) -> OutboxOperation {
        OutboxOperation(
            kind: .retie,
            method: .put,
            path: "nodes/\(nodeId.uuidString)/occurrences/\(key)/retie",
            body: nil,
            entityId: nodeId,
            now: now()
        )
    }

    /// The server's key for this occurrence; for a knot the server has not
    /// confirmed yet, the predictable key of its nearest occurrence.
    private func occurrenceKey(for node: ReminderNode, at occurrenceDate: Date) throws -> String {
        if let occurrence = try repository.serverOccurrence(nodeId: node.id, scheduledAt: occurrenceDate) {
            return occurrence.key
        }
        return NodeMapper.offlineOccurrenceKey(isRepeating: node.isRepeating, occurrence: occurrenceDate, timeZone: node.timeZone)
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
