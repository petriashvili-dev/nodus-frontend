import Foundation
import SwiftData

@Model
final class ReminderOccurrenceState {
    @Attribute(.unique) var id: UUID
    var reminderId: UUID
    var occurrenceDate: Date
    var statusRaw: String
    var completedAt: Date?

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

