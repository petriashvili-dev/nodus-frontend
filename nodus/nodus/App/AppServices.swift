import Foundation

/// The app's long-lived services, created once at launch. Views receive what
/// they need from here; nothing in it is a view model.
@MainActor
final class AppServices {
    let configuration: APIConfiguration
    let secureStore: SecureStore
    let session: AuthSession
    let api: APIClient
    let aiAccessStore: AIAccessStore
    let account: AccountService

    init(
        configuration: APIConfiguration = .live,
        transport: HTTPTransport = URLSessionTransport(),
        secureStore: SecureStore = KeychainStore(),
        aiAccessStore: AIAccessStore? = nil
    ) {
        self.configuration = configuration
        self.secureStore = secureStore
        let aiAccessStore = aiAccessStore ?? AIAccessStore()
        self.aiAccessStore = aiAccessStore
        session = AuthSession(configuration: configuration, transport: transport, store: secureStore)
        api = APIClient(configuration: configuration, transport: transport, session: session)
        account = AccountService(api: api, session: session, store: secureStore, aiAccessStore: aiAccessStore)
    }
}
