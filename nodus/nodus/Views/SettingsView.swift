import SwiftUI

struct SettingsView: View {
    private enum Destination: String, Identifiable, Equatable {
        case account, notifications, thread, app, archive, drafts

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore
    @ObservedObject var viewModel: HomeTimelineViewModel
    @ObservedObject var aiAccessStore: AIAccessStore
    @ObservedObject var aiDrafts: AIDraftsCoordinator
    @ObservedObject var account: AccountService
    @ObservedObject var appConfig: AppConfigStore
    @State private var emailSheet: EmailCodeSheet.Mode?
    @State private var displayName = ""
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false
    @State private var reviewingJob: AIDraftJob?
    @State private var manualDraftJob: AIDraftJob?
    @State private var destination: Destination?
    @State private var archiveForExport: NodusArchive?
    @State private var isExportingArchive = false
    @State private var isImportingArchive = false
    @State private var editingPausedKnot: PausedKnot?

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()

                if let destination {
                    detail(destination)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    menu
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }

            if let toast = viewModel.toast {
                ToastView(toast: toast, undoDuration: HomeTimelineViewModel.toastDuration)
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
        .animation(.easeInOut(duration: 0.22), value: destination)
        .sheet(item: $reviewingJob) { job in
            AIDraftsReviewView(
                job: job,
                language: settings.appLanguage,
                quickPresetSettings: settings.snapshot,
                confirm: { aiDrafts.confirm(job, drafts: $0) },
                cancelJob: { aiDrafts.cancel(job) }
            )
        }
        .sheet(item: $manualDraftJob) { job in
            // "Create manually" after the model could not help.
            ReminderEditorView(
                draft: ReminderDraft(title: String(job.transcript.prefix(200))),
                quickPresetSettings: settings.snapshot
            ) { draft in
                await viewModel.saveDraft(draft)
                aiDrafts.remove(job)
                manualDraftJob = nil
            }
        }
        .sheet(item: Binding(
            get: { emailSheet.map(EmailSheetItem.init) },
            set: { emailSheet = $0?.mode }
        )) { item in
            EmailCodeSheet(mode: item.mode, language: settings.appLanguage, account: account) {
                viewModel.presentToast(settings.appLanguage.localizedString(item.mode == .link ? "Account saved" : "Account restored"))
            }
        }
        .alert(settings.appLanguage.localizedString("Sign out?"), isPresented: $isConfirmingSignOut) {
            Button(settings.appLanguage.localizedString("Sign out"), role: .destructive) {
                Task { await account.logout() }
            }
            Button(settings.appLanguage.localizedString("Cancel"), role: .cancel) {}
        } message: {
            Text(settings.appLanguage.localizedString("Knots will disappear from this device. Sign in with your email to see them again."))
        }
        .alert(settings.appLanguage.localizedString("Delete account?"), isPresented: $isConfirmingDeletion) {
            Button(settings.appLanguage.localizedString("Delete account"), role: .destructive) {
                Task {
                    do {
                        try await account.deleteAccount()
                        viewModel.presentToast(settings.appLanguage.localizedString("Account deleted"))
                    } catch {
                        viewModel.presentToast(settings.appLanguage.localizedString("Deleting the account needs a connection"))
                    }
                }
            }
            Button(settings.appLanguage.localizedString("Cancel"), role: .cancel) {}
        } message: {
            Text(settings.appLanguage.localizedString("All your knots, drafts and connections will be deleted. Shared knots disappear for other participants too. This cannot be undone."))
        }
        .sheet(item: $editingPausedKnot) { knot in
            PauseUntilSheet(initialDate: knot.resumesAt) { date in
                await viewModel.pause(nodeId: knot.nodeId, until: date)
            }
        }
        .fileExporter(
            isPresented: $isExportingArchive,
            document: archiveForExport,
            contentType: .nodusArchive,
            defaultFilename: "Nodus-\(Self.archiveDateFormatter.string(from: Date()))"
        ) { result in
            archiveForExport = nil
            switch result {
            case .success:
                viewModel.presentToast("Активные узлы экспортированы.")
            case let .failure(error):
                viewModel.presentToast("Не удалось экспортировать: \(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.nodusArchive]) { result in
            switch result {
            case let .success(url):
                importArchive(from: url)
            case let .failure(error):
                viewModel.presentToast("Не удалось открыть файл: \(error.localizedDescription)")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
        .animation(.easeOut(duration: 0.28), value: viewModel.toast?.id)
    }

    private var header: some View {
        HStack {
            IconCircleButton(systemName: destination == nil ? "xmark" : "chevron.left", accessibilityLabel: "Close") {
                if destination == nil {
                    dismiss()
                } else {
                    destination = nil
                }
            }

            Spacer()

            Text(destinationTitle ?? settings.appLanguage.localizedString("Settings"))
                .font(.cormorant(22, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))

            Spacer()

            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var destinationTitle: String? {
        switch destination {
        case .account: settings.appLanguage.localizedString("Account")
        case .notifications: settings.appLanguage.localizedString("Notifications")
        case .thread: settings.appLanguage.localizedString("Thread")
        case .app: "Приложение"
        case .archive: "Импорт и экспорт"
        case .drafts: settings.appLanguage.localizedString("Drafts")
        case nil: nil
        }
    }

    private var menu: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsMenuRow(title: settings.appLanguage.localizedString("Account")) {
                    displayName = account.profile?.displayName ?? ""
                    destination = .account
                }

                SettingsMenuRow(title: settings.appLanguage.localizedString("Notifications")) {
                    destination = .notifications
                }

                SettingsMenuRow(title: settings.appLanguage.localizedString("Thread")) {
                    destination = .thread
                }

                SettingsMenuRow(title: "Приложение") {
                    destination = .app
                }

                SettingsMenuRow(title: "Импорт и экспорт") {
                    destination = .archive
                }

                // Drafts stay reachable for unfinished jobs even after the
                // feature is withdrawn.
                if aiAccessStore.access.isAvailable(.drafts) || !aiDrafts.jobs.isEmpty {
                    SettingsMenuRow(title: settings.appLanguage.localizedString("Drafts")) {
                        aiDrafts.refreshJobs()
                        destination = .drafts
                    }
                }

                NodusWaveDivider().padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private func detail(_ destination: Destination) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                switch destination {
                case .account:
                    accountSection
                case .notifications:
                    notificationsSection
                case .thread:
                    threadSection
                case .app:
                    appSection
                case .archive:
                    archiveSection
                case .drafts:
                    draftsSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            NodusToggleRow(title: "Enable Notifications", subtitle: "Allow reminders about tied knots", hapticsEnabled: settings.hapticsEnabled, isOn: $settings.notificationsEnabled)
            NodusToggleRow(title: "Notification Sound", subtitle: "Play a sound when a notification arrives", hapticsEnabled: settings.hapticsEnabled, isOn: $settings.notificationSoundEnabled)
            SettingsControlTitle("Быстрые подсказки").padding(.top, 4)
            DatePicker("Утро", selection: timeBinding(for: $settings.morningMinutes), displayedComponents: .hourAndMinute)
                .tint(NodusPalette.accent)
            DatePicker("Вечер", selection: timeBinding(for: $settings.eveningMinutes), displayedComponents: .hourAndMinute)
                .tint(NodusPalette.accent)
        }
    }

    private func timeBinding(for minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: .now)) ?? .now },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsControlTitle("Развязанные узлы")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                NodusToggleChip(title: settings.appLanguage.localizedString("Hide"), isActive: settings.untiedKnotsVisibility == .hidden) { settings.untiedKnotsVisibility = .hidden }
                NodusToggleChip(title: settings.appLanguage.localizedString("Until End of Day"), isActive: settings.untiedKnotsVisibility == .untilEndOfDay) { settings.untiedKnotsVisibility = .untilEndOfDay }
                NodusToggleChip(title: settings.appLanguage.localizedString("Always"), isActive: settings.untiedKnotsVisibility == .always) { settings.untiedKnotsVisibility = .always }
            }

            SettingsControlTitle("На паузе")
                .padding(.top, 12)

            if viewModel.pausedKnots.isEmpty {
                Text("Нет узлов на паузе.")
                    .font(.system(size: 14))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            } else {
                VStack(spacing: 8) {
                    ForEach(viewModel.pausedKnots) { knot in
                        PausedKnotRow(
                            knot: knot,
                            locale: settings.appLanguage.locale,
                            change: { editingPausedKnot = knot },
                            resume: { Task { await viewModel.resumePausedKnot(nodeId: knot.nodeId) } }
                        )
                    }
                }
            }
        }
    }

