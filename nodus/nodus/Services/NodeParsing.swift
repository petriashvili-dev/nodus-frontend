import Foundation

/// The app-facing contract for turning a spoken or typed sentence into Nodus
/// nodes. Keeping it independent of the provider makes replacing the direct
/// TestFlight integration with a backend a one-file change.
protocol NodeParsing {
    func parse(_ text: String, context: NodeParsingContext) async throws -> NodeParseResult
}

struct NodeParsingContext: Sendable {
    let now: Date
    let timeZone: TimeZone
    let locale: Locale

    init(
        now: Date = .now,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
    }
}

struct NodeParseResult: Sendable, Equatable {
    let nodes: [ParsedNode]
    let clarifications: [NodeClarification]
}

struct ParsedNode: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let note: String?
    let scheduledAt: Date?
    let repeatSchedule: RepeatSchedule

    init(
        id: UUID = UUID(),
        title: String,
        note: String? = nil,
        scheduledAt: Date? = nil,
        repeatSchedule: RepeatSchedule = .none
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.scheduledAt = scheduledAt
        self.repeatSchedule = repeatSchedule
    }
}

struct NodeClarification: Sendable, Equatable, Identifiable {
    enum Field: String, Decodable, Sendable {
        case title
        case scheduledAt
        case repeatSchedule
    }

    let id = UUID()
    let field: Field
    let question: String
}

enum NodeParsingError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case server(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Для тестовой AI-функции не задан ключ NeuroAPI."
        case .invalidEndpoint:
            return "Неверный адрес NeuroAPI."
        case let .server(statusCode, message):
            return "NeuroAPI вернул ошибку \(statusCode): \(message)"
        case .invalidResponse:
            return "Не удалось разобрать ответ AI."
        }
    }
}
