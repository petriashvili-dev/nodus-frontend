import Foundation
import SwiftData

protocol NodeRepositoryProtocol {
    func fetchNodes() throws -> [ReminderNode]
    func fetchOccurrenceStates(since: Date) throws -> [ReminderOccurrenceState]
    func fetchOccurrenceOverrides(since: Date) throws -> [ReminderOccurrenceOverride]
    func saveNode(_ node: ReminderNode) throws
    func saveNodes(_ nodes: [ReminderNode]) throws
    func saveOccurrenceState(_ state: ReminderOccurrenceState) throws
    func saveOccurrenceOverride(_ override: ReminderOccurrenceOverride) throws
    func deleteNode(_ node: ReminderNode) throws
    func deleteOccurrenceOverride(_ override: ReminderOccurrenceOverride) throws
    func saveChanges() throws
}

@MainActor
final class SwiftDataNodeRepository: NodeRepositoryProtocol {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchNodes() throws -> [ReminderNode] {
        let descriptor = FetchDescriptor<ReminderNode>(sortBy: [SortDescriptor(\.scheduledAt)])
        return try context.fetch(descriptor)
    }

    func fetchOccurrenceStates(since date: Date) throws -> [ReminderOccurrenceState] {
        try context.fetch(FetchDescriptor<ReminderOccurrenceState>(
            predicate: #Predicate { $0.occurrenceDate >= date }
        ))
    }

    func fetchOccurrenceOverrides(since date: Date) throws -> [ReminderOccurrenceOverride] {
        try context.fetch(FetchDescriptor<ReminderOccurrenceOverride>(
            predicate: #Predicate { $0.originalOccurrenceDate >= date }
        ))
    }

    func saveNode(_ node: ReminderNode) throws {
        context.insert(node)
        try saveChanges()
    }

    func saveNodes(_ nodes: [ReminderNode]) throws {
        nodes.forEach(context.insert)
        do {
            try saveChanges()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Replaces any existing state for the same occurrence rather than
    /// blindly inserting — without this, repeated actions on the same
    /// occurrence (e.g. tapping Untie twice) would leave two rows with the
    /// same (reminderId, occurrenceDate), which crashes the timeline's
    /// `Dictionary(uniqueKeysWithValues:)` lookup on the next load.
    func saveOccurrenceState(_ state: ReminderOccurrenceState) throws {
        let reminderId = state.reminderId
        let occurrenceDate = state.occurrenceDate
        let existing = try context.fetch(FetchDescriptor<ReminderOccurrenceState>(
            predicate: #Predicate { $0.reminderId == reminderId && $0.occurrenceDate == occurrenceDate }
        ))
        existing.forEach { context.delete($0) }
        context.insert(state)
        try saveChanges()
    }

    /// Same upsert reasoning as `saveOccurrenceState`, keyed on
    /// (reminderId, originalOccurrenceDate).
    func saveOccurrenceOverride(_ override: ReminderOccurrenceOverride) throws {
        let reminderId = override.reminderId
        let originalOccurrenceDate = override.originalOccurrenceDate
        let existing = try context.fetch(FetchDescriptor<ReminderOccurrenceOverride>(
            predicate: #Predicate { $0.reminderId == reminderId && $0.originalOccurrenceDate == originalOccurrenceDate }
        ))
        existing.forEach { context.delete($0) }
        context.insert(override)
        try saveChanges()
    }

    func deleteNode(_ node: ReminderNode) throws {
        context.delete(node)
        try saveChanges()
    }

    func deleteOccurrenceOverride(_ override: ReminderOccurrenceOverride) throws {
        context.delete(override)
        try saveChanges()
    }

    func saveChanges() throws {
        try context.save()
    }
}
