import Foundation
import Testing
@testable import nodus

struct APIClientTests {
    private let clock = TestClock()

    private func makeClient(transport: FakeTransport, store: InMemorySecureStore) -> APIClient {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let clock = clock
        let session = AuthSession(configuration: configuration, transport: transport, store: store, now: { clock.now })
        return APIClient(configuration: configuration, transport: transport, session: session)
    }

    private func signedInStore() -> InMemorySecureStore {
        InMemorySecureStore(session: Fixtures.session(access: "old", refresh: "r", expiresAt: clock.now.addingTimeInterval(900)))
    }

    @Test func retriesOnceAfter401WithTheSameIdempotencyKey() async throws {
        let newExpiry = clock.now.addingTimeInterval(1800)
        let transport = FakeTransport { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                return .json(200, Fixtures.tokensJSON(access: "new", refresh: "r2", expiresAt: newExpiry))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                return Fixtures.problem(401, "unauthorized")
            }
            return .json(200, #"{"timezone":"Europe/Moscow"}"#)
        }
        let client = makeClient(transport: transport, store: signedInStore())
        let key = UUID()

        _ = try await client.send(APIRequest<EmptyResponse>(method: .put, path: "me/timezone", body: Data("{}".utf8), idempotencyKey: key))

        let calls = await transport.requests(to: "/me/timezone")
        #expect(calls.count == 2)
        #expect(calls.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == [key.uuidString, key.uuidString])
        #expect(calls.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test func problemDetailsBecomeAServerErrorWithItsCode() async throws {
        let transport = FakeTransport { _ in
            .json(403, #"{"status":403,"code":"feature_not_available","title":"t","feature":"ai_drafts"}"#,
                  headers: ["X-Request-Id": "req-1"])
        }
        let client = makeClient(transport: transport, store: signedInStore())

        do {
            _ = try await client.send(APIRequest<EmptyResponse>(method: .post, path: "ai/node-drafts"))
            Issue.record("expected an error")
        } catch let error as APIError {
            #expect(error.status == 403)
            #expect(error.code == "feature_not_available")
            #expect(!error.isRetryableWithSameKey)
            guard case let .server(_, problem, _, requestId) = error else { return }
            #expect(problem?.feature == "ai_drafts")
            #expect(requestId == "req-1")
        }
    }

    @Test(arguments: [
        (500, "internal_error", true),
        (503, "unavailable", true),
        (429, "rate_limited", true),
        (429, "ai_quota_exceeded", false),
        (409, "version_conflict", false),
        (400, "validation_failed", false),
    ])
    func retryabilityFollowsTheErrorTable(status: Int, code: String, retryable: Bool) {
        let error = APIError.server(status: status, problem: ProblemDetails(code: code), body: Data(), requestId: nil)
        #expect(error.isRetryableWithSameKey == retryable)
    }

    @Test func offlineIsRetryable() {
        #expect(APIError.transport(URLError(.notConnectedToInternet)).isRetryableWithSameKey)
    }

    @Test func decodesSnakeCaseBodiesAndISOMoments() async throws {
        let transport = FakeTransport { _ in
            .json(200, """
            {"id":"00000000-0000-0000-0000-000000000009","is_anonymous":true,"email":null,"display_name":null,
             "timezone":"Europe/Moscow","features":["ai_drafts","something_new"],
             "ai_consent_at":"2026-10-18T09:00:00.123+00:00","version":3,"created_at":"2026-10-17T09:00:00+00:00"}
            """)
        }
        let client = makeClient(transport: transport, store: signedInStore())

        let profile = try await client.send(APIRequest<UserProfileDTO>(method: .get, path: "me"))

        #expect(profile.isAnonymous)
        #expect(profile.aiAccess.features == [.drafts])
        #expect(profile.aiAccess.hasConsent)
        #expect(profile.version == 3)
    }

    @Test(arguments: [
        "2026-10-18T18:46:09+00:00",
        "2026-10-18T18:46:09.123+00:00",
        "2026-10-18T18:46:09.979833+00:00",
        "2026-10-18T18:46:09.9798331Z",
    ])
    func parsesServerMomentsWithAnyFraction(_ raw: String) throws {
        let date = try #require(APICoding.parseMoment(raw))
        #expect(abs(date.timeIntervalSince1970 - 1_792_349_169) < 1)
    }

    @Test func buildsURLsUnderTheVersionedBase() {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let url = configuration.url(for: "feed", query: [URLQueryItem(name: "from", value: "2026-10-17")])
        #expect(url.absoluteString == "https://api.test/v1/feed?from=2026-10-17")
    }
}
