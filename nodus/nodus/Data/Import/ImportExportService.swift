import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct TransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .commaSeparatedText] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExportedNodusFile: Sendable {
    var data: Data
    var fileName: String
}

actor ImportExportService {
    private let api: APIClient
    private let didChange: @Sendable () async -> Void
    private struct ImportSubmission: Hashable, Sendable {
        var content: Data
        var fileName: String
        var timezone: String
    }
    private var pendingImportKeys: [ImportSubmission: UUID] = [:]

    init(api: APIClient, didChange: @escaping @Sendable () async -> Void = {}) {
        self.api = api
        self.didChange = didChange
    }

    func export() async throws -> ExportedNodusFile {
        let (data, headers) = try await api.data(APIRequest<EmptyResponse>(method: .get, path: "me/export"))
        let disposition = headers["content-disposition"] ?? ""
        let filename = Self.filename(from: disposition)
        return ExportedNodusFile(data: data, fileName: filename ?? "nodus-export.json")
    }

    func importFile(data: Data, fileName: String, timezone: String) async throws -> ImportResponseDTO {
        guard let content = String(data: data, encoding: .utf8) else { throw ImportExportError.invalidText }
        let submission = ImportSubmission(content: data, fileName: fileName, timezone: timezone)
        let idempotencyKey = pendingImportKeys[submission] ?? UUID()
        pendingImportKeys[submission] = idempotencyKey
        let request = try APIRequest<ImportResponseDTO>(
            method: .post,
            path: "me/import",
            json: ImportRequestBody(content: content, fileName: fileName, timezone: timezone),
            idempotencyKey: idempotencyKey
        )
        do {
            let response = try await api.send(request)
            pendingImportKeys[submission] = nil
            await didChange()
            return response
        } catch let error as APIError {
            if !error.isRetryableWithSameKey { pendingImportKeys[submission] = nil }
            throw error
        }
    }

    func confirm(_ jobId: UUID, indexes: [Int], idempotencyKey: UUID) async throws {
        let request = try APIRequest<ImportJobDTO>(
            method: .post,
            path: "me/imports/\(jobId.uuidString)/confirm",
            json: ConfirmImportBody(indexes: indexes),
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(request)
        await didChange()
    }

    func cancel(_ jobId: UUID, idempotencyKey: UUID) async throws {
        let request = APIRequest<ImportJobDTO>(
            method: .post,
            path: "me/imports/\(jobId.uuidString)/cancel",
            idempotencyKey: idempotencyKey
        )
        _ = try await api.send(request)
        await didChange()
    }

    private static func filename(from disposition: String) -> String? {
        if let range = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let encoded = disposition[range.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init)
            if let encoded, let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        guard let range = disposition.range(of: "filename=", options: .caseInsensitive) else { return nil }
        let raw = disposition[range.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return raw?.isEmpty == false ? raw : nil
    }
}

enum ImportExportError: LocalizedError {
    case invalidText

    var errorDescription: String? {
        switch self {
        case .invalidText: "The selected file is not readable text."
        }
    }
}
