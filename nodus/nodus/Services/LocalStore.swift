import Foundation
import SwiftData

/// A local persistence record that can be loaded by the active store adapter.
/// The protocol keeps SwiftData fetch descriptors out of the sync layer while
/// allowing the existing records to remain the app's on-disk representation.
nonisolated protocol LocalStoreRecord: PersistentModel {
    static func fetchAll(from context: ModelContext) throws -> [Self]
}

/// Persistence boundary used by sync and background application services.
/// Calls are synchronous because the owner serializes access to its store
/// context (the sync engine's model actor in production).
nonisolated protocol LocalStore: AnyObject {
    func fetch<T: LocalStoreRecord>(_ type: T.Type) throws -> [T]
    func insert<T: LocalStoreRecord>(_ record: T)
    func delete<T: LocalStoreRecord>(_ record: T)
    func deleteAll<T: LocalStoreRecord>(_ type: T.Type) throws
    func deleteAll<T: LocalStoreRecord>(_ type: T.Type, where predicate: (T) -> Bool) throws
    func save() throws
    func rollback()
}

/// SwiftData implementation of `LocalStore`. Keep this instance confined to
/// the actor that owns the supplied context.
nonisolated final class SwiftDataLocalStore: LocalStore, @unchecked Sendable {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetch<T: LocalStoreRecord>(_ type: T.Type) throws -> [T] {
        try T.fetchAll(from: context)
    }

    func insert<T: LocalStoreRecord>(_ record: T) {
        context.insert(record)
    }

    func delete<T: LocalStoreRecord>(_ record: T) {
        context.delete(record)
    }

    func deleteAll<T: LocalStoreRecord>(_ type: T.Type) throws {
        try context.delete(model: type)
    }

    func deleteAll<T: LocalStoreRecord>(_ type: T.Type, where predicate: (T) -> Bool) throws {
        for record in try fetch(type) where predicate(record) {
            delete(record)
        }
    }

    func save() throws {
        try context.save()
    }

    func rollback() {
        context.rollback()
    }
}

extension ReminderNode: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [ReminderNode] {
        try context.fetch(FetchDescriptor<ReminderNode>())
    }
}

extension ReminderOccurrenceState: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [ReminderOccurrenceState] {
        try context.fetch(FetchDescriptor<ReminderOccurrenceState>())
    }
}

extension ReminderOccurrenceOverride: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [ReminderOccurrenceOverride] {
        try context.fetch(FetchDescriptor<ReminderOccurrenceOverride>())
    }
}

extension OutboxOperation: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [OutboxOperation] {
        try context.fetch(FetchDescriptor<OutboxOperation>())
    }
}

extension SyncMetadata: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [SyncMetadata] {
        try context.fetch(FetchDescriptor<SyncMetadata>())
    }
}

extension ServerOccurrence: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [ServerOccurrence] {
        try context.fetch(FetchDescriptor<ServerOccurrence>())
    }
}

extension AIDraftJob: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [AIDraftJob] {
        try context.fetch(FetchDescriptor<AIDraftJob>())
    }
}

extension Connection: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [Connection] {
        try context.fetch(FetchDescriptor<Connection>())
    }
}

extension Suggestion: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [Suggestion] {
        try context.fetch(FetchDescriptor<Suggestion>())
    }
}

extension ImportJob: LocalStoreRecord {
    static func fetchAll(from context: ModelContext) throws -> [ImportJob] {
        try context.fetch(FetchDescriptor<ImportJob>())
    }
}
