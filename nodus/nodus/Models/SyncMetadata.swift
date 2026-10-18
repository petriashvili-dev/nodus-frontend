import Foundation
import SwiftData

/// The single row of sync bookkeeping. Saved in the same transaction as the
/// changes it acknowledges.
@Model
nonisolated final class SyncMetadata {
    /// `next_cursor` of the last applied Delta Sync page; `nil` until the
    /// first snapshot.
    var cursor: Int?
    var lastSuccessAt: Date?
    /// The account this cache belongs to. A different account (recovery, a
    /// lost anonymous session) starts from a fresh snapshot.
    var userId: UUID?
    /// Knots created before the backend existed have been queued for
    /// upload once.
    var didQueueLegacyNodes: Bool = false
    /// The last zone sent with `PUT /me/timezone`.
    var sentTimeZone: String?

    init() {}
}
