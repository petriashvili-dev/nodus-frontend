import SwiftData
import SwiftUI
import UserNotifications

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

    let notificationHandler: NotificationActionHandler

    init(notificationHandler: NotificationActionHandler = NotificationActionHandler()) {
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
                        visible: homeVisible,
                        openVoiceComposerFromControl: $openVoiceComposerFromControl
                    )
                        .transition(.opacity.animation(.easeInOut(duration: 1.1)))
                }
            }
        }
        .environmentObject(localizer)
        .environment(\.locale, locale)
        .task {
            configureIfNeeded()
            await playIntro()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel?.load(rescheduleNotifications: false)
        }
        .onOpenURL { url in
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
            case "subscription":
                viewModel?.isShowingSettings = true
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

    private func configureIfNeeded() {
        guard viewModel == nil else { return }

        let repository = SwiftDataNodeRepository(context: modelContext)
        let scheduler = NotificationScheduler()
        scheduler.registerCategories(settings: settingsStore.snapshot)
        notificationScheduler = scheduler
        let reminderService = ReminderService(repository: repository, notificationScheduler: scheduler)
        let createdViewModel = HomeTimelineViewModel(
            repository: repository,
            timelineService: TimelineService(),
            reminderService: reminderService,
            notificationScheduler: scheduler,
            settingsStore: settingsStore
        )
        viewModel = createdViewModel
        localizer.update(language: settingsStore.appLanguage)

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
    ContentView()
}
