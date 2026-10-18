import Foundation
import CoreGraphics
import Combine
import SwiftData
import UserNotifications
#if os(iOS)
import WidgetKit
#endif

enum DayTimelineState: Equatable {
    case empty
    case lost
    case completed
    case active
}

enum SmartPhraseAnimation: Equatable {
    case none
    case appear
    case crossfade
    case typewriter
}

struct EditingKnot: Identifiable {
    let item: TimelineItem
    let draft: ReminderDraft
    var id: String { item.id }
}

struct PausedKnot: Identifiable {
    let nodeId: UUID
    let title: String
    let resumesAt: Date

    var id: UUID { nodeId }
}

@MainActor
final class HomeTimelineViewModel: ObservableObject {
    @Published private(set) var sections: [TimelineSectionModel] = []
    @Published private(set) var lostItems: [TimelineItem] = []
    @Published private(set) var pausedKnots: [PausedKnot] = []
    @Published private(set) var dayState: DayTimelineState = .empty
    @Published private(set) var smartPhrase = ""
    @Published private(set) var smartPhraseAnimation: SmartPhraseAnimation = .appear
    @Published private(set) var smartPhraseEvent = 0
    @Published var selectedItem: TimelineItem?
    @Published var isShowingEditor = false
    @Published var isShowingSettings = false
    @Published var editingKnot: EditingKnot?
    @Published var retieTarget: TimelineItem?
    @Published var pauseTarget: TimelineItem?
    @Published var actionMenuItem: TimelineItem?
    @Published var actionMenuAnchor: CGRect = .zero
    @Published var permissionPromptDraft: ReminderDraft?
    @Published var errorMessage: String?
    @Published var toast: ToastPresentation?

    /// How long a plain confirmation toast (tie/update/untie) stays up.
    static let toastDuration: Double = 2
    /// How long the delete toast's undo window actually stays open before
    /// the knot is gone for real — must match the undo ring's fill time,
    /// since that ring is what visually promises the user how much time
    /// they have left.
    static let deleteUndoDuration: Double = 2

    private let repository: NodeRepositoryProtocol
    private let timelineService: TimelineService
    private let reminderService: ReminderService
    private let notificationScheduler: NotificationScheduling
    private let settingsStore: SettingsStore
    private var hasLoadedTimeline = false
    private var currentDayKey: String?
    private var phraseByDayState: [String: String] = [:]
    private let lastAnimatedDayKey = "nodus.lastAnimatedSmartPhraseDay"
    private var toastDismissTask: Task<Void, Never>?
    private var pendingDelete: (node: ReminderNode, task: Task<Void, Never>)?
    private var notificationRescheduleTask: Task<Void, Never>?
    private var cachedNodes: [ReminderNode] = []
    private var cachedOccurrenceStates: [ReminderOccurrenceState] = []
    private var cachedOccurrenceOverrides: [ReminderOccurrenceOverride] = []
    private var cachedServerOccurrences: [ServerOccurrence] = []
    private var locallyChangedNodeIds: Set<UUID> = []
    private var hasDatabaseSnapshot = false

    private var locale: Locale { settingsStore.appLanguage.locale }

    init(
        repository: NodeRepositoryProtocol,
        timelineService: TimelineService,
        reminderService: ReminderService,
        notificationScheduler: NotificationScheduling,
        settingsStore: SettingsStore
    ) {
        self.repository = repository
        self.timelineService = timelineService
        self.reminderService = reminderService
        self.notificationScheduler = notificationScheduler
        self.settingsStore = settingsStore
        self.smartPhrase = settingsStore.appLanguage.localizedString("Today the thread is free")
    }

