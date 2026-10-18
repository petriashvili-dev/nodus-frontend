import Foundation

/// Node types of the server contract.
nonisolated enum NodeType: String, Codable, Sendable {
    case oneTime = "one_time"
    case recurring
    case anniversary
}

nonisolated struct RecurrenceDTO: Codable, Sendable, Equatable {
    var frequency: String
    var interval: Int
    var startDate: String
    var until: String?
    var times: [String]
    var weekDays: [String]
    var monthDay: Int?
}

/// `CreateNode` — the client generates the id.
nonisolated struct CreateNodeBody: Codable, Sendable, Equatable {
    var id: UUID
    var type: NodeType
    var title: String
    var description: String?
    var timezone: String
    var date: String?
    var time: String?
    var recurrence: RecurrenceDTO?
    var trackYears: Bool?
}

/// `UpdateNode` — the full template plus `expected_version`; the type
/// never changes.
nonisolated struct UpdateNodeBody: Codable, Sendable, Equatable {
    var expectedVersion: Int?
    var title: String
    var description: String?
    var timezone: String
    var date: String?
    var time: String?
    var recurrence: RecurrenceDTO?
    var trackYears: Bool?
}

nonisolated struct NodeMemberDTO: Codable, Sendable, Equatable {
    var userId: UUID
    var displayName: String?
}

nonisolated struct HorizonDTO: Codable, Sendable, Equatable {
    var from: String
    var to: String
}

nonisolated struct OccurrenceDTO: Codable, Sendable, Equatable {
    var nodeId: UUID
    var key: String
    var revision: Int?
    var title: String
    var description: String?
    var date: String?
    var time: String?
    var scheduledAt: Date?
    var years: Int?
    var state: String
    var completedAt: Date?
    var isPast: Bool
}

nonisolated struct NodeDTO: Codable, Sendable, Equatable {
    var id: UUID
    var type: NodeType
    var ownerId: UUID
    var title: String
    var description: String?
    var timezone: String
    var date: String?
    var time: String?
    var scheduledAt: Date?
    var recurrence: RecurrenceDTO?
    var trackYears: Bool?
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var members: [NodeMemberDTO]?
    var horizon: HorizonDTO?
    var occurrences: [OccurrenceDTO]?
}

nonisolated struct OccurrenceStateDTO: Codable, Sendable, Equatable {
    var nodeId: UUID
    var key: String
    var state: String
    var completedAt: Date?
    var version: Int
    var scheduledAt: Date?
    var date: String?
    var time: String?
}

nonisolated struct UntieBody: Codable, Sendable, Equatable {
    var completedAt: Date
}

nonisolated struct VersionConflictBody: Decodable, Sendable {
    var code: String?
    var current: NodeDTO?
}

// MARK: - Sync

/// One change of a Delta Sync page. `data` is decoded later by
/// `entity_type`, so unknown types from a newer server are skipped.
nonisolated struct SyncChangeDTO: Decodable, Sendable {
    var revision: Int
    var entityType: String
    var entityId: String
    var operation: String
    var version: Int?
    var data: RawJSON?
}

nonisolated struct SyncPageDTO: Decodable, Sendable {
    var changes: [SyncChangeDTO]
    var nextCursor: Int
    var hasMore: Bool
}

nonisolated struct SnapshotDTO: Decodable, Sendable {
    var cursor: Int
    var user: UserProfileDTO?
    var nodes: [NodeDTO]
    var occurrenceStates: [OccurrenceStateDTO]?
    var aiDraftJobs: [AIDraftJobDTO]?
    var connections: [ConnectionDTO]?
    var suggestions: [SuggestionDTO]?
    var importJobs: [ImportJobDTO]?
}

nonisolated struct FeedItemDTO: Decodable, Sendable {
    var nodeType: NodeType
    var nodeVersion: Int
    var occurrence: OccurrenceDTO
}

nonisolated struct FeedDTO: Decodable, Sendable {
    var from: String
    var to: String
    var items: [FeedItemDTO]
}

nonisolated struct OccurrenceWindowDTO: Decodable, Sendable {
    var from: String
    var to: String
    var occurrences: [OccurrenceDTO]
}

/// Keeps a JSON value as raw bytes so it can be decoded into the right DTO
/// once its type is known.
nonisolated struct RawJSON: Decodable, Sendable {
    let data: Data

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        data = try JSONEncoder().encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try APICoding.decoder.decode(type, from: data)
    }
}

private nonisolated enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Integers (versions, counts) must stay integers.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
