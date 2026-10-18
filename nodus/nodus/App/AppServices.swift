import Foundation
import SwiftData

/// The app's long-lived services, created once at launch. Views receive what
/// they need from here; nothing in it is a view model.
@MainActor
final class AppServices {
    let configuration: APIConfiguration
    let secureStore: SecureStore
    let modelContainer: ModelContainer
    let session: AuthSession
    let api: APIClient
    let aiAccessStore: AIAccessStore
    let account: AccountService
    let sync: SyncCoordinator

    init(
        configuration: APIConfiguration = .live,
        transport: HTTPTransport = URLSessionTransport(),
        secureStore: SecureStore = KeychainStore(),
        modelContainer: ModelContainer? = nil,
        aiAccessStore: AIAccessStore? = nil
    ) {
        self.configuration = configuration
        self.secureStore = secureStore
        do {
            self.modelContainer = try modelContainer ?? NodusModelContainer.make()
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        let aiAccessStore = aiAccessStore ?? AIAccessStore()
        self.aiAccessStore = aiAccessStore

        // Session losses and sync events arrive off the main actor; the relay
        // forwards them once everything below exists.
        let relay = EventRelay()
        session = AuthSession(
            configuration: configuration,
            transport: transport,
            store: secureStore,
            onLoss: { loss in Task { @MainActor in relay.sessionLost?(loss) } }
        )
        api = APIClient(configuration: configuration, transport: transport, session: session)
        account = AccountService(api: api, session: session, store: secureStore, aiAccessStore: aiAccessStore)
        let engine = SyncEngine(
            container: self.modelContainer,
            api: api,
            session: session,
            events: SyncEngine.Events(
                profile: { profile in Task { @MainActor in relay.profile?(profile) } },
                accessRefused: { Task { @MainActor in relay.accessRefused?() } }
            )
        )
        sync = SyncCoordinator(engine: engine)
        sync.attach(EventStream(
            configuration: configuration,
            session: session,
            cursor: { await engine.currentCursor() },
            onSignal: { Task { @MainActor in relay.syncSignal?() } }
        ))

        relay.profile = { [account] in account.apply($0) }
        relay.accessRefused = { [account] in Task { await account.refresh() } }
        relay.sessionLost = { [sync] _ in sync.requestSync() }
        relay.syncSignal = { [sync] in sync.requestSync() }
    }
}

@MainActor
private final class EventRelay {
    var profile: ((UserProfileDTO) -> Void)?
    var accessRefused: (() -> Void)?
    var sessionLost: ((AuthSession.Loss) -> Void)?
    var syncSignal: (() -> Void)?
}