    private var appSection: some View {
        VStack(spacing: 20) {
            NodusToggleRow(title: "Анимированная заставка", subtitle: "Показывать анимацию при запуске приложения", hapticsEnabled: settings.hapticsEnabled, isOn: $settings.animatedSplashEnabled)
            NodusToggleRow(title: "Тактильный отклик", subtitle: "Использовать лёгкую вибрацию при действиях в приложении", hapticsEnabled: settings.hapticsEnabled, isOn: $settings.hapticsEnabled)
            NodusToggleRow(title: "Звуки в приложении", subtitle: "Воспроизводить тихие звуки при действиях в приложении", hapticsEnabled: settings.hapticsEnabled, isOn: $settings.inAppSoundsEnabled)
            if aiAccessStore.access.hasAnyFeature {
                NodusToggleRow(
                    title: LocalizedStringKey(settings.appLanguage.localizedString("AI assistant")),
                    subtitle: LocalizedStringKey(settings.appLanguage.localizedString("Send your notes and knot titles to an AI model through Nodus to get drafts and suggestions")),
                    hapticsEnabled: settings.hapticsEnabled,
                    isOn: Binding(
                        get: { aiAccessStore.access.hasConsent },
                        set: { aiDrafts.setConsent($0) }
                    )
                )
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            NodusSheetSection {
                NodusInfoRow(
                    title: LocalizedStringKey(settings.appLanguage.localizedString("Account")),
                    value: account.profile?.email ?? settings.appLanguage.localizedString("Anonymous")
                )
                NodusTextField(
                    title: LocalizedStringKey(settings.appLanguage.localizedString("Name")),
                    placeholder: LocalizedStringKey(settings.appLanguage.localizedString("How your connections see you")),
                    text: $displayName,
                    submitLabel: .done,
                    onSubmit: saveDisplayName
                )
                .onChange(of: displayName) { _, name in
                    let limit = appConfig.config.limits.displayNameMaxChars
                    if name.count > limit { displayName = String(name.prefix(limit)) }
                }
            }

            if account.isAnonymous {
                Text(settings.appLanguage.localizedString("An anonymous account lives only on this device. Save it with an email to keep your knots after reinstalling."))
                    .font(.system(size: 13))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.78))
                NodusActionButton(title: LocalizedStringKey(settings.appLanguage.localizedString("Save account")), systemName: "envelope", tone: .primary) {
                    emailSheet = .link
                }
            }

            NodusActionButton(title: LocalizedStringKey(settings.appLanguage.localizedString("Restore account")), systemName: "arrow.uturn.backward") {
                emailSheet = .recover
            }

            NodusSheetSection {
                NodusLinkRow(title: LocalizedStringKey(settings.appLanguage.localizedString("Privacy policy")), destination: appConfig.config.privacyPolicyURL)
                NodusLinkRow(title: LocalizedStringKey(settings.appLanguage.localizedString("Terms of use")), destination: appConfig.config.termsURL)
                NodusLinkRow(title: LocalizedStringKey(settings.appLanguage.localizedString("Contact support")), destination: appConfig.config.supportURL)
            }

            if !account.isAnonymous {
                NodusActionButton(title: LocalizedStringKey(settings.appLanguage.localizedString("Sign out")), systemName: "rectangle.portrait.and.arrow.right") {
                    isConfirmingSignOut = true
                }
            }

            NodusActionButton(title: LocalizedStringKey(settings.appLanguage.localizedString("Delete account")), systemName: "trash", tone: .destructive) {
                isConfirmingDeletion = true
            }
        }
        .onDisappear(perform: saveDisplayName)
    }