    func load(now: Date = Date(), rescheduleNotifications: Bool = true) {
        do {
            let occurrenceWindowStart = Calendar.current.date(byAdding: .day, value: -3, to: now) ?? now
            cachedNodes = try repository.fetchNodes()
            // The timeline only renders the recent lost window plus the next
            // occurrence. Loading years of completed/overridden history is
            // both invisible and unnecessary for an immediate local read.
            cachedOccurrenceStates = try repository.fetchOccurrenceStates(since: occurrenceWindowStart)
            cachedOccurrenceOverrides = try repository.fetchOccurrenceOverrides(since: occurrenceWindowStart)
            cachedServerOccurrences = try repository.fetchServerOccurrences()
            locallyChangedNodeIds = try repository.nodesWithUnsyncedTemplate()
            hasDatabaseSnapshot = true
            rebuildTimeline(now: now, rescheduleNotifications: rescheduleNotifications)
        } catch {
            errorMessage = settingsStore.appLanguage.localizedString("Could not load the thread.")
        }
    }

    /// Rebuilds only the in-memory presentation. Settings changes should be
    /// immediate and must not re-query the local store or block a sheet.
    func refreshPresentation(now: Date = Date(), rescheduleNotifications: Bool = false) {
        guard hasDatabaseSnapshot else {
            load(now: now, rescheduleNotifications: rescheduleNotifications)
            return
        }
        rebuildTimeline(now: now, rescheduleNotifications: rescheduleNotifications)
    }

    private func rebuildTimeline(now: Date, rescheduleNotifications: Bool) {
        let nodes = cachedNodes
        sections = timelineService.buildTimeline(
            nodes: nodes,
            states: cachedOccurrenceStates,
            overrides: cachedOccurrenceOverrides,
            serverOccurrences: cachedServerOccurrences,
            locallyChangedNodeIds: locallyChangedNodeIds,
            settings: settingsStore.snapshot,
            now: now
        )
        pausedKnots = nodes.compactMap { node in
                guard node.isRepeating, let pausedUntil = node.pausedUntil, pausedUntil > now else { return nil }
                return PausedKnot(nodeId: node.id, title: node.title, resumesAt: pausedUntil)
            }
            .sorted { $0.resumesAt < $1.resumesAt }
        WidgetSnapshotWriter.write(sections: sections, now: now)
        lostItems = timelineService.lostItems(in: sections)
            .filter { Calendar.current.isDateInToday($0.scheduledAt) }
        updateDayState(now: now)
        if rescheduleNotifications {
            let plan = timelineService.notificationPlan(
                timeline: sections,
                nodes: nodes,
                states: cachedOccurrenceStates,
                overrides: cachedOccurrenceOverrides,
                serverOccurrences: cachedServerOccurrences,
                locallyChangedNodeIds: locallyChangedNodeIds,
                settings: settingsStore.snapshot,
                now: now
            )
            scheduleNotificationRefresh(nodes: nodes, plan: plan, settings: settingsStore.snapshot)
        }
    }

    private func scheduleNotificationRefresh(
        nodes: [ReminderNode],
        plan: [TimelineItem],
        settings: SettingsSnapshot
    ) {
        notificationRescheduleTask?.cancel()
        notificationRescheduleTask = Task { [notificationScheduler] in
            // Coalesce a burst of model/settings changes into one system
            // notification pass. Local-notification queries are expensive and
            // need not run while the user is still editing a knot.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await notificationScheduler.rescheduleAll(nodes: nodes, plan: plan, settings: settings)
        }
    }

    var hasTodayKnots: Bool {
        dayState != .empty
    }

    /// Whether the thread has anything at all to show — today or any
    /// future section. Drives whether we render the full thread or fall
    /// back to the empty-state illustration.
    var hasAnyKnots: Bool {
        sections.flatMap(\.items).contains { $0.title != nil }
    }

    func node(for item: TimelineItem) -> ReminderNode? {
        cachedNodes.first { $0.id == item.nodeId }
    }

    func activeNodesArchive() throws -> NodusArchive {
        let activeNodes = cachedNodes.filter { $0.status == .active }
        return NodusArchive(nodes: activeNodes)
    }

