import Foundation

/// A deliberately small, direct client for the TestFlight experiment.
/// No key ships with the app (the repository is public), so without an
/// injected key `parse` fails with `missingAPIKey`. To be replaced by the
/// backend AI drafts flow (`nodus_backend/docs/ios/07-ai.md`).
struct DirectNeuroAPIParser: NodeParsing {
    private let apiKey: String
    private let session: URLSession
    private let endpoint = URL(string: "https://neuroapi.host/v1/chat/completions")!
    private let model = "deepseek-v4-flash"

    init(apiKey: String = "", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func parse(_ text: String, context: NodeParsingContext) async throws -> NodeParseResult {
        guard !apiKey.isEmpty else { throw NodeParsingError.missingAPIKey }

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: Self.instructions),
                .init(role: "user", content: Self.prompt(text: text, context: context))
            ],
            temperature: 0.1,
            maxTokens: 900,
            responseFormat: .init(type: "json_object")
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NodeParsingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let error = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).error.message)
                ?? String(decoding: data, as: UTF8.self)
            throw NodeParsingError.server(statusCode: httpResponse.statusCode, message: error)
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              let json = Self.jsonData(from: content) else {
            throw NodeParsingError.invalidResponse
        }

        let payload = try JSONDecoder().decode(ParsePayload.self, from: json)
        let nodes = try payload.nodes.map(Self.node(from:))
        let clarifications = payload.clarifications.map {
            NodeClarification(field: $0.field, question: $0.question)
        }
        return NodeParseResult(nodes: nodes, clarifications: clarifications)
    }
}

private extension DirectNeuroAPIParser {
    static let instructions = """
    You extract one or more Nodus reminder nodes from Russian or English user text.
    Return ONLY a JSON object matching the requested schema, with no Markdown.
    A node is one concrete action. Split distinct actions into separate nodes.
    Never invent an action, details, date, time, or recurrence. Keep title short; put only useful leftover detail in note.
    For a known date and time, scheduledAt must be a full ISO 8601 timestamp with timezone offset. Use null if any required part is absent or ambiguous.
    repeat must be one of: none, weekdays, Nd, Nw, Nmo, Ny, where N is a positive integer.
    Add a clarification only when the user must answer before the node can be safely created. Ask one concise question in the user's language.
    The app requires a future scheduledAt, so ask for a date/time when it is missing.
    """

    static func prompt(text: String, context: NodeParsingContext) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = context.timeZone
        return """
        Current time: \(formatter.string(from: context.now))
        Time zone: \(context.timeZone.identifier)
        Locale: \(context.locale.identifier)

        User text:
        \(text)

        JSON schema:
        {
          "nodes": [{
            "title": "string",
            "note": "string or null",
            "scheduledAt": "ISO 8601 timestamp or null",
            "repeat": "none | weekdays | Nd | Nw | Nmo | Ny"
          }],
          "clarifications": [{
            "field": "title | scheduledAt | repeatSchedule",
            "question": "string"
          }]
        }
        """
    }

    static func node(from payload: ParsedNodePayload) throws -> ParsedNode {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NodeParsingError.invalidResponse }

        let scheduledAt = try payload.scheduledAt.map(parseISO8601Date(_:))
        let repeatSchedule = RepeatSchedule(rawToken: payload.repeatToken) ?? .none
        return ParsedNode(
            title: title,
            note: payload.note?.trimmingCharacters(in: .whitespacesAndNewlines),
            scheduledAt: scheduledAt,
            repeatSchedule: repeatSchedule
        )
    }

    static func parseISO8601Date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw NodeParsingError.invalidResponse }
        return date
    }

    static func jsonData(from content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutFence.data(using: .utf8)
    }
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxTokens: Int
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

private struct ParsePayload: Decodable {
    let nodes: [ParsedNodePayload]
    let clarifications: [ClarificationPayload]

    enum CodingKeys: String, CodingKey {
        case nodes
        case clarifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([ParsedNodePayload].self, forKey: .nodes)
        // Providers commonly omit an empty optional array, despite the
        // requested schema. Treat that as the intended empty array.
        clarifications = try container.decodeIfPresent([ClarificationPayload].self, forKey: .clarifications) ?? []
    }
}

private struct ParsedNodePayload: Decodable {
    let title: String
    let note: String?
    let scheduledAt: String?
    let repeatToken: String

    enum CodingKeys: String, CodingKey {
        case title, note, scheduledAt
        case repeatToken = "repeat"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        scheduledAt = try container.decodeIfPresent(String.self, forKey: .scheduledAt)
        repeatToken = try container.decodeIfPresent(String.self, forKey: .repeatToken) ?? "none"
    }
}

private struct ClarificationPayload: Decodable {
    let field: NodeClarification.Field
    let question: String
}
