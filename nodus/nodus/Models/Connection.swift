import Foundation
import SwiftData

/// A trusted contact (`LocalConnections`). Only `active` connections can
/// receive shared knots.
@Model
nonisolated final class Connection {
    @Attribute(.unique) var id: UUID
    /// The other person.
    var userId: UUID
    var displayName: String?
    /// `pending`, `active` or `removed`.
    var status: String
    var invitedByMe: Bool
    var awaitingMyConfirmation: Bool
    var createdAt: Date

    init(id: UUID, userId: UUID) {
        self.id = id
        self.userId = userId
        status = "pending"
        invitedByMe = false
        awaitingMyConfirmation = false
        createdAt = Date()
    }

    var isActive: Bool { status == "active" }

    func apply(_ dto: ConnectionDTO) {
        userId = dto.userId
        displayName = dto.displayName
        status = dto.status
        invitedByMe = dto.invitedByMe
        awaitingMyConfirmation = dto.awaitingMyConfirmation
        createdAt = dto.createdAt ?? createdAt
    }
}
