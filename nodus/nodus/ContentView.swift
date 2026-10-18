import SwiftData
import SwiftUI
import UserNotifications
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var localizer = NodusLocalizer(language: .defaultValue)
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage(
        "openVoiceComposerFromControl",
        store: UserDefaults(suiteName: NodusModelContainer.appGroupID)
    ) private var openVoiceComposerFromControl = false
    @State private var phase: Phase = .splash
    @State private var homeVisible = false
    @State private var viewModel: HomeTimelineViewModel?
    @State private var notificationScheduler: NotificationScheduler?
    @State private var pendingDeepLink: URL?

    let services: AppServices
    @ObservedObject private var appConfig: AppConfigStore
    @ObservedObject private var account: AccountService
    let notificationHandler: NotificationActionHandler

    init(services: AppServices, notificationHandler: NotificationActionHandler = NotificationActionHandler()) {
        self.services = services
        appConfig = services.appConfig
        account = services.account
        self.notificationHandler = notificationHandler
    }

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()

            switch phase {
            case .splash:
                if settingsStore.animatedSplashEnabled {
                    SplashRitualView(hapticsEnabled: settingsStore.hapticsEnabled, soundEnabled: settingsStore.inAppSoundsEnabled)
                        .transition(.opacity.animation(.easeInOut(duration: 1.1)))
                }
            case .onboarding:
                OnboardingView(continueAction: finishOnboarding)
                    .transition(.opacity.animation(.easeInOut(duration: 1.1)))
            case .home:
                if let viewModel {
                    HomeTimelineView(
                        viewModel: viewModel,
                        settingsStore: settingsStore,
                        aiAccessStore: services.aiAccessStore,
                        aiDrafts: services.aiDrafts,
                        account: services.account,
                        appConfig: services.appConfig,
                        connections: services.connections,
                        privacyPolicyURL: appConfig.config.privacyPolicyURL,
                        visible: homeVisible,
                        openVoiceComposerFromControl: $openVoiceComposerFromControl
                    )
                        .transition(.opacity.animation(.easeInOut(duration: 1.1)))
                }
            }
        }
        .sheet(isPresented: $account.isSessionEnded) {
            SessionEndedView(language: settingsStore.appLanguage, account: account)
        }
        .overlay {
            if appConfig.requiresUpdate {
                UpdateRequiredView(language: settingsStore.appLanguage, appStoreURL: appConfig.config.appStoreURL)
                    .transition(.opacity)
            }
        }
        .environmentObject(localizer)
        .environment(\.locale, locale)
        .task {
            configureIfNeeded()
            await playIntro()
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            if newPhase == .background {
                services.sync.enterBackground()
            }
            guard newPhase == .active else { return }
            viewModel?.load(rescheduleNotifications: false)
            // Network never blocks the screen: the account and the data
            // catch up in the background.
            Task { await services.account.refresh() }
            services.sync.enterForeground()
            Task { await registerForPushIfAllowed() }
            Task {
                await appConfig.refresh()
                if appConfig.shouldOfferUpdate() {
                    viewModel?.presentToast(settingsStore.appLanguage.localizedString("A new version of Nodus is available"))
                }
            }
        }
        .onOpenURL { url in
            // An invitation link (Universal Link) is handled as `nodus://invite/{token}`.
            if url.scheme == "https", url.host == "nodus.app", url.pathComponents.dropFirst().first == "invite",
               let token = url.pathComponents.dropFirst(2).first {
                acceptInvite(token: token)
                return
            }
            guard url.scheme == "nodus" else { return }
            configureIfNeeded()

            guard phase != .splash else {
                pendingDeepLink = url
                return
            }

            openDeepLink(url)
        }
    }

    private func openDeepLink(_ url: URL) {
        guard let action = url.host else { return }

        switch action {
            case "create":
                viewModel?.isShowingEditor = true
            case "voice":
                openVoiceComposerFromControl = true
            case "invite":
                if let token = url.pathComponents.dropFirst().first {
                    acceptInvite(token: token)
                }
            case "node":
                guard
                    let rawNodeID = url.pathComponents.dropFirst().first,
                    let nodeID = UUID(uuidString: rawNodeID)
                else { return }
                let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "action" })?
                    .value
                switch action {
                case "snooze":
                    Task {
                        await viewModel?.snooze(by: 15 * 60, nodeId: nodeID, occurrenceDate: nil)
                    }
                case "untie":
                    Task {
                        await viewModel?.untie(nodeId: nodeID, occurrenceDate: nil)
                    }
                default:
                    viewModel?.presentDetail(nodeId: nodeID, occurrenceDate: nil)
                }
            default:
                break
        }
    }

    private var locale: Locale {
        switch settingsStore.appLanguage {
        case .ru:
            Locale(identifier: "ru")
        case .en:
            Locale(identifier: "en")
        }
    }

    /// Accepting needs the network; the answer says what happened.
    private func acceptInvite(token: String) {
        let language = settingsStore.appLanguage
        Task {
            do {
                let connection = try await services.connections.accept(token: token)
                viewModel?.presentToast(InviteResult.message(for: connection, language: language))
            } catch let error as ConnectionsService.InviteError {
                viewModel?.presentToast(InviteResult.message(for: error, language: language))
            } catch {
                viewModel?.presentToast(language.localizedString("Something went wrong. Try again"))
            }
        }
    }

    /// Remote notifications only after the user allowed notifications in
    /// context; a refusal blocks nothing (push only announces sync data).
    private func registerForPushIfAllowed() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func configureIfNeeded() {
        guard viewModel == nil else { return }

        let repository = SwiftDataNodeRepository(context: modelContext)
        let scheduler = NotificationScheduler()
        scheduler.registerCategories(settings: settingsStore.snapshot)
        notificationScheduler = scheduler
        let reminderService = ReminderService(
            repository: repository,
            notificationScheduler: scheduler,
            didEnqueue: { [sync = services.sync] in sync.localChangeQueued() }
        )
        let createdViewModel = HomeTimelineViewModel(
            repository: repository,
            timelineService: TimelineService(),
            reminderService: reminderService,
            notificationScheduler: scheduler,
            settingsStore: settingsStore
        )
        viewModel = createdViewModel
        localizer.update(language: settingsStore.appLanguage)

        // Sync writes through its own context; screens re-read afterwards.
        services.sync.onDataChanged = { [weak createdViewModel, aiDrafts = services.aiDrafts, connections = services.connections] in
            createdViewModel?.load(rescheduleNotifications: true)
            aiDrafts.dataChanged()
            connections.reload()
        }
        services.aiDrafts.toast = { [weak createdViewModel] in createdViewModel?.presentToast($0) }
        services.presentToast = { [weak createdViewModel] in createdViewModel?.presentToast($0) }

        services.push.destinations = PushRouter.Destinations(
            sync: { [sync = services.sync] in await sync.syncNow() },
            toast: { [weak createdViewModel] in createdViewModel?.presentToast($0) },
            openDraftsReview: { [aiDrafts = services.aiDrafts] in aiDrafts.openJob(id: $0) },
            openNode: { [weak createdViewModel] in createdViewModel?.openNode($0) ?? false },
            openImport: { [weak createdViewModel] in createdViewModel?.openImportJob($0) }
        )
        notificationHandler.setPushHandler { [push = services.push] payload, isTap in
            if isTap {
                await push.tapped(payload)
            } else {
                await push.received(payload)
            }
        }
        services.sync.start()

        notificationHandler.setActionHandler { action, nodeId, occurrenceDate in
            switch action {
            case .open:
                createdViewModel.presentDetail(nodeId: nodeId, occurrenceDate: occurrenceDate)
            case .untie:
                await createdViewModel.untie(nodeId: nodeId, occurrenceDate: occurrenceDate)
            case .snooze(let kind):
                await createdViewModel.snooze(using: kind, nodeId: nodeId, occurrenceDate: occurrenceDate)
            }
        }
    }

    private func playIntro() async {
        guard settingsStore.animatedSplashEnabled else {
            await showInitialScreen()
            return
        }

        try? await Task.sleep(for: .milliseconds(5500))
        await showInitialScreen()
    }

    private func showInitialScreen() async {
        guard !hasSeenOnboarding && pendingDeepLink == nil else {
            await revealHome()
            return
        }

        withAnimation(.easeInOut(duration: 1.05)) {
            phase = .onboarding
        }
    }

    private func finishOnboarding() {
        hasSeenOnboarding = true
        Task {
            withAnimation(.easeInOut(duration: 0.7)) {
                phase = .home
            }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeOut(duration: 1.0)) {
                homeVisible = true
            }
        }
    }

    private func revealHome() async {
        withAnimation(.easeInOut(duration: 1.05)) {
            phase = .home
        }

        try? await Task.sleep(for: .milliseconds(220))

        withAnimation(.easeOut(duration: 1.0)) {
            homeVisible = true
        }
        openPendingDeepLink()
    }

    private func openPendingDeepLink() {
        guard let pendingDeepLink else { return }
        self.pendingDeepLink = nil
        openDeepLink(pendingDeepLink)
    }
}

private enum Phase {
    case splash
    case onboarding
    case home
}

#Preview {
    ContentView(services: AppServices())
}
