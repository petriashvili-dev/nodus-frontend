import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let nodusArchive = UTType(exportedAs: "app.nodus.archive", conformingTo: .json)
}

/// A portable snapshot of the active knots in a thread. The archive does not
/// contain completion history, occurrence overrides, or notification state:
/// importing it creates a clean set of active knots on another device.
struct NodusArchive: FileDocument {
    static let currentVersion = 1
    static var readableContentTypes: [UTType] { [.nodusArchive] }
    static var writableContentTypes: [UTType] { [.nodusArchive] }

    let nodes: [ArchivedNode]

    init(nodes: [ReminderNode]) {
        self.nodes = nodes.map(ArchivedNode.init)
    }

    private init(dto: NodusArchiveDTO) {
        nodes = dto.nodes
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(fileData: data)
    }

    init(fileData: Data) throws {
        self.init(dto: try NodusArchiveParser.parse(fileData))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let archive = NodusArchiveV1(version: Self.currentVersion, nodes: nodes)
        return FileWrapper(regularFileWithContents: try Self.encoder.encode(archive))
    }

    func makeNodes() -> [ReminderNode] {
        nodes.map { node in
            ReminderNode(
                title: node.title,
                note: node.note,
                scheduledAt: node.scheduledAt,
                originDate: node.originDate,
                repeatSchedule: node.repeatSchedule,
                leadTimes: node.leadTimes,
                status: .active,
                createdAt: node.createdAt,
                updatedAt: node.updatedAt,
                pausedUntil: node.pausedUntil
            )
        }
    }

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    fileprivate static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The stable in-app representation. Version-specific adapters convert an
/// archive file into this DTO before the importer creates SwiftData models.
struct NodusArchiveDTO {
    let nodes: [ArchivedNode]
}

private struct NodusArchiveVersionEnvelope: Decodable {
    let version: Int
}

private protocol NodusArchiveVersionAdapter {
    func makeDTO(from data: Data) throws -> NodusArchiveDTO
}

private enum NodusArchiveParser {
    static func parse(_ data: Data) throws -> NodusArchiveDTO {
        let envelope = try NodusArchive.decoder.decode(NodusArchiveVersionEnvelope.self, from: data)

        switch envelope.version {
        case 1:
            return try NodusArchiveV1Adapter().makeDTO(from: data)
        default:
            throw NodusArchiveError.unsupportedFormat
        }
    }
}

/// Keep this adapter even though V1 currently matches the common DTO: future
/// formats can change independently without leaking their schema into import.
private struct NodusArchiveV1Adapter: NodusArchiveVersionAdapter {
    func makeDTO(from data: Data) throws -> NodusArchiveDTO {
        let archive = try NodusArchive.decoder.decode(NodusArchiveV1.self, from: data)
        guard archive.version == 1 else { throw NodusArchiveError.unsupportedFormat }
        return NodusArchiveDTO(nodes: archive.nodes)
    }
}

private struct NodusArchiveV1: Codable {
    let version: Int
    let nodes: [ArchivedNode]
}

struct ArchivedNode: Codable {
    let title: String
    let note: String?
    let scheduledAt: Date
    let originDate: Date?
    let repeatSchedule: RepeatSchedule
    let leadTimes: [ReminderLeadTime]
    let createdAt: Date
    let updatedAt: Date
    let pausedUntil: Date?

    init(_ node: ReminderNode) {
        title = node.title
        note = node.note
        scheduledAt = node.scheduledAt
        originDate = node.originDate
        repeatSchedule = node.repeatSchedule
        leadTimes = node.leadTimes
        createdAt = node.createdAt
        updatedAt = node.updatedAt
        pausedUntil = node.pausedUntil
    }
}

enum NodusArchiveError: LocalizedError {
    case unsupportedFormat
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Этот файл создан другой версией Nodus."
        case .empty:
            return "В файле нет активных узлов для импорта."
        }
    }
}
