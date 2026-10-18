import Foundation
import SwiftData

@Model
nonisolated final class ImportJob {
    @Attribute(.unique) var id: UUID
    var statusRaw: String
    var fileName: String?
    var version: Int?
    var createdAt: Date?
    var updatedAt: Date?
    var expiresAt: Date?
    var error: String?
    var previewData: Data?
    var issuesData: Data?
    var resultData: Data?
    var pendingConfirmKey: String?
    var pendingConfirmIndexesData: Data?
    var pendingCancelKey: String?

    var preview: [ImportPreviewNodeDTO] {
        guard let previewData else { return [] }
        return (try? APICoding.decoder.decode([ImportPreviewNodeDTO].self, from: previewData)) ?? []
    }

    var previewIssues: [ImportPreviewIssueDTO] {
        guard let issuesData else { return [] }
        return (try? APICoding.decoder.decode([ImportPreviewIssueDTO].self, from: issuesData)) ?? []
    }

    var result: ImportResultDTO? {
        guard let resultData else { return nil }
        return try? APICoding.decoder.decode(ImportResultDTO.self, from: resultData)
    }

    var pendingConfirmIndexes: [Int]? {
        guard let pendingConfirmIndexesData else { return nil }
        return try? APICoding.decoder.decode([Int].self, from: pendingConfirmIndexesData)
    }

    func prepareConfirm(indexes: [Int]) throws -> UUID {
        if let pendingConfirmKey, let id = UUID(uuidString: pendingConfirmKey) { return id }
        let id = UUID()
        pendingConfirmKey = id.uuidString
        pendingConfirmIndexesData = try APICoding.encoder.encode(indexes)
        return id
    }

    func prepareCancel() -> UUID {
        if let pendingCancelKey, let id = UUID(uuidString: pendingCancelKey) { return id }
        let id = UUID()
        pendingCancelKey = id.uuidString
        return id
    }

    init(_ dto: ImportJobDTO) {
        id = dto.id
        statusRaw = dto.status
        fileName = dto.fileName
        version = dto.version
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
        expiresAt = dto.expiresAt
        error = dto.error
        previewData = Self.encode(dto.preview)
        issuesData = Self.encode(dto.previewIssues)
        resultData = Self.encode(dto.result)
    }

    func apply(_ dto: ImportJobDTO) {
        statusRaw = dto.status
        fileName = dto.fileName
        version = dto.version
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
        expiresAt = dto.expiresAt
        error = dto.error
        if let preview = dto.preview { previewData = Self.encode(preview) }
        if let issues = dto.previewIssues { issuesData = Self.encode(issues) }
        if let result = dto.result { resultData = Self.encode(result) }
    }

    private static func encode<T: Encodable>(_ value: T?) -> Data? {
        guard let value else { return nil }
        return try? APICoding.encoder.encode(value)
    }
}