    private func saveDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (account.profile?.displayName ?? "") else { return }
        try? account.updateDisplayName(trimmed)
    }

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if aiDrafts.jobs.isEmpty {
                Text(settings.appLanguage.localizedString("No drafts"))
                    .font(.system(size: 14))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            } else {
                ForEach(aiDrafts.jobs) { job in
                    DraftJobRow(
                        job: job,
                        status: aiDrafts.statusMessage(for: job),
                        language: settings.appLanguage,
                        review: { reviewingJob = job },
                        resend: { Task { await aiDrafts.resubmit(job) } },
                        createManually: { manualDraftJob = job },
                        remove: { job.isOnServer && job.status == .ready ? aiDrafts.cancel(job) : aiDrafts.remove(job) }
                    )
                }
            }
        }
    }

    private var archiveSection: some View {
        archiveActions
    }

    private var archiveActions: some View {
        VStack(spacing: 0) {
            ArchiveTransferRow(
                title: "Экспортировать",
                detail: "Только активные узлы",
                action: exportArchive
            )

            ArchiveTransferRow(
                title: "Импортировать",
                detail: "Дополняет узлами нить"
            ) {
                isImportingArchive = true
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .leading) {
            // The first two rows of a full 304pt thread: preserve its
            // coordinate system, then crop it. Rescaling the thread changes
            // its normalized curve and makes the knots look unlike the
            // thread elsewhere in the app.
            TimelineThread(knotFractions: [0.079, 0.329])
                .stroke(
                    LinearGradient(
                        colors: [NodusPalette.accent.opacity(0.3), NodusPalette.accent.opacity(0.56), NodusPalette.accent.opacity(0.28), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                )
                .frame(width: 46, height: 304)
                .padding(.top, 14)
                .frame(width: 46, height: 152, alignment: .top)
                .clipped()
                .accessibilityHidden(true)

            ArchiveThreadArrows()
                .stroke(
                    LinearGradient(
                        colors: [NodusPalette.accent.opacity(0.3), NodusPalette.accent.opacity(0.56), NodusPalette.accent.opacity(0.28), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 56, height: 304)
                .padding(.top, 14)
                .frame(width: 56, height: 152, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
        }
    }

    private func exportArchive() {
        do {
            archiveForExport = try viewModel.activeNodesArchive()
            isExportingArchive = true
        } catch {
            viewModel.presentToast("Не удалось подготовить экспорт: \(error.localizedDescription)")
        }
    }

    private func importArchive(from url: URL) {
        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let document = try NodusArchive(fileData: Data(contentsOf: url))
            let importedCount = try viewModel.importArchive(document)
            viewModel.presentToast("Импортировано узлов: \(importedCount).")
        } catch {
            viewModel.presentToast("Не удалось импортировать файл: \(error.localizedDescription)")
        }
    }

    private static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct EmailSheetItem: Identifiable {
    let mode: EmailCodeSheet.Mode
    var id: String { mode == .link ? "link" : "recover" }
}

/// One voice note in "Drafts" with what can be done about it now.
private struct DraftJobRow: View {
    let job: AIDraftJob
    let status: String
    let language: AppLanguage
    let review: () -> Void
    let resend: () -> Void
    let createManually: () -> Void
    let remove: () -> Void

    var body: some View {
        NodusSheetSection {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.transcript.isEmpty ? language.localizedString("Voice note") : job.transcript)
                    .font(.cormorant(18, weight: .regular))
                    .foregroundStyle(NodusPalette.primary.opacity(0.92))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            }

            switch job.status {
            case .ready:
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Review")), systemName: "checklist", tone: .primary, action: review)
            case .unsent:
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Send")), systemName: "paperplane", tone: .primary, action: resend)
            case .failed where job.errorCode != "nothing_recognized" && !job.transcript.isEmpty:
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Try again")), systemName: "arrow.clockwise", tone: .primary, action: resend)
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Create manually")), systemName: "square.and.pencil", action: createManually)
            default:
                EmptyView()
            }

            if job.status != .queued && job.status != .processing {
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Delete")), systemName: "trash", tone: .destructive, action: remove)
            }
        }
    }
}

private struct SettingsMenuRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.cormorant(23, weight: .regular))
                    .foregroundStyle(NodusPalette.primary.opacity(0.92))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.48))
            }
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NodusPalette.softLine.opacity(0.72)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Labels a group of controls inside a settings section without competing
/// with the sheet's own title in the header.
private struct SettingsControlTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.cormorant(20, weight: .light))
            .foregroundStyle(NodusPalette.secondary.opacity(0.82))
    }
}

