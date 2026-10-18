import Foundation
import os

/// Owns the account tokens (docs/ios/01-auth-and-account.md).
///
/// Refresh is strictly single-flight: the server treats a refresh token
/// reused more than two minutes after rotation as theft and revokes the
/// session, which for an anonymous account is a permanent loss of access.
/// Every caller that needs a refresh awaits the one in progress, and a new
/// pair is written to the Keychain before anyone uses it.
actor AuthSession {
    nonisolated enum Loss: Sendable, Equatable {
        /// The anonymous account is gone; a new one was created.
        case anonymousAccountReplaced
        /// An email account needs to sign in again through recovery.
        case sessionEnded
    }

    private let configuration: APIConfiguration
    private let transport: HTTPTransport
    private let store: SecureStore
    private let now: @Sendable () -> Date
    private let onLoss: @Sendable (Loss) -> Void
    private let logger = Logger(subsystem: "app.nodus", category: "Auth")

    private var session: StoredSession?
    private var hasLoaded = false
    private var refreshTask: Task<AuthTokens, Error>?
    private var signInTask: Task<AuthTokens, Error>?

    /// Refresh this long before `access_token_expires_at`.
    private static let refreshMargin: TimeInterval = 60

    init(
        configuration: APIConfiguration,
        transport: HTTPTransport,
        store: SecureStore,
        now: @escaping @Sendable () -> Date = { Date() },
        onLoss: @escaping @Sendable (Loss) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.now = now
        self.onLoss = onLoss
    }

    var userId: UUID? {
        loadIfNeeded()
        return session?.tokens.userId
    }

    var hasAccount: Bool {
        loadIfNeeded()
        return session != nil
    }

    /// A usable access token: creates the anonymous account on first use
    /// and refreshes ahead of expiry.
    func accessToken() async throws -> String {
        loadIfNeeded()
        guard let tokens = session?.tokens else {
            return try await signInAnonymously().accessToken
        }
        if tokens.accessTokenExpiresAt.addingTimeInterval(-Self.refreshMargin) <= now() {
            return try await refresh(rejecting: tokens.accessToken).accessToken
        }
        return tokens.accessToken
    }

    /// Called after `401 unauthorized` with the token that was rejected. If
    /// another caller already rotated the pair, the fresh pair is returned
    /// without a second refresh.
    @discardableResult
    func refresh(rejecting accessToken: String) async throws -> AuthTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        loadIfNeeded()
        guard let current = session else {
            return try await signInAnonymously()
        }
        if current.tokens.accessToken != accessToken {
            return current.tokens
        }

        let task = Task { try await performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Updates whether the account is anonymous (from the profile).
    func setAnonymous(_ isAnonymous: Bool) throws {
        loadIfNeeded()
        guard var current = session, current.isAnonymous != isAnonymous else { return }
        current.isAnonymous = isAnonymous
        try store.saveSession(current)
        session = current
    }

    /// Replaces the account (recovery sign-in).
    func adopt(_ tokens: AuthTokens, isAnonymous: Bool) throws {
        let new = StoredSession(tokens: tokens, isAnonymous: isAnonymous)
        try store.saveSession(new)
        session = new
    }

    /// Logout or account deletion: forget the tokens on this device.
    func clear() throws {
        try store.clearSession()
        session = nil
    }

    var currentRefreshToken: String? {
        loadIfNeeded()
        return session?.tokens.refreshToken
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            session = try store.loadSession()
        } catch {
            logger.error("Could not read the session from the Keychain")
        }
    }

    private func signInAnonymously() async throws -> AuthTokens {
        if let signInTask {
            return try await signInTask.value
        }
        let task = Task { try await performAnonymousSignIn() }
        signInTask = task
        defer { signInTask = nil }
        return try await task.value
    }

    private func performAnonymousSignIn() async throws -> AuthTokens {
        var request = URLRequest(url: configuration.url(for: "auth/anonymous"))
        request.httpMethod = "POST"
        let tokens: AuthTokens = try await sendAuthRequest(request)
        let new = StoredSession(tokens: tokens, isAnonymous: true)
        try store.saveSession(new)
        session = new
        return tokens
    }

    private func performRefresh(_ current: StoredSession) async throws -> AuthTokens {
        var request = URLRequest(url: configuration.url(for: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try APICoding.encoder.encode(["refresh_token": current.tokens.refreshToken])

        do {
            let tokens: AuthTokens = try await sendAuthRequest(request)
            let rotated = StoredSession(tokens: tokens, isAnonymous: current.isAnonymous)
            // Persist before use: if the app dies now, the next launch must
            // not come back with the already rotated refresh token.
            try store.saveSession(rotated)
            session = rotated
            return tokens
        } catch let error as APIError where error.code == "invalid_refresh_token" {
            return try await handleLostSession(current)
        }
    }

    private func handleLostSession(_ lost: StoredSession) async throws -> AuthTokens {
        logger.notice("Refresh token rejected; the session has ended")
        try store.clearSession()
        session = nil
        guard lost.isAnonymous else {
            onLoss(.sessionEnded)
            throw APIError.sessionEnded
        }
        let tokens = try await performAnonymousSignIn()
        onLoss(.anonymousAccountReplaced)
        return tokens
    }

    private func sendAuthRequest<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }
        let requestId = response.value(forHTTPHeaderField: "X-Request-Id")
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.server(
                status: response.statusCode,
                problem: try? APICoding.decoder.decode(ProblemDetails.self, from: data),
                body: data,
                requestId: requestId
            )
        }
        do {
            return try APICoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse(requestId: requestId)
        }
    }
}
