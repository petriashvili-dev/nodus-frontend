import Foundation
import SwiftData

@Model
final class ReminderOccurrenceOverride {
    @Attribute(.unique) var id: UUID
    var reminderId: UUID
    var originalOccurrenceDate: Date
    var overriddenScheduledAt: Date?
    var isDeleted: Bool

    init(
        id: UUID = UUID(),
        reminderId: UUID,
        originalOccurrenceDate: Date,
        overriddenScheduledAt: Date? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.reminderId = reminderId
        self.originalOccurrenceDate = originalOccurrenceDate
        self.overriddenScheduledAt = overriddenScheduledAt
        self.isDeleted = isDeleted
    }
}