    @discardableResult
    func importArchive(_ archive: NodusArchive) throws -> Int {
        let nodes = archive.makeNodes()
        guard !nodes.isEmpty else { throw NodusArchiveError.empty }
        try repository.saveNodes(nodes)
        load(rescheduleNotifications: true)
        return nodes.count
    }

    /// Builds an editable draft (title, note, type, date) from the node
    /// behind this item, so the existing knot editor can be reused to
    /// change them in place, instead of only retying or deleting.
    func beginEditing(_ item: TimelineItem) {
        guard let node = node(for: item) else { return }
        // A stale date makes the editor impossible to save and is not useful
        // as a starting point. For a future occurrence preserve its effective
        // timeline date (including a previous retie); otherwise offer the
        // same first valid slot used by the new-knot flow.
        let scheduledAt = item.scheduledAt >= Date()
            ? item.scheduledAt
            : .earliestReminderTime()
        let draft = ReminderDraft(
            title: node.title,
            note: node.note ?? "",
            scheduledAt: scheduledAt,
            originDate: node.originDate,
            repeatSchedule: node.repeatSchedule,
            leadTimes: node.leadTimes
        )
        editingKnot = EditingKnot(item: item, draft: draft)
    }

    func saveEdit(_ draft: ReminderDraft, item: TimelineItem) async {
        guard let node = node(for: item) else { return }
        do {
            let scheduleChanged = node.scheduledAt != draft.scheduledAt
            try await reminderService.update(node: node, with: draft, settings: settingsStore.snapshot)
            editingKnot = nil
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString(scheduleChanged ? "Knot retied." : "Knot updated."))
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func saveDraft(_ draft: ReminderDraft) async {
        if !draft.leadTimes.isEmpty && settingsStore.notificationsEnabled {
            let status = await notificationScheduler.authorizationStatus()
            if status == .notDetermined {
                permissionPromptDraft = draft
                return
            }
        }

        await tie(draft)
    }

    func approveNotificationsAndTie() async {
        guard var draft = permissionPromptDraft else { return }
        permissionPromptDraft = nil
        let granted = await notificationScheduler.requestAuthorization()
        if !granted {
            draft.leadTimes = []
        }
        await tie(draft)
    }

    func tieWithoutNotifications() async {
        guard var draft = permissionPromptDraft else { return }
        permissionPromptDraft = nil
        draft.leadTimes = []
        await tie(draft)
    }

    /// Voice text becomes knots only through the backend AI drafts flow
    /// (`POST /v1/ai/node-drafts`) — the client never calls a model itself.
    /// Until that flow is connected the entry point is hidden, so this is
    /// reachable only from a stale composer and answers neutrally.
    func submitVoiceTranscript(_ text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        presentFeatureUnavailable()
        return false
    }

    /// The only wording an unavailable AI feature ever gets: no plans,
    /// subscriptions or "coming soon" (see DESIGN_SYSTEM.md §7).
    func presentFeatureUnavailable() {
        presentToast(settingsStore.appLanguage.localizedString("This feature is currently unavailable."))
    }

    func untie(_ item: TimelineItem) async {
        await untie(nodeId: item.nodeId, occurrenceDate: item.occurrenceDate)
    }

    /// A future knot only needs its active state restored. A past knot needs
    /// a fresh date, so it goes through the existing retie sheet instead.
    func tie(_ item: TimelineItem) async {
        guard item.scheduledAt < Date() else {
            await activate(item)
            return
        }
        retieTarget = item
    }

    private func activate(_ item: TimelineItem) async {
        guard let node = node(for: item) else { return }
        do {
            if let state = try await reminderService.activate(node: node, occurrenceDate: item.occurrenceDate) {
                cache(state: state)
            }
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString("Knot activated."))
        } catch {
            errorMessage = settingsStore.appLanguage.localizedString("Could not activate the knot.")
        }
    }

