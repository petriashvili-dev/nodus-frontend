import SwiftUI

struct HomeTimelineView: View {
    @ObservedObject var viewModel: HomeTimelineViewModel
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var aiAccessStore: AIAccessStore
    @ObservedObject var aiDrafts: AIDraftsCoordinator
    @ObservedObject var account: AccountService
    let appConfig: AppConfigStore
    @ObservedObject var connections: ConnectionsService
    let privacyPolicyURL: URL
    let visible: Bool
    @Binding var openVoiceComposerFromControl: Bool
    @State private var currentDate = Date()
    @State private var phraseWidth: CGFloat = 0
    @StateObject private var speech = SpeechTranscriptionService()
    @State private var isShowingVoiceComposer = false
    @State private var isShowingVoicePermissionPrimer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            background
            timelineScroll
            topBar
            floatingButton

            if isShowingVoiceComposer && canUseVoiceDrafts {
                VoiceInputComposer(
                    speech: speech,
                    language: settingsStore.appLanguage,
                    isSubmitting: aiDrafts.phase == .sending,
                    cancel: dismissVoiceComposer,
                    submit: submitVoiceTranscript
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(8)
            }

            if isShowingWaitingCard {
                AIDraftsWaitingCard(
                    language: settingsStore.appLanguage,
                    isAccepted: aiDrafts.phase != .sending,
                    close: { aiDrafts.closeWaiting() }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(8)
            }

            if let item = viewModel.actionMenuItem {
                KnotActionMenuOverlay(
                    item: item,
                    anchor: viewModel.actionMenuAnchor,
                    dismiss: { viewModel.dismissActionMenu() },
                    untie: { Task { await viewModel.untie(item) } },
                    tie: { Task { await viewModel.tie(item) } },
                    retie: { viewModel.retieTarget = item },
                    pause: { viewModel.pauseTarget = item },
                    delete: { viewModel.delete(item) }
                )
                .zIndex(10)
            }

            if let toast = viewModel.toast {
                ToastView(
                    toast: toast,
                    undoDuration: toast.onUndo != nil ? HomeTimelineViewModel.deleteUndoDuration : HomeTimelineViewModel.toastDuration
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 16)
                    .safeAreaPadding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .offset(y: -14).combined(with: .opacity),
                        removal: .offset(y: -14).combined(with: .opacity)
                    ))
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.8).delay(0.18), value: viewModel.toast?.id)
        .animation(.spring(duration: 0.32, bounce: 0.16), value: isShowingVoiceComposer)
        .animation(.spring(duration: 0.32, bounce: 0.16), value: aiDrafts.phase)
        // The card's frame is captured (in MomentRow) and later used to
        // position the lifted copy in the overlay above. `.global` doesn't
        // work for that: it's the window's coordinate space, not this
        // ZStack's own — any safe-area/nav-bar offset between the two made
        // the lifted card land a few points higher or lower than the real
        // one. Naming this ZStack's space and measuring/positioning against
        // it on both ends keeps them pixel-identical regardless of insets.
        .coordinateSpace(name: ThreadCoordinateSpace.name)
        .task {
            // Notifications are persisted by the system; opening the screen
            // must not start a full cancel-and-reschedule pass.
            viewModel.load(now: currentDate, rescheduleNotifications: false)
            await runClock()
        }
        .onChange(of: settingsStore.untiedKnotsVisibility) { _, _ in
            viewModel.refreshPresentation()
        }
        .onChange(of: settingsStore.notificationsEnabled) { _, _ in
            viewModel.refreshPresentation(rescheduleNotifications: true)
        }
        .onChange(of: settingsStore.notificationSoundEnabled) { _, _ in
            viewModel.refreshPresentation(rescheduleNotifications: true)
        }
        .onChange(of: settingsStore.morningMinutes) { _, _ in
            viewModel.refreshQuickPresetNotifications()
        }
        .onChange(of: settingsStore.eveningMinutes) { _, _ in
            viewModel.refreshQuickPresetNotifications()
        }
        .onChange(of: openVoiceComposerFromControl, initial: true) { _, shouldOpen in
            guard shouldOpen else { return }
            openVoiceComposerFromControl = false
            // The Control Center control cannot be hidden per user, so it
            // stays installed and answers neutrally without `ai_drafts`.
            guard canUseVoiceDrafts else {
                viewModel.presentFeatureUnavailable()
                return
            }
            openVoiceComposer()
        }
        .onChange(of: canUseVoiceDrafts) { _, isAvailable in
            // Revoked on the server while the composer was open.
            if !isAvailable { dismissVoiceComposer() }
        }
        .sheet(isPresented: $viewModel.isShowingEditor) {
            ReminderEditorView(quickPresetSettings: settingsStore.snapshot) { draft in
                await viewModel.saveDraft(draft)
            }
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(
                settings: settingsStore,
                viewModel: viewModel,
                aiAccessStore: aiAccessStore,
                aiDrafts: aiDrafts,
                account: account,
                appConfig: appConfig,
                connections: connections,
                privacyPolicyURL: privacyPolicyURL
            )
        }
        .sheet(isPresented: $aiDrafts.isShowingConsent) {
            AIConsentView(
                language: settingsStore.appLanguage,
                privacyPolicyURL: privacyPolicyURL,
                allow: { await aiDrafts.consentGranted() },
                decline: { aiDrafts.consentDeclined() }
            )
        }
        .sheet(item: $aiDrafts.reviewJob) { job in
            AIDraftsReviewView(
                job: job,
                language: settingsStore.appLanguage,
                quickPresetSettings: settingsStore.snapshot,
                confirm: { aiDrafts.confirm(job, drafts: $0) },
                cancelJob: { aiDrafts.cancel(job) }
            )
        }
        .sheet(isPresented: $isShowingVoicePermissionPrimer) {
            VoicePermissionPromptView(language: settingsStore.appLanguage) {
                settingsStore.hasSeenVoicePermissionPrimer = true
                _ = await speech.requestPermissions()
                startVoiceCapture()
            }
        }
        .sheet(item: $viewModel.selectedItem) { item in
            ReminderDetailView(item: item, quickPresetSettings: settingsStore.snapshot, sharing: sharing(for: item)) {
                await viewModel.untie(item)
            } tie: {
                await viewModel.tie(item)
            } retie: { date in
                await viewModel.retie(item, to: date)
            } delete: {
                viewModel.delete(item)
            } edit: {
                viewModel.beginEditing(item)
            }
        }
        .sheet(item: $viewModel.editingKnot) { editing in
            ReminderEditorView(
                title: "Edit Knot",
                confirmTitle: "Save",
                draft: editing.draft,
                pause: { date in await viewModel.pause(editing.item, until: date) },
                quickPresetSettings: settingsStore.snapshot
            ) { draft in
                await viewModel.saveEdit(draft, item: editing.item)
            }
        }
        .sheet(item: $viewModel.suggestionToPresent) { suggestion in
            SuggestionPromptView(
                suggestion: suggestion,
                language: settingsStore.appLanguage,
                quickPresetSettings: settingsStore.snapshot,
                accept: { await viewModel.acceptSuggestion(suggestion, draft: $0) },
                dismissSuggestion: { viewModel.dismissSuggestion(suggestion) }
            )
        }
        .sheet(item: $viewModel.retieTarget) { item in
            RetieSheet(item: item, quickPresetSettings: settingsStore.snapshot) { date in
                await viewModel.retie(item, to: date)
            }
        }
        .sheet(item: $viewModel.pauseTarget) { item in
            PauseUntilSheet { date in
                await viewModel.pause(item, until: date)
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.permissionPromptDraft != nil },
            set: { isPresented in
                guard !isPresented, viewModel.permissionPromptDraft != nil else { return }
                // Swiping this away without tapping a button must not silently
                // drop the knot the user just filled in — fall back to tying
                // it without notifications, same as tapping "Not now".
                Task { await viewModel.tieWithoutNotifications() }
            }
        )) {
            NotificationPermissionPromptView {
                await viewModel.approveNotificationsAndTie()
            } notNow: {
                await viewModel.tieWithoutNotifications()
            }
        }
    }

    private var background: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()
        }
    }

    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, 26)
                        .padding(.top, 6)
                        .padding(.bottom, 12)
                        .opacity(visible ? 1 : 0)
                        .offset(y: visible ? 0 : 14)
                        .onPreferenceChange(PhraseWidthKey.self) { phraseWidth = $0 }
                        .id("now")

                    divider

                    if viewModel.hasAnyKnots {
                        TimelineThreadList(
                            rows: timelineRows,
                            visible: visible,
                            hapticsEnabled: settingsStore.hapticsEnabled,
                            select: { item in viewModel.selectedItem = item },
                            presentMenu: { item, anchor in viewModel.presentActionMenu(for: item, anchor: anchor) },
                            activeMenuItemID: viewModel.actionMenuItem?.id
                        )
                        .equatable()
                        .padding(.bottom, 96)
                    } else {
                        EmptyDayContent(
                            action: { viewModel.isShowingEditor = true },
                            voiceAction: voiceComposerAction,
                            isRecording: speech.isRecording,
                            language: settingsStore.appLanguage
                        )
                        .padding(.top, 42)
                        .opacity(visible ? 1 : 0)
                        .offset(y: visible ? 0 : 14)
                        .animation(.easeOut(duration: 0.8).delay(0.18), value: visible)
                    }
                }
            }
            .safeAreaPadding(.top, 4)
            .onChange(of: visible) { _, newValue in
                guard newValue && viewModel.hasAnyKnots else { return }
                withAnimation(.easeInOut(duration: 0.8)) {
                    proxy.scrollTo("now", anchor: .top)
                }
            }
        }
    }

    /// Flattens every section into one continuous row list (section title
    /// rows interleaved with item rows) so the thread can be drawn as a
    /// single uninterrupted line instead of one disconnected piece per
    /// section.
    private var timelineRows: [TimelineRow] {
        viewModel.sections.flatMap { section -> [TimelineRow] in
            var rows: [TimelineRow] = [.sectionTitle(id: "title-\(section.id)", text: section.title)]
            rows.append(contentsOf: section.items.map { TimelineRow.item($0) })
            return rows
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Text(greeting)
                    .font(.cormorant(26, weight: .regular))
                    .foregroundStyle(NodusPalette.primary.opacity(0.92))

                Text(formattedDate)
                    .font(.cormorant(18, weight: .light))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.82))
            }

            statusBlock
                .padding(.top, 20)
        }
    }

    private var statusBlock: some View {
        SmartPhraseText(
            phrase: viewModel.smartPhrase,
            animation: viewModel.smartPhraseAnimation,
            event: viewModel.smartPhraseEvent
        )
    }

    /// Sized to the smart phrase above it (with a small margin) instead of
    /// spanning the row, and rendered as a fade rather than a hard rule —
    /// an echo of the phrase rather than a structural separator.
    private var divider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [NodusPalette.primary.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(40, phraseWidth + 6), height: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.bottom, viewModel.hasTodayKnots ? 24 : 0)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: phraseWidth)
    }

    private var floatingButton: some View {
        Group {
            if viewModel.hasAnyKnots {
                HStack(spacing: 16) {
                    NewNodeButton(title: settingsStore.appLanguage.localizedString("Tie a Knot"), systemName: "plus", height: 52) {
                        viewModel.isShowingEditor = true
                    }

                    if canUseVoiceDrafts {
                        VoiceCaptureButton(isRecording: speech.isRecording, language: settingsStore.appLanguage, size: 52, action: openVoiceComposer)
                    }
                }
            }
        }
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 14)
        .animation(.easeOut(duration: 0.8).delay(0.18), value: visible)
    }

    /// Voice input exists only to feed AI drafts, so without `ai_drafts` in
    /// `user.features` it has no entry point at all.
    private var canUseVoiceDrafts: Bool {
        aiAccessStore.access.isAvailable(.drafts)
    }

    /// Members, rights and sync issues of the knot behind a row.
    private func sharing(for item: TimelineItem) -> NodeSharing? {
        guard let node = viewModel.node(for: item) else { return nil }
        let me = account.profile?.id
        let members = node.members
        let memberIds = Set(members.map(\.userId))
        return NodeSharing(
            members: members,
            ownerId: node.ownerId,
            currentUserId: me,
            isOwner: node.isOwned(by: me),
            shareCandidates: connections.active.filter { !memberIds.contains($0.userId) },
            syncIssue: node.syncIssueRaw,
            share: { connection in
                try? connections.share(node, with: connection)
                viewModel.refreshPresentation()
            },
            removeMember: { userId in
                try? connections.remove(member: userId, from: node, isSelf: false)
                viewModel.refreshPresentation()
            },
            leave: {
                guard let me else { return }
                try? connections.remove(member: me, from: node, isSelf: true)
                viewModel.load(rescheduleNotifications: true)
            },
            keepMine: { viewModel.keepMine(node) },
            keepTheirs: { viewModel.dismissSyncIssue(node) }
        )
    }

    /// After the composer closed: while the request is on its way (for
    /// example right after consent) and until the drafts are ready.
    private var isShowingWaitingCard: Bool {
        switch aiDrafts.phase {
        case .idle: false
        case .sending: !isShowingVoiceComposer
        case .waiting: true
        }
    }

    private var voiceComposerAction: (() -> Void)? {
        guard canUseVoiceDrafts else { return nil }
        return openVoiceComposer
    }

    private func dismissVoiceComposer() {
        speech.reset()
        isShowingVoiceComposer = false
    }

    private func openVoiceComposer() {
        guard settingsStore.hasSeenVoicePermissionPrimer else {
            isShowingVoicePermissionPrimer = true
            return
        }

        startVoiceCapture()
    }

    private func startVoiceCapture() {
        speech.reset()
        isShowingVoiceComposer = true
        Task { await speech.start(language: settingsStore.appLanguage) }
    }

    private func submitVoiceTranscript(_ transcript: String) {
        Task {
            if await aiDrafts.submit(transcript) {
                dismissVoiceComposer()
            }
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Spacer()
                IconCircleButton(systemName: "gearshape", accessibilityLabel: "Settings") {
                    viewModel.isShowingSettings = true
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            Spacer()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: currentDate)
        switch hour {
        case 5...11:
            return settingsStore.appLanguage.localizedString("Good morning")
        case 12...17:
            return settingsStore.appLanguage.localizedString("Good afternoon")
        case 18...22:
            return settingsStore.appLanguage.localizedString("Good evening")
        default:
            return settingsStore.appLanguage.localizedString("Good night")
        }
    }

    private var formattedDate: String {
        let date = currentDate
        let dayMonth = date.formatted(.dateTime.day().month(.wide).locale(locale))
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(locale)).lowercased(with: locale)
        return "\(dayMonth), \(weekday)"
    }

    private var locale: Locale {
        settingsStore.appLanguage.locale
    }

    private func runClock() async {
        while !Task.isCancelled {
            let nextDate = Date()
            await MainActor.run {
                let crossedIntoNewDay = !Calendar.current.isDate(currentDate, inSameDayAs: nextDate)
                currentDate = nextDate
                // The clock only owns the greeting and date label. Rebuilding
                // the complete SwiftData-backed thread every minute made a
                // routine clock tick compete with scrolling and sheets. The
                // timeline needs a fresh query only when its day boundary
                // changes.
                if crossedIntoNewDay {
                    viewModel.load(now: nextDate, rescheduleNotifications: false)
                }
            }

            let interval = secondsUntilNextMinute(from: nextDate)
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }

    private func secondsUntilNextMinute(from date: Date) -> Double {
        let second = Calendar.current.component(.second, from: date)
        let nanosecond = Calendar.current.component(.nanosecond, from: date)
        return max(1, 60 - Double(second) - Double(nanosecond) / 1_000_000_000)
    }
}

