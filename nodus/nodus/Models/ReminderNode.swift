import Foundation
import SwiftData

@Model
nonisolated final class ReminderNode {
    @Attribute(.unique) var id: UUID
    var title: String
    var note: String?
    var scheduledAt: Date
    /// The date from which a yearly anniversary is counted. It is optional
    /// because recurring reminders do not always represent an anniversary.
    var originDate: Date?
    // A default value here (rather than leaving it required-with-no-default)
    // is what lets SwiftData's lightweight migration add this column to
    // already-saved knots — it renamed `repeatRuleRaw`, and a required
    // attribute with no default has nothing to backfill existing rows with.
    var repeatScheduleRaw: String = "none"
    var leadTimesRaw: String?
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    /// A temporary stop for recurring knots. `nil` means the schedule is
    /// active; occurrences before this instant are omitted from the thread
    /// and from local-notification scheduling.
    var pausedUntil: Date?

    // MARK: Server state (docs/03-outbox-and-sync.md)
    //
    // The local row is a cache of the server's node plus the user's pending
    // changes on top. Defaults let lightweight migration add these columns
    // to knots saved before the backend existed.

    /// The server `version` this row reflects; `0` until the server has
    /// confirmed the node at least once.
    var serverVersion: Int = 0
    /// IANA zone the node's local date and time belong to. Empty for knots
    /// created before the backend; they adopt the device zone when sent.
    var timeZoneIdentifier: String = ""
    var ownerId: UUID?
    /// Number of participants including the owner; above one the node is
    /// shared and conflicts are never resolved silently.
    var memberCount: Int = 1
    /// A one-time node without a date ("someday"), created on another
    /// client. This client has no editor for it yet and keeps it off the
    /// thread instead of inventing a date.
    var isUndated: Bool = false
    /// A local change the server rejected or that conflicts with someone
    /// else's; shown quietly on the card.
    var syncIssueRaw: String?

    init(
        id: UUID = UUID(),
        title: String,
        note: String? = nil,
        scheduledAt: Date,
        originDate: Date? = nil,
        repeatSchedule: RepeatSchedule = .none,
        leadTimes: [ReminderLeadTime] = ReminderNode.defaultLeadTimes,
        status: NodeStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        pausedUntil: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.scheduledAt = scheduledAt
        self.originDate = originDate
        self.repeatScheduleRaw = repeatSchedule.rawToken
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.pausedUntil = pausedUntil
        self.leadTimesRaw = Self.encode(leadTimes)
    }

    /// A single "at the moment" reminder — the common case for a plain
    /// knot. Yearly anniversaries typically replace this with several
    /// (7 days before, 1 day before, at the moment), but the storage and
    /// the editor's picker treat both the same way: just a list.
    static let defaultLeadTimes: [ReminderLeadTime] = [.atTime]

    var repeatSchedule: RepeatSchedule {
        get { RepeatSchedule(rawToken: repeatScheduleRaw) ?? .none }
        set { repeatScheduleRaw = newValue.rawToken }
    }

    var status: NodeStatus {
        get { NodeStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var isRepeating: Bool {
        repeatSchedule.isRepeating
    }

    var isShared: Bool {
        memberCount > 1
    }

    /// The zone to send to the server; knots predating the backend never
    /// recorded one and use the device's.
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    /// An empty list means "no notifications for this knot" — distinct
    /// from `nil`/missing storage, which falls back to the default below
    /// (older knots saved before this existed).
    var leadTimes: [ReminderLeadTime] {
        get {
            guard let leadTimesRaw else { return Self.defaultLeadTimes }
            guard !leadTimesRaw.isEmpty else { return [] }
            return leadTimesRaw.split(separator: ",").compactMap { ReminderLeadTime(rawToken: String($0)) }
        }
        set { leadTimesRaw = Self.encode(newValue) }
    }

    private static func encode(_ leadTimes: [ReminderLeadTime]) -> String {
        leadTimes.map(\.rawToken).joined(separator: ",")
    }
}
