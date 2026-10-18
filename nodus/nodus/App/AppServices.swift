import Foundation
import SwiftData
import UserNotifications

/// The app's long-lived services, created once at launch. Views receive what
/// they need from here; nothing in it is a view model.
@MainActor
final class AppServices {
    /// The app and its in-process intents (Siri) share one set of services.
    static let shared = AppServices()

    let configuration: APIConfiguration
    let secureStore: SecureStore
    let modelContainer: ModelContainer
    let session: AuthSession
    let api: APIClient
    let aiAccessStore: AIAccessStore
    let appConfig: AppConfigStore
    let account: AccountService
    let sync: SyncCoordinator
    let aiDrafts: AIDraftsCoordinator
    /// A short message on the current screen; set by `ContentView`.
    var presentToast: (String) -> Void = { _ in }

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
        appConfig = AppConfigStore(api: api)
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

        aiDrafts = AIDraftsCoordinator(service: AIDraftsService(
            context: self.modelContainer.mainContext,
            api: api,
            aiAccessStore: aiAccessStore,
            account: account,
            didEnqueue: { [sync] in sync.localChangeQueued() }
        ))

        let mainContext = self.modelContainer.mainContext
        account.enqueue = { [sync] operation in
            mainContext.insert(operation)
            try mainContext.save()
            sync.localChangeQueued()
        }
        account.resetLocalData = { [sync] userId in
            try? await engine.wipeLocalData(for: userId)
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            sync.onDataChanged()
            sync.requestSync()
        }

        relay.profile = { [account] in account.apply($0) }
        relay.accessRefused = { [account] in Task { await account.refresh() } }
        relay.sessionLost = { [weak self, account, sync] loss in
            switch loss {
            case .sessionEnded:
                account.isSessionEnded = true
            case .anonymousAccountReplaced:
                // The old anonymous account is unreachable; this device's
                // knots are uploaded into the new one by the next sync.
                self?.presentToast(AppLanguage.defaultValue.localizedString("The previous session was lost. Knots on this device are kept"))
                sync.requestSync()
            }
        }
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
