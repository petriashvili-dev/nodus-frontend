import Foundation

/// A connection seen from this user (`ConnectionDto`): `user_id` is the
/// other person.
nonisolated struct ConnectionDTO: Codable, Sendable, Equatable {
    var id: UUID
    var userId: UUID
    var displayName: String?
    var status: String
    var invitedByMe: Bool
    var awaitingMyConfirmation: Bool
    var version: Int?
    var createdAt: Date?
    var confirmedAt: Date?
}

nonisolated struct ConnectionsListDTO: Decodable, Sendable {
    var connections: [ConnectionDTO]
}

nonisolated struct InviteDTO: Decodable, Sendable, Equatable {
    var id: UUID
    var token: String
    var code: String
    var link: URL
    var expiresAt: Date
}

nonisolated struct AcceptCodeBody: Encodable, Sendable {
    var code: String
}

nonisolated struct AddMemberBody: Encodable, Sendable {
    var userId: UUID
}

extension InviteDTO {
    /// `K7M2Q9TP` → `K7M2 Q9TP`, easier to read aloud.
    nonisolated var groupedCode: String {
        stride(from: 0, to: code.count, by: 4).map { start in
            let lower = code.index(code.startIndex, offsetBy: start)
            let upper = code.index(lower, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[lower..<upper])
        }.joined(separator: " ")
    }
}