    func retie(_ item: TimelineItem, to date: Date) async {
        await retie(nodeId: item.nodeId, occurrenceDate: item.occurrenceDate, to: date)
    }

    func pause(_ item: TimelineItem, until date: Date) async {
        guard let node = node(for: item) else { return }
        await pause(node: node, until: date)
        pauseTarget = nil
    }

    func pause(nodeId: UUID, until date: Date) async {
        guard let node = cachedNodes.first(where: { $0.id == nodeId }) else { return }
        await pause(node: node, until: date)
    }

    private func pause(node: ReminderNode, until date: Date) async {
        do {
            try await reminderService.pause(node: node, until: date)
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString("Knot paused."))
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func resumePausedKnot(nodeId: UUID) async {
        guard let node = cachedNodes.first(where: { $0.id == nodeId }) else { return }
        do {
            try await reminderService.resume(node: node)
            refreshPresentation(rescheduleNotifications: true)
            presentToast("Пауза снята.")
        } catch {
            errorMessage = settingsStore.appLanguage.localizedString("Could not activate the knot.")
        }
    }

    /// Shared by the row-tap flow above and the notification quick actions
    /// below — both ultimately just need a node id, not a `TimelineItem`.
    func untie(nodeId: UUID, occurrenceDate: Date?) async {
        guard let node = cachedNodes.first(where: { $0.id == nodeId }) else { return }
        do {
            if let state = try await reminderService.untie(node: node, occurrenceDate: occurrenceDate) {
                cache(state: state)
            }
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString("Knot untied."))
        } catch {
            errorMessage = settingsStore.appLanguage.localizedString("Could not tie the knot.")
        }
    }

