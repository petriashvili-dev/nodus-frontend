import Foundation
import SwiftData

/// A ready occurrence computed by the server (`OccurrenceDto`). The client
/// never computes occurrences of a synced node itself; it keeps these for
/// the feed and the local-notification horizon.
@Model
nonisolated final class ServerOccurrence {
    /// `"{nodeId}:{key}"` — also the local notification identifier.
    @Attribute(.unique) var id: String
    var nodeId: UUID
    var key: String
    var title: String
    var note: String?
    /// Local date `yyyy-MM-dd` in the node's zone; `nil` for undated.
    var localDate: String?
    /// Local time `HH:mm`; `nil` for all-day.
    var localTime: String?
    var scheduledAt: Date?
    var years: Int?
    var stateRaw: String
    var completedAt: Date?
    var isPast: Bool
    /// Part of the last `GET /feed` answer: the thread shows exactly these.
    var isInFeed: Bool = false
    /// Within the node's notification horizon.
    var isInHorizon: Bool = false

    init(nodeId: UUID, key: String) {
        id = Self.identifier(nodeId: nodeId, key: key)
        self.nodeId = nodeId
        self.key = key
        title = ""
        stateRaw = "tied"
        isPast = false
    }

    static func identifier(nodeId: UUID, key: String) -> String {
        "\(nodeId.uuidString):\(key)"
    }

    var isUntied: Bool { stateRaw == "untied" }
}
