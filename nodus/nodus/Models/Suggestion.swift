import Foundation
import SwiftData

@Model
nonisolated final class Suggestion {
    @Attribute(.unique) var id: UUID
    var sourceNodeId: UUID
    var statusRaw: String
    var title: String
    var detail: String?
    var shownAt: Date?
    var acceptedAt: Date?
    var dismissedAt: Date?
    var linkedNodeId: UUID?
    var version: Int

    init(_ dto: SuggestionDTO) {
        id = dto.id
        sourceNodeId = dto.sourceNodeId
        statusRaw = dto.status
        title = dto.title
        detail = dto.description
        shownAt = dto.shownAt
        acceptedAt = dto.acceptedAt
        dismissedAt = dto.dismissedAt
        linkedNodeId = dto.linkedNodeId
        version = dto.version
    }

    var isReadyToShow: Bool { statusRaw == "ready" && shownAt == nil }

    func apply(_ dto: SuggestionDTO) {
        sourceNodeId = dto.sourceNodeId
        statusRaw = dto.status
        title = dto.title
        detail = dto.description
        shownAt = dto.shownAt
        acceptedAt = dto.acceptedAt
        dismissedAt = dto.dismissedAt
        linkedNodeId = dto.linkedNodeId
        version = dto.version
    }
}
