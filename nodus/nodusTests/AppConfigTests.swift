import Foundation
import Testing
@testable import nodus

struct AppConfigTests {
    @Test func missingAndMistypedKeysFallBackToDefaults() {
        let json = #"""
        {"values":{"links.privacy_policy":42,"links.terms":"https://example.com/terms","min_supported_version":"x.y",
                   "unknown":"ignored"},
         "limits":{"ai_draft_text_max_chars":"many","import_max_chars":1000}}
        """#
        let config = AppConfig(json: Data(json.utf8))

        #expect(config.privacyPolicyURL == AppConfig.defaults.privacyPolicyURL)
        #expect(config.termsURL == URL(string: "https://example.com/terms"))
        #expect(config.minSupportedVersion == nil)
        #expect(config.limits.aiDraftTextMaxChars == 4000)
        #expect(config.limits.importMaxChars == 1000)
    }

    @Test func garbageIsTheDefaultConfig() {
        #expect(AppConfig(json: Data("nope".utf8)) == .defaults)
    }

    @Test(arguments: [
        ("1.10.0", "1.9.0", false),
        ("1.9.0", "1.10.0", true),
        ("1.2", "1.2.0", false),
        ("1.2.0", "1.2.1", true),
        ("2.0", "10.0", true),
    ])
    func versionsCompareNumerically(installed: String, other: String, isOlder: Bool) throws {
        let lhs = try #require(AppVersion(installed))
        let rhs = try #require(AppVersion(other))
        #expect((lhs < rhs) == isOlder)
    }

    @Test func blocksOnlyBelowTheMinimum() throws {
        let config = AppConfig(json: Data(#"{"values":{"min_supported_version":"1.2.0","latest_version":"1.4.0"}}"#.utf8))

        #expect(config.requiresUpdate(current: try #require(AppVersion("1.1.9"))))
        #expect(!config.requiresUpdate(current: try #require(AppVersion("1.2.0"))))
        #expect(config.hasNewerVersion(than: try #require(AppVersion("1.3.0"))))
        #expect(!config.hasNewerVersion(than: try #require(AppVersion("1.4.0"))))
    }
}

@MainActor
struct AppConfigStoreTests {
    private let defaults: UserDefaults

    init() throws {
        let suite = "AppConfigStoreTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    private func makeStore(_ transport: FakeTransport) -> AppConfigStore {
        let configuration = APIConfiguration(baseURL: Fixtures.baseURL)
        let session = AuthSession(configuration: configuration, transport: transport, store: InMemorySecureStore())
        return AppConfigStore(api: APIClient(configuration: configuration, transport: transport, session: session), defaults: defaults)
    }

    @Test func savesTheAnswerAndRevalidatesWithItsETag() async throws {
        let transport = FakeTransport { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return FakeTransport.Reply(status: 304, body: Data())
            }
            return .json(200, #"{"values":{"links.support":"mailto:help@example.com"},"limits":{}}"#, headers: ["ETag": "\"v1\""])
        }

        let first = makeStore(transport)
        await first.refresh()
        #expect(first.config.supportURL == URL(string: "mailto:help@example.com"))
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)

        // A new launch: the saved answer is used at once, and 304 keeps it.
        let second = makeStore(transport)
        #expect(second.config.supportURL == URL(string: "mailto:help@example.com"))
        await second.refresh()
        #expect(second.config.supportURL == URL(string: "mailto:help@example.com"))
        #expect(await transport.requests.count == 2)
    }

    @Test func offlineKeepsTheBuiltInDefaults() async {
        let store = makeStore(FakeTransport { _ in throw URLError(.notConnectedToInternet) })

        await store.refresh()

        #expect(store.config == .defaults)
    }
}
