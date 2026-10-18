import Foundation
import SwiftData

@Model
nonisolated final class ReminderOccurrenceState {
    @Attribute(.unique) var id: UUID
    var reminderId: UUID
    var occurrenceDate: Date
    var statusRaw: String
    var completedAt: Date?
    /// The server occurrence key (`g0-20261018-0`, `once`) this state belongs
    /// to; `nil` for states recorded before the backend.
    var key: String?

    init(
        id: UUID = UUID(),
        reminderId: UUID,
        occurrenceDate: Date,
        status: NodeStatus = .active,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.reminderId = reminderId
        self.occurrenceDate = occurrenceDate
        self.statusRaw = status.rawValue
        self.completedAt = completedAt
    }

    var status: NodeStatus {
        get { NodeStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }
}

