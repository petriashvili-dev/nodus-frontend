import Foundation

/// JSON conventions of the backend: `snake_case` keys and ISO 8601 moments
/// (`2026-10-18T06:30:00+00:00`, sometimes with fractional seconds). Dates
/// without a time (`2026-10-18`) and local times (`09:30`) stay strings in
/// DTOs — they are not moments.
nonisolated enum APICoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatMoment(date))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseMoment(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 moment")
            }
            return date
        }
        return decoder
    }()

    static func formatMoment(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parseMoment(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) {
            return date
        }
        return try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// For endpoints that answer `204` or whose body the client does not need.
nonisolated struct EmptyResponse: Decodable, Sendable {}