    func retie(nodeId: UUID, occurrenceDate: Date?, to date: Date) async {
        guard let node = cachedNodes.first(where: { $0.id == nodeId }) else { return }
        do {
            // Notifications created before occurrence identities were added
            // have no timestamp for a repeating knot. Its first occurrence
            // is still unambiguous, so retain compatibility with those
            // already-pending notifications rather than moving the whole
            // series as though it were a one-off knot.
            let occurrenceIdentity = occurrenceDate ?? (node.isRepeating ? node.scheduledAt : nil)
            try await reminderService.retie(node: node, occurrenceDate: occurrenceIdentity, to: date, settings: settingsStore.snapshot)
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString("Knot retied."))
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    /// Snoozing from a notification's quick action skips straight to a
    /// fixed offset — no picker to round through — so it rounds here
    /// instead, the same way every other quick-offset action in the app
    /// does, to avoid landing on an off-grid time like 18:01.
    func snooze(by interval: TimeInterval, nodeId: UUID, occurrenceDate: Date?) async {
        await retie(nodeId: nodeId, occurrenceDate: occurrenceDate, to: Date().addingTimeInterval(interval).roundedToNearest5Minutes())
    }

    func snooze(using kind: ReminderQuickPreset.Kind, nodeId: UUID, occurrenceDate: Date?) async {
        let presets = ReminderQuickPreset.all(settings: settingsStore.snapshot)
        let date = presets.first(where: { $0.kind == kind })?.date
            ?? Date().addingTimeInterval(15 * 60).roundedToNearest5Minutes()
        await retie(nodeId: nodeId, occurrenceDate: occurrenceDate, to: date)
    }

    func refreshQuickPresetNotifications() {
        notificationScheduler.registerCategories(settings: settingsStore.snapshot)
        refreshPresentation(rescheduleNotifications: true)
    }

    /// Opens the same detail sheet a row tap would, located by node id
    /// since a notification only carries identifiers, not a `TimelineItem`.
    func presentDetail(nodeId: UUID, occurrenceDate: Date?) {
        refreshPresentation(rescheduleNotifications: false)
        let allItems = sections.flatMap(\.items) + lostItems
        if let occurrenceDate, let match = allItems.first(where: { $0.nodeId == nodeId && $0.occurrenceDate == occurrenceDate }) {
            selectedItem = match
        } else {
            selectedItem = allItems.first { $0.nodeId == nodeId }
        }
    }

    func presentActionMenu(for item: TimelineItem, anchor: CGRect) {
        actionMenuAnchor = anchor
        actionMenuItem = item
    }

    func dismissActionMenu() {
        actionMenuItem = nil
    }

    /// Doesn't delete anything right away — the toast's undo ring is the
    /// real deadline. The knot only actually goes once that ring finishes
    /// filling; tapping undo within the window cancels the pending task
    /// and the knot is never touched.
    func delete(_ item: TimelineItem) {
        guard let node = node(for: item) else { return }
        pendingDelete?.task.cancel()

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.deleteUndoDuration))
            guard !Task.isCancelled else { return }
            await self?.finalizeDelete(node: node)
        }
        pendingDelete = (node: node, task: task)

        toastDismissTask?.cancel()
        toast = ToastPresentation(text: settingsStore.appLanguage.localizedString("Knot deleted."), onUndo: { [weak self] in
            self?.cancelPendingDelete()
        })
    }

    private func cancelPendingDelete() {
        pendingDelete?.task.cancel()
        pendingDelete = nil
        toast = nil
    }

    private func finalizeDelete(node: ReminderNode) async {
        pendingDelete = nil
        do {
            try await reminderService.delete(node: node)
            cachedNodes.removeAll { $0.id == node.id }
            cachedOccurrenceStates.removeAll { $0.reminderId == node.id }
            cachedOccurrenceOverrides.removeAll { $0.reminderId == node.id }
            refreshPresentation(rescheduleNotifications: true)
        } catch {
            errorMessage = localizedMessage(for: error)
        }
        toast = nil
    }

    private func cache(state: ReminderOccurrenceState) {
        cachedOccurrenceStates.removeAll {
            $0.reminderId == state.reminderId && $0.occurrenceDate == state.occurrenceDate
        }
        cachedOccurrenceStates.append(state)
    }

    private func localizedMessage(for error: Error) -> String {
        if let reminderError = error as? ReminderError {
            return reminderError.message(language: settingsStore.appLanguage)
        }
        return error.localizedDescription
    }

    /// Plain confirmations (tie/update/untie) — shown briefly with no
    /// action attached, unlike the undoable delete toast above.
    func presentToast(_ text: String) {
        toastDismissTask?.cancel()
        toast = ToastPresentation(text: text)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastDuration))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func tie(_ draft: ReminderDraft) async {
        do {
            let node = try await reminderService.tie(draft, settings: settingsStore.snapshot)
            cachedNodes.append(node)
            isShowingEditor = false
            refreshPresentation(rescheduleNotifications: true)
            presentToast(settingsStore.appLanguage.localizedString("Knot tied."))
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    private func updateDayState(now: Date = Date()) {
        let todayItems = sections
            .flatMap(\.items)
            .filter { item in
                item.title != nil && Calendar.current.isDateInToday(item.scheduledAt)
            }

        let newState: DayTimelineState
        if todayItems.isEmpty {
            newState = .empty
        } else if todayItems.contains(where: \.isLost) {
            newState = .lost
        } else if todayItems.allSatisfy({ $0.status == .completed }) {
            newState = .completed
        } else {
            newState = .active
        }

        let dayKey = Self.dayKey(for: now)
        // The empty-thread copy has a morning-only variant. Include that
        // window in the cache key so a phrase selected in the morning cannot
        // linger through the afternoon just because the day state is still
        // `.empty`.
        let stateKey = "\(dayKey)-\(newState)-\(Self.phraseTimeWindow(for: newState, now: now))"
        let isFirstLoad = !hasLoadedTimeline
        let isNewCalendarDay = currentDayKey != nil && currentDayKey != dayKey
        let stateChanged = !isFirstLoad && (newState != dayState || isNewCalendarDay)
        let selectedPhrase = phraseByDayState[stateKey] ?? Self.phrase(for: newState, now: now, language: settingsStore.appLanguage)
        phraseByDayState[stateKey] = selectedPhrase

        let animation = animationForPhraseChange(
            from: dayState,
            to: newState,
            dayKey: dayKey,
            isFirstLoad: isFirstLoad,
            isNewCalendarDay: isNewCalendarDay,
            stateChanged: stateChanged
        )

        dayState = newState
        currentDayKey = dayKey
        hasLoadedTimeline = true

        // Deliberately not comparing `smartPhraseAnimation` here: it holds
        // whichever animation a *past* change used, not a persistent
        // display state, so comparing it against the freshly computed
        // `animation` (almost always `.none` once nothing is changing)
        // used to bump `smartPhraseEvent` on every per-minute clock tick
        // even when nothing actually changed — an extra, pointless
        // `runAnimation()` call once a minute.
        guard isFirstLoad || stateChanged || smartPhrase != selectedPhrase else {
            return
        }

        smartPhrase = selectedPhrase
        smartPhraseAnimation = animation
        smartPhraseEvent += 1
    }

    private static func phrase(for state: DayTimelineState, now: Date, language: AppLanguage) -> String {
        let phrases: [String]
        switch state {
        case .empty:
            // "The day is just beginning" is only appropriate in the
            // morning. Once the afternoon starts, keep the wording neutral
            // rather than letting a morning phrase remain on screen.
            if Calendar.current.component(.hour, from: now) >= 12 {
                phrases = [
                    language.localizedString("Today the thread is free"),
                    language.localizedString("Nothing is tied today yet")
                ]
            } else {
                phrases = [
                    language.localizedString("Today the thread is free"),
                    language.localizedString("The day is just beginning"),
                    language.localizedString("A good time to tie the first knot"),
                    language.localizedString("Nothing is tied today yet")
                ]
            }
        case .active:
            phrases = [
                language.localizedString("Today is manageable"),
                language.localizedString("The thread is beginning to take shape"),
                language.localizedString("One knot at a time"),
                language.localizedString("Everything is moving in its own rhythm")
            ]
        case .lost:
            phrases = [
                language.localizedString("One knot is still waiting"),
                language.localizedString("Not every knot stays held"),
                language.localizedString("There is room to return what was lost")
            ]
        case .completed:
            phrases = [
                language.localizedString("All knots are untied"),
                language.localizedString("Today’s thread is complete"),
                language.localizedString("Good work")
            ]
        }
        return phrases.randomElement() ?? phrases[0]
    }

    private static func phraseTimeWindow(for state: DayTimelineState, now: Date) -> String {
        guard state == .empty else { return "all-day" }
        return Calendar.current.component(.hour, from: now) < 12 ? "morning" : "afternoon"
    }

    private func animationForPhraseChange(
        from previousState: DayTimelineState,
        to newState: DayTimelineState,
        dayKey: String,
        isFirstLoad: Bool,
        isNewCalendarDay: Bool,
        stateChanged: Bool
    ) -> SmartPhraseAnimation {
        if isFirstLoad {
            let lastAnimatedDay = UserDefaults.standard.string(forKey: lastAnimatedDayKey)
            if lastAnimatedDay != dayKey {
                UserDefaults.standard.set(dayKey, forKey: lastAnimatedDayKey)
                return .typewriter
            }
            return .appear
        }

        if isNewCalendarDay {
            UserDefaults.standard.set(dayKey, forKey: lastAnimatedDayKey)
            return .typewriter
        }

        guard stateChanged else { return .none }

        if previousState == .empty && newState == .active {
            return .typewriter
        }

        if newState == .completed && previousState != .completed {
            return .typewriter
        }

        return .crossfade
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
