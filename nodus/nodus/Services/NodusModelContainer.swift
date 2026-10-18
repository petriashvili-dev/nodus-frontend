import SwiftData

enum NodusModelContainer {
    nonisolated static let appGroupID = "group.app.nodus"

    /// Every persisted model; tests build in-memory stores from it.
    nonisolated static let schema = Schema([
        ReminderNode.self,
        ReminderOccurrenceState.self,
        ReminderOccurrenceOverride.self,
        OutboxOperation.self,
        SyncMetadata.self,
        ServerOccurrence.self,
        AIDraftJob.self,
        Connection.self,
        Suggestion.self,
        ImportJob.self,
    ])

    static func make() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(appGroupID)
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
