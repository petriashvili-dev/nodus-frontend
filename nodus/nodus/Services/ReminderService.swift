import Foundation
import os
#if os(iOS)
import WidgetKit
#endif

@MainActor
final class ReminderService {
    private let repository: NodeRepositoryProtocol
    private let notificationScheduler: NotificationScheduling
    private let validator: ReminderValidator
    private let repeatEngine: RepeatEngine
    private let logger = Logger(subsystem: "app.nodus", category: "Reminder")

    init(
        repository: NodeRepositoryProtocol,
        notificationScheduler: NotificationScheduling,
        validator: ReminderValidator = ReminderValidator(),
        repeatEngine: RepeatEngine = RepeatEngine()
    ) {
        self.repository = repository
        self.notificationScheduler = notificationScheduler
        self.validator = validator
        self.repeatEngine = repeatEngine
    }

    @discardableResult
    func tie(_ draft: ReminderDraft, settings: SettingsSnapshot) async throws -> ReminderNode {
        try validator.validate(draft)
        let now = Date()
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
        try repository.saveNode(node)
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
        node.updatedAt = Date()
        try repository.saveChanges()
        await notificationScheduler.cancelAll(nodeId: node.id)
        await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
    }

    @discardableResult
    func untie(node: ReminderNode, occurrenceDate: Date?) async throws -> ReminderOccurrenceState? {
        if node.isRepeating {
            // A recurring knot is never completed as a whole. Current
            // notifications carry the occurrence identity; the fallback is
            // deliberately limited to today for old deep links/notifications.
            guard let occurrenceDate = occurrenceDate ?? repeatEngine.occurrence(for: node, on: Date()) else {
                throw ReminderError.noOccurrenceToday
            }
            let state = ReminderOccurrenceState(reminderId: node.id, occurrenceDate: occurrenceDate, status: .completed, completedAt: Date())
            try repository.saveOccurrenceState(state)
#if os(iOS)
            reloadWidgets()
#endif
            await notificationScheduler.cancel(nodeId: node.id, occurrenceDate: occurrenceDate)
            return state
        } else {
            node.status = .completed
            node.completedAt = Date()
            node.updatedAt = Date()
            try repository.saveChanges()
#if os(iOS)
            reloadWidgets()
#endif
            await notificationScheduler.cancel(nodeId: node.id, occurrenceDate: nil)
            return nil
        }
    }

#if os(iOS)
    /// Notification quick actions may run with a short background execution
    /// window. Reload widgets as soon as the completion reaches disk, before
    /// awaiting notification cleanup that could outlive that window.
    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "NodusTodayWidget")
    }
#endif

    /// Restores a completed knot to the active thread. For recurring knots,
    /// completion belongs to one occurrence rather than the whole schedule.
    @discardableResult
    func activate(node: ReminderNode, occurrenceDate: Date?) async throws -> ReminderOccurrenceState? {
        if let occurrenceDate {
            let state = ReminderOccurrenceState(
                reminderId: node.id,
                occurrenceDate: occurrenceDate,
                status: .active,
                completedAt: nil
            )
            try repository.saveOccurrenceState(state)
            return state
        } else {
            node.status = .active
            node.completedAt = nil
            node.updatedAt = Date()
            try repository.saveChanges()
            return nil
        }
    }

    func retie(node: ReminderNode, occurrenceDate _: Date?, to newDate: Date, settings: SettingsSnapshot) async throws {
        guard newDate > Date() else { throw ReminderError.invalidDate }
        if node.isRepeating {
            // Retie changes the schedule of a recurring knot. Keeping the
            // old date solely as an occurrence override made the move appear
            // to work only until the next reload, which rebuilt the series
            // from its unchanged base date.
            node.scheduledAt = newDate
            node.updatedAt = Date()
            try repository.saveChanges()
            await notificationScheduler.cancelAll(nodeId: node.id)
            await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
        } else {
            node.scheduledAt = newDate
            // Re-tying a completed one-off knot must also put it back on the
            // thread; otherwise its newly selected future date remains done.
            node.status = .active
            node.completedAt = nil
            node.updatedAt = Date()
            try repository.saveChanges()
            await notificationScheduler.cancelAll(nodeId: node.id)
            await notificationScheduler.schedule(node: node, occurrenceDate: nil, scheduledAt: nil, settings: settings)
        }
    }

    func hideOccurrence(node: ReminderNode, occurrenceDate: Date) throws {
        let override = ReminderOccurrenceOverride(reminderId: node.id, originalOccurrenceDate: occurrenceDate, isDeleted: true)
        try repository.saveOccurrenceOverride(override)
    }

    func pause(node: ReminderNode, until date: Date) async throws {
        guard node.isRepeating else { return }
        guard date > Date() else { throw ReminderError.invalidDate }
        node.pausedUntil = date
        node.updatedAt = Date()
        try repository.saveChanges()

        // Clear all previously queued occurrences right away. The timeline
        // reload that follows schedules only the first allowed occurrences
        // after the pause.
        await notificationScheduler.cancelAll(nodeId: node.id)
    }

    func resume(node: ReminderNode) async throws {
        guard node.isRepeating, node.pausedUntil != nil else { return }
        node.pausedUntil = nil
        node.updatedAt = Date()
        try repository.saveChanges()
    }

    func delete(node: ReminderNode) async throws {
        logger.info("Deleting knot")
        await notificationScheduler.cancelAll(nodeId: node.id)
        try repository.deleteNode(node)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
