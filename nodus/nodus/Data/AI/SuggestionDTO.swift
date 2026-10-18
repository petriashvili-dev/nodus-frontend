import Foundation

nonisolated struct SuggestionDTO: Codable, Sendable, Equatable {
    var id: UUID
    var sourceNodeId: UUID
    var status: String
    var title: String
    var description: String?
    var shownAt: Date?
    var acceptedAt: Date?
    var dismissedAt: Date?
    var linkedNodeId: UUID?
    var version: Int
}

nonisolated struct AcceptSuggestionBody: Codable, Sendable {
    var node: CreateNodeBody
}

nonisolated struct AcceptSuggestionResponse: Decodable, Sendable {
    var suggestion: SuggestionDTO
    var node: NodeDTO
}

/// Import job support is filled by the import flow; keeping the DTO here
/// makes snapshot decoding forward compatible while that screen is wired.
nonisolated struct ImportJobDTO: Codable, Sendable, Equatable {
    var id: UUID
    var status: String
    var fileName: String?
    var version: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var expiresAt: Date?
    var error: String?
    var preview: [ImportPreviewNodeDTO]?
    var previewIssues: [ImportPreviewIssueDTO]?
    var result: ImportResultDTO?
}

nonisolated struct ImportPreviewNodeDTO: Codable, Sendable, Equatable {
    var index: Int
    var type: NodeType
    var title: String
    var description: String?
    var timezone: String?
    var date: String?
    var time: String?
    var recurrence: RecurrenceDTO?
    var trackYears: Bool?
}

nonisolated struct ImportPreviewIssueDTO: Codable, Sendable, Equatable {
    var index: Int
    var title: String?
    var code: String
    var message: String?
}

nonisolated struct ImportResultDTO: Codable, Sendable, Equatable {
    var createdNodes: Int
    var skippedDuplicates: Int
    var skippedInactive: Int
    var issues: [ImportPreviewIssueDTO]?
}

nonisolated struct ImportRequestBody: Encodable, Sendable {
    var content: String
    var fileName: String
    var timezone: String
}

nonisolated struct ImportResponseDTO: Decodable, Sendable {
    var mode: String
    var format: String?
    var job: ImportJobDTO?
    var result: ImportResultDTO?
}

nonisolated struct ConfirmImportBody: Encodable, Sendable {
    var indexes: [Int]?
}
