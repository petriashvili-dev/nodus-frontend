import Foundation
import Testing
@testable import nodus

@MainActor
struct AccountServiceTests {
    private let clock = TestClock()
    private let store = InMemorySecureStore(session: Fixtures.session(access: "a", refresh: "r-old", expiresAt: TestClock().now.addingTimeInterval(3600)))
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "AccountServiceTests.\(UUID().uuidString)"))
    }

    private func makeAccount(_ transport: FakeTransport) -> (AccountService, AuthSession) {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let clock = clock
        let session = AuthSession(configuration: configuration, transport: transport, store: store, now: { clock.now })
        let api = APIClient(configuration: configuration, transport: transport, session: session)
        return (AccountService(api: api, session: session, store: store, aiAccessStore: AIAccessStore(defaults: defaults)), session)
    }

    nonisolated private static func profileJSON(email: String?, anonymous: Bool) -> String {
        let emailValue = email.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"00000000-0000-0000-0000-000000000001","is_anonymous":\(anonymous),"email":\(emailValue),"display_name":null,
         "timezone":"Europe/Moscow","features":[],"ai_consent_at":null,"version":2}
        """
    }

    @Test func linkingAnEmailKeepsTheSameAccount() async throws {
        let transport = FakeTransport { request in
            request.url!.path.hasSuffix("/verify") ? .json(200, Self.profileJSON(email: "a@b.c", anonymous: false)) : .json(202, #"{"message":"ok"}"#)
        }
        let (account, _) = makeAccount(transport)

        try await account.startLinkingEmail("a@b.c")
        try await account.verifyLinkingEmail("a@b.c", code: "123456")

        #expect(account.profile?.email == "a@b.c")
        #expect(!account.isAnonymous)
        #expect(store.storedSession?.tokens.accessToken == "a")
    }

    @Test func wrongCodeIsReportedByItsCode() async {
        let (account, _) = makeAccount(FakeTransport { _ in Fixtures.problem(400, "invalid_code") })

        await #expect(throws: AccountService.EmailError.invalidCode) {
            try await account.verifyLinkingEmail("a@b.c", code: "000000")
        }
    }

    @Test func recoveryReplacesTokensAndWipesTheAnonymousData() async throws {
        let restored = UUID()
        let expiresAt = clock.now.addingTimeInterval(900)
        let transport = FakeTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/sign-in/verify") {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                return .json(200, Fixtures.tokensJSON(access: "restored", refresh: "rr", expiresAt: expiresAt, userId: restored))
            }
            if path.hasSuffix("/me") { return .json(200, Self.profileJSON(email: "a@b.c", anonymous: false)) }
            return .json(202, "{}")
        }
        let (account, _) = makeAccount(transport)
        let wiped = Recorder<UUID?>()
        account.resetLocalData = { wiped.record($0) }

        try await account.startRecovery("a@b.c")
        try await account.completeRecovery("a@b.c", code: "123456")

        #expect(store.storedSession?.tokens.userId == restored)
        #expect(store.storedSession?.isAnonymous == false)
        #expect(wiped.values == [restored])
    }

    @Test func deletingTheAccountForgetsItLocally() async throws {
        let transport = FakeTransport { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
            return FakeTransport.Reply(status: 204, body: Data())
        }
        let (account, _) = makeAccount(transport)
        let wiped = Recorder<UUID?>()
        account.resetLocalData = { wiped.record($0) }

        try await account.deleteAccount()

        #expect(store.storedSession == nil)
        #expect(wiped.values == [nil])
    }

    @Test func a401AfterALostDeleteResponseMeansDeleted() async throws {
        let (account, _) = makeAccount(FakeTransport { request in
            request.url!.path.hasSuffix("/auth/refresh") ? Fixtures.problem(401, "invalid_refresh_token") : Fixtures.problem(401, "unauthorized")
        })
        account.resetLocalData = { _ in }

        try await account.deleteAccount()

        #expect(store.storedSession == nil)
    }

    @Test func deletingOfflineKeepsEverything() async {
        let (account, _) = makeAccount(FakeTransport { _ in throw URLError(.notConnectedToInternet) })
        let wiped = Recorder<UUID?>()
        account.resetLocalData = { wiped.record($0) }

        await #expect(throws: AccountService.EmailError.offline) { try await account.deleteAccount() }
        #expect(store.storedSession != nil)
        #expect(wiped.values.isEmpty)
    }

    @Test func renamingGoesThroughTheOutbox() throws {
        let (account, _) = makeAccount(FakeTransport { _ in .json(200, "{}") })
        let queued = Recorder<OutboxOperation>()
        account.enqueue = { queued.record($0) }

        try account.updateDisplayName("  Аня ")

        let operation = try #require(queued.values.first)
        #expect(operation.kind == .updateProfile)
        #expect(operation.httpMethod == .patch)
        let body = try #require(operation.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["display_name": "Аня"])
    }
}

@MainActor
final class Recorder<Value> {
    private(set) var values: [Value] = []
    func record(_ value: Value) { values.append(value) }
}
