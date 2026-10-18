import Foundation
import Testing
@testable import nodus

struct AuthSessionTests {
    private let clock = TestClock()

    private func makeSession(
        transport: FakeTransport,
        store: InMemorySecureStore,
        onLoss: @escaping @Sendable (AuthSession.Loss) -> Void = { _ in }
    ) -> AuthSession {
        let clock = clock
        return AuthSession(
            configuration: APIConfiguration(baseURL: Fixtures.baseURL),
            transport: transport,
            store: store,
            now: { clock.now },
            onLoss: onLoss
        )
    }

    @Test func firstUseCreatesOneAnonymousAccountForConcurrentCallers() async throws {
        let gate = Gate()
        let expiresAt = clock.now.addingTimeInterval(900)
        let transport = FakeTransport { _ in
            await gate.wait()
            return .json(201, Fixtures.tokensJSON(access: "a1", refresh: "r1", expiresAt: expiresAt))
        }
        let store = InMemorySecureStore()
        let session = makeSession(transport: transport, store: store)

        async let first = session.accessToken()
        async let second = session.accessToken()
        async let third = session.accessToken()
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()

        #expect(try await [first, second, third] == ["a1", "a1", "a1"])
        #expect(await transport.requests(to: "/auth/anonymous").count == 1)
        #expect(store.storedSession?.isAnonymous == true)
    }

    @Test func concurrentRefreshesShareOneRequest() async throws {
        let gate = Gate()
        let store = InMemorySecureStore(session: Fixtures.session(access: "old", refresh: "r-old", expiresAt: clock.now.addingTimeInterval(900)))
        let newExpiry = clock.now.addingTimeInterval(1800)
        let transport = FakeTransport { _ in
            await gate.wait()
            return .json(200, Fixtures.tokensJSON(access: "new", refresh: "r-new", expiresAt: newExpiry))
        }
        let session = makeSession(transport: transport, store: store)

        async let a = session.refresh(rejecting: "old")
        async let b = session.refresh(rejecting: "old")
        async let c = session.refresh(rejecting: "old")
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        let results = try await [a, b, c]

        #expect(results.map(\.accessToken) == ["new", "new", "new"])
        let refreshes = await transport.requests(to: "/auth/refresh")
        #expect(refreshes.count == 1)
        let sentBody = try #require(refreshes.first?.httpBody)
        #expect(String(decoding: sentBody, as: UTF8.self).contains("r-old"))
        #expect(store.storedSession?.tokens.refreshToken == "r-new")
    }

    @Test func aRefreshForAnAlreadyRotatedTokenIsNotRepeated() async throws {
        let store = InMemorySecureStore(session: Fixtures.session(access: "current", refresh: "r", expiresAt: clock.now.addingTimeInterval(900)))
        let transport = FakeTransport { _ in Issue.record("no request expected"); return .json(500, "{}") }
        let session = makeSession(transport: transport, store: store)

        let tokens = try await session.refresh(rejecting: "stale")

        #expect(tokens.accessToken == "current")
        #expect(await transport.requests.isEmpty)
    }

    @Test func refreshesAMinuteBeforeExpiry() async throws {
        let store = InMemorySecureStore(session: Fixtures.session(access: "old", refresh: "r", expiresAt: clock.now.addingTimeInterval(120)))
        let newExpiry = clock.now.addingTimeInterval(1000)
        let transport = FakeTransport { _ in .json(200, Fixtures.tokensJSON(access: "new", refresh: "r2", expiresAt: newExpiry)) }
        let session = makeSession(transport: transport, store: store)

        #expect(try await session.accessToken() == "old")
        clock.advance(by: 61)
        #expect(try await session.accessToken() == "new")
        #expect(await transport.requests(to: "/auth/refresh").count == 1)
    }

    @Test func lostAnonymousSessionCreatesANewAccount() async throws {
        let store = InMemorySecureStore(session: Fixtures.session(access: "old", refresh: "r", expiresAt: clock.now.addingTimeInterval(900)))
        let expiresAt = clock.now.addingTimeInterval(900)
        let userId = UUID()
        let transport = FakeTransport { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return Fixtures.problem(401, "invalid_refresh_token") }
            return .json(201, Fixtures.tokensJSON(access: "fresh", refresh: "rf", expiresAt: expiresAt, userId: userId))
        }
        let losses = LossRecorder()
        let session = makeSession(transport: transport, store: store, onLoss: { losses.record($0) })

        let tokens = try await session.refresh(rejecting: "old")

        #expect(tokens.userId == userId)
        #expect(store.storedSession?.tokens.accessToken == "fresh")
        #expect(losses.values == [.anonymousAccountReplaced])
    }

    @Test func lostEmailSessionEndsWithoutReplacingTheAccount() async throws {
        let store = InMemorySecureStore(session: Fixtures.session(access: "old", refresh: "r", expiresAt: clock.now.addingTimeInterval(900), isAnonymous: false))
        let transport = FakeTransport { _ in Fixtures.problem(401, "invalid_refresh_token") }
        let losses = LossRecorder()
        let session = makeSession(transport: transport, store: store, onLoss: { losses.record($0) })

        await #expect(throws: APIError.self) { try await session.refresh(rejecting: "old") }
        #expect(store.storedSession == nil)
        #expect(losses.values == [.sessionEnded])
        #expect(await transport.requests(to: "/auth/anonymous").isEmpty)
    }

    @Test func networkFailureKeepsTheOldRefreshTokenForARetry() async throws {
        let original = Fixtures.session(access: "old", refresh: "r-old", expiresAt: clock.now.addingTimeInterval(900))
        let store = InMemorySecureStore(session: original)
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let session = makeSession(transport: transport, store: store)

        await #expect(throws: APIError.self) { try await session.refresh(rejecting: "old") }
        #expect(store.storedSession == original)
    }
}

nonisolated final class LossRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AuthSession.Loss] = []

    func record(_ loss: AuthSession.Loss) { lock.withLock { recorded.append(loss) } }
    var values: [AuthSession.Loss] { lock.withLock { recorded } }
}
