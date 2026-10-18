import Foundation

/// The problem details body every backend error carries. Decisions are made
/// by `code`, never by the human-readable `title`.
nonisolated struct ProblemDetails: Decodable, Sendable, Equatable {
    var status: Int?
    var code: String?
    var title: String?
    /// The AI feature key for `feature_not_available` / `ai_consent_required`.
    var feature: String?
    /// Field errors of `validation_failed`, keyed in snake_case.
    var errors: [String: [String]]?
}

nonisolated enum APIError: Error, Sendable {
    /// No response: offline, timeout, connection lost.
    case transport(URLError)
    /// The server answered with a non-2xx status. `body` is kept for errors
    /// that carry data, such as `409 version_conflict` with `current`.
    case server(status: Int, problem: ProblemDetails?, body: Data, requestId: String?)
    /// A 2xx body that does not match the contract.
    case invalidResponse(requestId: String?)
    /// The session ended and cannot be renewed silently (an email account
    /// whose refresh token was revoked or expired).
    case sessionEnded

    var status: Int? {
        if case let .server(status, _, _, _) = self { return status }
        return nil
    }

    var code: String? {
        if case let .server(_, problem, _, _) = self { return problem?.code }
        return nil
    }

    /// Whether the same request, with the same `Idempotency-Key`, may be sent
    /// again (docs/ios/02-outbox-and-errors.md). Business errors are stored by
    /// the server against the key and need a new operation instead.
    var isRetryableWithSameKey: Bool {
        switch self {
        case .transport:
            return true
        case let .server(status, problem, _, _):
            if status >= 500 { return true }
            return status == 429 && problem?.code == "rate_limited"
        case .invalidResponse, .sessionEnded:
            return false
        }
    }

    var isOffline: Bool {
        if case .transport = self { return true }
        return false
    }
}
