import Foundation

nonisolated struct CreateDraftJobBody: Encodable, Sendable {
    var text: String
    var timezone: String
    /// When the user spoke, so "tomorrow" counts from that moment.
    var referenceTime: Date
}

nonisolated struct DraftIssueDTO: Codable, Sendable, Equatable {
    var code: String
    var field: String?
    var message: String?
}

nonisolated struct NodeDraftDTO: Codable, Sendable, Equatable {
    var index: Int
    var type: NodeType
    var title: String
    var description: String?
    var timezone: String?
    var date: String?
    var time: String?
    var recurrence: RecurrenceDTO?
    var trackYears: Bool?
    var issues: [DraftIssueDTO]?
}

nonisolated struct AIDraftJobDTO: Codable, Sendable, Equatable {
    var id: UUID
    var status: String
    var timezone: String?
    var referenceTime: Date?
    var error: String?
    var version: Int?
    var createdAt: Date?
    var readyAt: Date?
    var confirmedAt: Date?
    var expiresAt: Date?
    var drafts: [NodeDraftDTO]?
}

nonisolated struct ConfirmDraftsBody: Codable, Sendable {
    var nodes: [CreateNodeBody]
}

nonisolated struct ConfirmDraftsResponse: Decodable, Sendable {
    nonisolated struct Created: Decodable, Sendable {
        var nodes: [NodeDTO]
    }

    var job: AIDraftJobDTO
    var created: Created?
}

nonisolated struct AIConsentBody: Codable, Sendable {
    var granted: Bool
}
