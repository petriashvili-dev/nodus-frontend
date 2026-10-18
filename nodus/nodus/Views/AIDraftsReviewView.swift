import SwiftUI

/// The drafts of one voice note. Each is edited with the regular knot
/// editor; one action ties all included drafts. Until then nothing appears
/// on the thread. Push and foreground lead to this same screen.
struct AIDraftsReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let job: AIDraftJob
    let language: AppLanguage
    let quickPresetSettings: SettingsSnapshot
    let confirm: ([ReminderDraft]) -> Bool
    let cancelJob: () -> Void

    @State private var drafts: [EditableDraft]
    @State private var editing: EditableDraft?

    init(
        job: AIDraftJob,
        language: AppLanguage,
        quickPresetSettings: SettingsSnapshot,
        now: Date = Date(),
        confirm: @escaping ([ReminderDraft]) -> Bool,
        cancelJob: @escaping () -> Void
    ) {
        self.job = job
        self.language = language
        self.quickPresetSettings = quickPresetSettings
        self.confirm = confirm
        self.cancelJob = cancelJob
        _drafts = State(initialValue: AIDraftsService.editableDrafts(of: job, now: now))
    }

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if !job.transcript.isEmpty {
                            Text("«\(job.transcript)»")
                                .font(.cormorant(17, weight: .light, italic: true))
                                .foregroundStyle(NodusPalette.secondary.opacity(0.78))
                                .lineLimit(4)
                                .padding(.bottom, 4)
                        }

                        ForEach($drafts) { $draft in
                            DraftCard(draft: $draft, language: language) {
                                editing = draft
                            }
                        }

                        NodusSheetFooterButton(
                            title: LocalizedStringKey(confirmTitle),
                            isDisabled: !canConfirm
                        ) {
                            let included = drafts.filter(\.isIncluded).map(\.draft)
                            if confirm(included) { dismiss() }
                        }

                        NodusActionButton(title: LocalizedStringKey(language.localizedString("Discard drafts")), systemName: "xmark", tone: .destructive) {
                            cancelJob()
                            dismiss()
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
        .sheet(item: $editing) { draft in
            ReminderEditorView(
                title: LocalizedStringKey(language.localizedString("Draft")),
                confirmTitle: LocalizedStringKey(language.localizedString("Save")),
                draft: draft.draft,
                quickPresetSettings: quickPresetSettings
            ) { edited in
                guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
                drafts[index].draft = edited
                drafts[index].needsDate = false
                editing = nil
            }
        }
    }

    private var includedCount: Int { drafts.filter(\.isIncluded).count }

    private var canConfirm: Bool {
        let now = Date()
        let included = drafts.filter(\.isIncluded)
        return !included.isEmpty && included.allSatisfy { $0.isValid(now: now) }
    }

    private var confirmTitle: String {
        includedCount == 1 ? language.localizedString("Tie the knot") : language.localizedString("Tie all knots")
    }

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Close") { dismiss() }
            Spacer()
            Text(language.localizedString("Drafts"))
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
            Spacer()
            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }
}

/// One draft: what it will become, what the model was unsure about, and
/// whether it is included.
private struct DraftCard: View {
    @Binding var draft: EditableDraft
    let language: AppLanguage
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { draft.isIncluded.toggle() }
            } label: {
                Image(systemName: draft.isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(draft.isIncluded ? NodusPalette.accent.opacity(0.9) : NodusPalette.secondary.opacity(0.5))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.localizedString(draft.isIncluded ? "Included" : "Excluded"))

            Button(action: edit) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.draft.title.isEmpty ? language.localizedString("Untitled") : draft.draft.title)
                        .font(.cormorant(19, weight: .regular))
                        .foregroundStyle(NodusPalette.primary.opacity(draft.isIncluded ? 0.94 : 0.5))
                        .multilineTextAlignment(.leading)

                    Text(whenText)
                        .font(.system(size: 13))
                        .foregroundStyle(draft.needsDate ? Color(hex: 0xD8A48F).opacity(0.92) : NodusPalette.secondary.opacity(0.78))

                    ForEach(Array(issueMessages.enumerated()), id: \.offset) { _, message in
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0xD8A48F).opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(language.localizedString("Edit"))

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NodusPalette.secondary.opacity(0.48))
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .padding(15)
        .background(Color(hex: 0x111827).opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(draft.needsDate && draft.isIncluded ? Color(hex: 0xD8A48F).opacity(0.3) : NodusPalette.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var whenText: String {
        if draft.needsDate { return language.localizedString("Choose a date and time") }
        let date = draft.draft.scheduledAt.formatted(.dateTime.day().month(.wide).hour().minute().locale(language.locale))
        guard draft.draft.repeatSchedule.isRepeating else { return date }
        return "\(draft.draft.repeatSchedule.displayLabel(language: language)) · \(date)"
    }

    /// Issues from the model; date problems are already shown above.
    private var issueMessages: [String] {
        draft.issues.compactMap { issue in
            switch issue.code {
            case "missing_date", "time_without_date", "invalid_date", "invalid_time":
                return nil
            case "past_date":
                return language.localizedString("The date has already passed")
            case "missing_recurrence", "invalid_recurrence":
                return language.localizedString("Check the repeat: it became a one-time knot")
            default:
                return issue.message
            }
        }
    }
}
