import Foundation
@testable import nodus

/// Records requests and answers them from a handler. A handler may suspend
/// (for example on a `Gate`) to hold requests in flight.
actor FakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]

        static func json(_ status: Int, _ json: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(json.utf8), headers: headers)
        }
    }

    typealias Handler = @Sendable (URLRequest) async throws -> Reply

    private(set) var requests: [URLRequest] = []
    private var handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try await record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        return (reply.body, response)
    }

    private func record(_ request: URLRequest) async throws -> Reply {
        requests.append(request)
        let handler = self.handler
        return try await handler(request)
    }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(path) == true }
    }
}

/// Lets a test hold concurrent requests until it opens the gate.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

nonisolated final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?
    private var installation = UUID()
    private(set) var saveCount = 0

    init(session: StoredSession? = nil) {
        self.session = session
    }

    func loadSession() throws -> StoredSession? {
        lock.withLock { session }
    }

    func saveSession(_ session: StoredSession) throws {
        lock.withLock {
            self.session = session
            saveCount += 1
        }
    }

    func clearSession() throws {
        lock.withLock { session = nil }
    }

    func installationId() throws -> UUID {
        lock.withLock { installation }
    }

    var storedSession: StoredSession? {
        lock.withLock { session }
    }
}

/// A clock the test moves by hand.
nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_792_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

nonisolated enum Fixtures {
    static let baseURL = URL(string: "https://api.test/v1")!

    static func tokensJSON(access: String, refresh: String, expiresAt: Date, userId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> String {
        let moment = APICoding.formatMoment(expiresAt)
        let refreshMoment = APICoding.formatMoment(expiresAt.addingTimeInterval(60 * 60 * 24 * 60))
        return """
        {"user_id":"\(userId.uuidString)","access_token":"\(access)","access_token_expires_at":"\(moment)",
         "refresh_token":"\(refresh)","refresh_token_expires_at":"\(refreshMoment)","token_type":"Bearer"}
        """
    }

    static func session(access: String, refresh: String, expiresAt: Date, isAnonymous: Bool = true) -> StoredSession {
        StoredSession(
            tokens: AuthTokens(
                userId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                accessToken: access,
                accessTokenExpiresAt: expiresAt,
                refreshToken: refresh,
                refreshTokenExpiresAt: expiresAt.addingTimeInterval(60 * 60 * 24 * 60)
            ),
            isAnonymous: isAnonymous
        )
    }

    static func problem(_ status: Int, _ code: String) -> FakeTransport.Reply {
        .json(status, #"{"status":\#(status),"code":"\#(code)","title":"t"}"#)
    }
}