/// One row in the unified thread — either a lightweight section divider
/// (no knot, no marker) or a real knot/item.
enum TimelineRow: Identifiable, Equatable {
    case sectionTitle(id: String, text: String)
    case item(TimelineItem)

    var id: String {
        switch self {
        case let .sectionTitle(id, _):
            id
        case let .item(item):
            item.id
        }
    }

    var height: CGFloat {
        switch self {
        case .sectionTitle:
            42
        case let .item(item):
            item.title == nil ? 44 : 126
        }
    }
}

struct SectionTitleRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.cormorant(16, weight: .regular))
            .foregroundStyle(NodusPalette.secondary.opacity(0.62))
            .padding(.horizontal, 26)
            .frame(height: 42, alignment: .bottomLeading)
    }
}

struct TimelineThreadList: View, Equatable {
    let rows: [TimelineRow]
    let visible: Bool
    var hapticsEnabled: Bool = true
    let select: (TimelineItem) -> Void
    let presentMenu: (TimelineItem, CGRect) -> Void
    /// The item whose card is currently lifted into the custom action menu
    /// overlay — that row's own card must hide itself while the overlay
    /// shows its lifted copy, otherwise both are visible at once.
    let activeMenuItemID: String?

    // Presentation state such as an opened sheet invalidates the parent
    // view. The thread does not depend on it, so ignore action closures (they
    // target the same long-lived view model) and preserve the expensive list
    // whenever its visual inputs have not changed.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows &&
        lhs.visible == rhs.visible &&
        lhs.hapticsEnabled == rhs.hapticsEnabled &&
        lhs.activeMenuItemID == rhs.activeMenuItemID
    }

    var body: some View {
        let layout = ThreadLayout(rows: rows)

        ZStack(alignment: .topLeading) {
            TimelineThread(knotFractions: layout.knotFractions, lostKnotFractions: layout.lostKnotFractions)
                .stroke(
                    LinearGradient(
                        colors: [.clear, NodusPalette.accent.opacity(0.58), NodusPalette.accent.opacity(0.30), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .frame(width: 60, height: layout.threadHeight)
                .position(x: layout.axisX, y: layout.totalHeight / 2)
                .opacity(visible ? 1 : 0)

            // Only this one lightweight path receives animation ticks. Rows
            // remain stable while the user scrolls or opens a sheet.
            TimelineThreadShimmer(layout: layout, visible: visible)

            LazyVStack(spacing: layout.rowSpacing) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TimelineThreadRow(
                        row: row,
                        index: index,
                        visible: visible,
                        axisX: layout.axisX,
                        lineX: layout.markerLineX[index],
                        activeMenuItemID: activeMenuItemID,
                        hapticsEnabled: hapticsEnabled,
                        select: select,
                        presentMenu: presentMenu
                    )
                }
            }
        }
        // The top overhang lets the thread fade before the first knot.
        .padding(.top, 4 + layout.threadPadding)
    }
}

