import Foundation

struct ReminderDraft: Equatable {
    var title: String = ""
    var note: String = ""
    var scheduledAt: Date = .earliestReminderTime()
    var originDate: Date?
    var repeatSchedule: RepeatSchedule = .none
    var leadTimes: [ReminderLeadTime] = ReminderNode.defaultLeadTimes
}

struct ReminderValidator: Sendable {
    nonisolated init() {}

    /// Every knot's date, regardless of repeat schedule, must be ahead of
    /// now — neither past nor the current moment.
    nonisolated func validate(_ draft: ReminderDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReminderError.emptyTitle
        }

        guard draft.scheduledAt >= .earliestReminderTime() else {
            throw ReminderError.invalidDate
        }
    }
}