private struct PausedKnotRow: View {
    let knot: PausedKnot
    let locale: Locale
    let change: () -> Void
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(knot.title)
                    .font(.cormorant(19, weight: .medium))
                    .foregroundStyle(NodusPalette.primary.opacity(0.94))
                    .lineLimit(1)

                Text("До \(knot.resumesAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(locale)))")
                    .font(.system(size: 12))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Button("Изменить") {
                    change()
                }
                Button("Снять") {
                    resume()
                }
            }
            .font(.cormorant(16, weight: .medium))
            .foregroundStyle(NodusPalette.accent)
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(NodusPalette.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ArchiveTransferRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Color.clear.frame(width: 64, height: 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.cormorant(23, weight: .medium))
                        .foregroundStyle(NodusPalette.primary.opacity(0.94))

                    Text(detail)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.76))
                        .lineSpacing(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.48))
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 76, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(NodeButtonStyle(intensity: .subtle))
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// The arrows are branches of the same thread: they share its cubic position,
/// gradient, and stroke rather than being separate SF Symbol decorations.
private struct ArchiveThreadArrows: Shape {
    func path(in rect: CGRect) -> Path {
        // Match the knot centers of the cropped thread in `archiveActions` exactly.
        let exportY: CGFloat = 24
        let importY: CGFloat = 100
        let threadGap: CGFloat = 17
        let arrowLength: CGFloat = 14
        let arrowSize: CGFloat = 4
        var path = Path()

        func threadX(_ y: CGFloat) -> CGFloat {
            23 + TimelineThread.xOffset(at: y / 304)
        }

        // Export grows from the thread toward the action.
        let exportStartX = threadX(exportY) + threadGap
        let exportEndX = exportStartX + arrowLength
        path.move(to: CGPoint(x: exportStartX, y: exportY))
        path.addCurve(
            to: CGPoint(x: exportEndX, y: exportY),
            control1: CGPoint(x: exportStartX + 6, y: exportY - 2),
            control2: CGPoint(x: exportEndX - 5, y: exportY - 1)
        )
        path.move(to: CGPoint(x: exportEndX - arrowSize, y: exportY - arrowSize))
        path.addLine(to: CGPoint(x: exportEndX, y: exportY))
        path.addLine(to: CGPoint(x: exportEndX - arrowSize, y: exportY + arrowSize))

        // Import returns toward the thread.
        let importEndX = threadX(importY) + threadGap
        let importStartX = importEndX + arrowLength
        path.move(to: CGPoint(x: importStartX, y: importY))
        path.addCurve(
            to: CGPoint(x: importEndX, y: importY),
            control1: CGPoint(x: importStartX - 5, y: importY + 1),
            control2: CGPoint(x: importEndX + 6, y: importY + 2)
        )
        path.move(to: CGPoint(x: importEndX + arrowSize, y: importY - arrowSize))
        path.addLine(to: CGPoint(x: importEndX, y: importY))
        path.addLine(to: CGPoint(x: importEndX + arrowSize, y: importY + arrowSize))

        return path
    }
}