private struct TimelineThreadRow: View {
    let row: TimelineRow
    let index: Int
    let visible: Bool
    let axisX: CGFloat
    let lineX: CGFloat
    let activeMenuItemID: String?
    let hapticsEnabled: Bool
    let select: (TimelineItem) -> Void
    let presentMenu: (TimelineItem, CGRect) -> Void

    var body: some View {
        Group {
            switch row {
            case let .sectionTitle(_, text):
                SectionTitleRow(text: text)
            case let .item(item):
                MomentRow(
                    item: item,
                    visible: visible,
                    index: index,
                    axisX: axisX,
                    lineX: lineX,
                    isCardHidden: item.id == activeMenuItemID,
                    hapticsEnabled: hapticsEnabled,
                    action: { select(item) },
                    onLongPress: presentMenu
                )
            }
        }
    }
}

private struct ThreadLayout {
    let axisX: CGFloat
    let rowSpacing: CGFloat
    let threadPadding: CGFloat
    let totalHeight: CGFloat
    let threadHeight: CGFloat
    let markerLineX: [CGFloat]
    let knotFractions: [CGFloat]
    let lostKnotFractions: [CGFloat]

    init(rows: [TimelineRow]) {
        // Keep the values local while constructing the derived arrays. Using
        // stored properties here makes the mapping closures capture `self`
        // before all of its properties have been initialized.
        let axisX: CGFloat = 118
        let rowSpacing: CGFloat = 70
        let threadPadding: CGFloat = 70
        let rowHeights = rows.map(\.height)
        let totalHeight = rowHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
        let threadHeight = totalHeight + threadPadding * 2
        let rowTops = rowHeights.indices.reduce(into: [CGFloat]()) { tops, index in
            let previous = tops.last ?? 0
            tops.append(index == 0 ? 0 : previous + rowHeights[index - 1] + rowSpacing)
        }
        let markerLineX = rowTops.map { top in
            axisX + TimelineThread.xOffset(at: (top + 24 + threadPadding) / max(threadHeight, 1))
        }
        let knotFractions = rows.indices.compactMap { index -> CGFloat? in
            let row = rows[index]
            guard case let .item(item) = row, item.title != nil, !item.isLost, !item.isCompleted else { return nil }
            return (rowTops[index] + 24.9 + threadPadding) / max(threadHeight, 1)
        }
        let lostKnotFractions = rows.indices.compactMap { index -> CGFloat? in
            let row = rows[index]
            guard case let .item(item) = row, item.isLost else { return nil }
            return (rowTops[index] + 24.9 + threadPadding) / max(threadHeight, 1)
        }

        self.axisX = axisX
        self.rowSpacing = rowSpacing
        self.threadPadding = threadPadding
        self.totalHeight = totalHeight
        self.threadHeight = threadHeight
        self.markerLineX = markerLineX
        self.knotFractions = knotFractions
        self.lostKnotFractions = lostKnotFractions
    }
}

