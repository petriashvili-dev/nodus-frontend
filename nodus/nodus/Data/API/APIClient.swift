import Foundation
import os

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One backend call. `Response` is the decoded success body.
nonisolated struct APIRequest<Response: Decodable & Sendable>: Sendable {
    var method: HTTPMethod
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    /// Mutations carry a key that never changes across retries of the same
    /// operation (docs/ios/02-outbox-and-errors.md).
    var idempotencyKey: UUID?
    var requiresAuth = true
    /// Extra headers such as `If-None-Match`.
    var headers: [String: String] = [:]

    init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        idempotencyKey: UUID? = nil,
        requiresAuth: Bool = true,
        headers: [String: String] = [:]
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.idempotencyKey = idempotencyKey
        self.requiresAuth = requiresAuth
        self.headers = headers
    }

    init<Body: Encodable>(
        method: HTTPMethod,
        path: String,
        json body: Body,
        idempotencyKey: UUID? = nil,
        requiresAuth: Bool = true
    ) throws {
        self.init(
            method: method,
            path: path,
            body: try APICoding.encoder.encode(body),
            idempotencyKey: idempotencyKey,
            requiresAuth: requiresAuth
        )
    }
}

nonisolated struct APIResponse<Body: Sendable>: Sendable {
    let body: Body
    let status: Int
    /// Header names are lowercased: HTTP names are case-insensitive.
    let headers: [String: String]
    /// `Idempotent-Replayed: true` — the server already ran this operation.
    var isReplay: Bool { headers["idempotent-replayed"]?.lowercased() == "true" }
}

/// Sends requests, authorizes them through `AuthSession` and turns error
/// bodies into `APIError`. Retries happen only for `401` (once, with the same
/// idempotency key, after a single-flight refresh); everything else is the
/// caller's decision — usually the Outbox's.
actor APIClient {
    private let configuration: APIConfiguration
    private let transport: HTTPTransport
    private let session: AuthSession
    private let logger = Logger(subsystem: "app.nodus", category: "API")

    init(configuration: APIConfiguration, transport: HTTPTransport, session: AuthSession) {
        self.configuration = configuration
        self.transport = transport
        self.session = session
    }

    func send<Response>(_ request: APIRequest<Response>) async throws -> Response {
        try await sendWithResponse(request).body
    }

    func sendWithResponse<Response>(_ request: APIRequest<Response>) async throws -> APIResponse<Response> {
        let (data, response) = try await perform(request)
        let headers = Self.headers(of: response)
        if Response.self == EmptyResponse.self || data.isEmpty, let empty = EmptyResponse() as? Response {
            return APIResponse(body: empty, status: response.statusCode, headers: headers)
        }
        do {
            let body = try APICoding.decoder.decode(Response.self, from: data)
            return APIResponse(body: body, status: response.statusCode, headers: headers)
        } catch {
            let requestId = headers["x-request-id"]
            logger.error("Unexpected response body for \(request.method.rawValue, privacy: .public) \(request.path, privacy: .public), request \(requestId ?? "-", privacy: .public)")
            throw APIError.invalidResponse(requestId: requestId)
        }
    }

    /// The raw body, for endpoints that return a file (`GET /me/export`).
    func data(_ request: APIRequest<EmptyResponse>) async throws -> (Data, [String: String]) {
        let (data, response) = try await perform(request)
        return (data, Self.headers(of: response))
    }

    private func perform<Response>(_ request: APIRequest<Response>) async throws -> (Data, HTTPURLResponse) {
        var token = request.requiresAuth ? try await session.accessToken() : nil
        var (data, response) = try await transmit(request, token: token)

        if response.statusCode == 401, let rejected = token {
            token = try await session.refresh(rejecting: rejected).accessToken
            (data, response) = try await transmit(request, token: token)
        }

        guard (200..<300).contains(response.statusCode) else {
            let problem = try? APICoding.decoder.decode(ProblemDetails.self, from: data)
            let requestId = response.value(forHTTPHeaderField: "X-Request-Id")
            logger.notice("\(request.method.rawValue, privacy: .public) \(request.path, privacy: .public) → \(response.statusCode) \(problem?.code ?? "-", privacy: .public), request \(requestId ?? "-", privacy: .public)")
            throw APIError.server(status: response.statusCode, problem: problem, body: data, requestId: requestId)
        }
        return (data, response)
    }

    private func transmit<Response>(_ request: APIRequest<Response>, token: String?) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: configuration.url(for: request.path, query: request.query))
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            return try await transport.send(urlRequest)
        } catch let error as URLError {
            throw APIError.transport(error)
        }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        return headers
    }
}
