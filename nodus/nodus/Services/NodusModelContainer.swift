import SwiftData

enum NodusModelContainer {
    nonisolated static let appGroupID = "group.app.nodus"

    static func make() throws -> ModelContainer {
        let schema = Schema([
            ReminderNode.self,
            ReminderOccurrenceState.self,
            ReminderOccurrenceOverride.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(appGroupID)
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