private struct TimelineThreadShimmer: View {
    let layout: ThreadLayout
    let visible: Bool

    var body: some View {
        // A one-second tick plus interpolation keeps the 26-second glow
        // smooth without scheduling a 30 FPS SwiftUI body update.
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 26) / 26
            let halfWidth = 0.16
            let feather = 0.07
            let center = halfWidth + cycle * (1 - 2 * halfWidth)
            let clamp: (Double) -> Double = { min(max($0, 0), 1) }
            let fade = cycle < 0.15 ? cycle / 0.15 : (cycle > 0.85 ? (1 - cycle) / 0.15 : 1)
            let stops: [Gradient.Stop] = [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: clamp(center - halfWidth)),
                .init(color: Color(hex: 0xF1C98E).opacity(0.42), location: clamp(center - halfWidth + feather)),
                .init(color: Color(hex: 0xF1C98E).opacity(0.42), location: clamp(center + halfWidth - feather)),
                .init(color: .clear, location: clamp(center + halfWidth)),
                .init(color: .clear, location: 1)
            ]

            TimelineThread(knotFractions: layout.knotFractions, lostKnotFractions: layout.lostKnotFractions)
                .stroke(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 60, height: layout.threadHeight)
                .position(x: layout.axisX, y: layout.totalHeight / 2)
                .blur(radius: 0.6)
                .opacity(visible ? fade : 0)
                .animation(.linear(duration: 1), value: cycle)
        }
        .allowsHitTesting(false)
    }
}
