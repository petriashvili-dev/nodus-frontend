import SwiftUI

struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isNoteFocused: Bool
    @State private var draft: ReminderDraft
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let save: (ReminderDraft) async -> Void
    let pause: ((Date) async -> Void)?
    let quickPresetSettings: SettingsSnapshot
    @State private var isShowingPausePicker = false
    @State private var isShowingOriginDatePicker = false

    init(
        title: LocalizedStringKey = "Tie a Knot",
        confirmTitle: LocalizedStringKey = "Tie",
        draft: ReminderDraft = ReminderDraft(),
        pause: ((Date) async -> Void)? = nil,
        quickPresetSettings: SettingsSnapshot = .init(untiedKnotsVisibility: .untilEndOfDay, language: .ru, notificationsEnabled: true, notificationSoundEnabled: true, hapticsEnabled: true, inAppSoundsEnabled: true),
        save: @escaping (ReminderDraft) async -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self._draft = State(initialValue: draft)
        self.pause = pause
        self.quickPresetSettings = quickPresetSettings
        self.save = save
    }

    var body: some View {
        ZStack {
            NodusPalette.background
                .ignoresSafeArea()
                // Only taps on the empty background dismiss the keyboard.
                // A gesture attached to the whole editor also receives a
                // double tap inside TextField and clears its selection.
                .onTapGesture { dismissKeyboard() }
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        titleField
                        noteField
                        dateTimeRow
                        quickReminderPicker
                        repeatPicker
                        if draft.repeatSchedule.isYearly {
                            originDateControl
                        }
                        if draft.repeatSchedule.isRepeating, pause != nil {
                            pauseControl
                        }
                        notificationPicker
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                    NodusWaveDivider()
                        .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
        .animation(.easeInOut(duration: 0.24), value: draft.repeatSchedule)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
            }
        }
        .onAppear {
            isTitleFocused = true
        }
        .sheet(isPresented: $isShowingPausePicker) {
            PauseUntilSheet { date in
                await pause?(date)
                dismiss()
            }
        }
        .sheet(isPresented: $isShowingOriginDatePicker) {
            NodusDatePickerSheet(
                title: "Origin date",
                date: originDateBinding,
                mode: .dateOnly
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Cancel") {
                dismiss()
            }

            Spacer()

            Text(title)
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))

            Spacer()

            NodusSheetConfirmButton(action: confirm, isDisabled: !isValid, accessibilityLabel: confirmTitle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Fields

    private var titleField: some View {
        NodusTextField(
            title: "What to tie?",
            placeholder: "The knot you do not want to lose",
            text: $draft.title,
            submitLabel: .next,
            onSubmit: { isNoteFocused = true },
            focus: $isTitleFocused
        )
    }

    private var noteField: some View {
        NodusTextField(
            title: "Knot meaning",
            placeholder: "Why this knot matters today",
            text: $draft.note,
            axis: .vertical,
            lineLimit: 3...6,
            submitLabel: .done,
            onSubmit: { dismissKeyboard() },
            dismissesOnReturn: true,
            focus: $isNoteFocused
        )
    }

    private var dateTimeRow: some View {
        NodusDateTimeRow(
            title: dateFieldTitle,
            date: $draft.scheduledAt,
            mode: dateFieldMode,
            minimumDate: .earliestReminderTime()
        )
    }

    private var quickReminderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick actions")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
                ForEach(quickReminderPresets) { preset in
                    NodusToggleChip(title: preset.label(language: AppLanguage(locale: locale)), isActive: false) {
                        draft.scheduledAt = preset.date
                    }
                }
            }
        }
    }

    private var repeatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Repeat")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            NodusRepeatPicker(schedule: $draft.repeatSchedule)
        }
    }

    private var notificationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notification")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            NodusLeadTimePicker(leadTimes: $draft.leadTimes)
        }
    }

    private var originDateControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Origin date")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            if draft.originDate != nil {
                NodusDateTimeRow(
                    title: "Origin date",
                    date: originDateBinding,
                    mode: .dateOnly,
                    showsLabel: false
                )

                NodusActionButton(title: "Remove origin date", systemName: "xmark.circle", tone: .secondary) {
                    draft.originDate = nil
                }
            } else {
                NodusActionButton(title: "Add origin date", systemName: "calendar.badge.plus", tone: .secondary) {
                    draft.originDate = Calendar.current.startOfDay(for: Date())
                    isShowingOriginDatePicker = true
                }
            }
        }
    }

    private var pauseControl: some View {
        NodusActionButton(title: "Поставить на паузу", systemName: "pause.circle", tone: .secondary) {
            dismissKeyboard()
            isShowingPausePicker = true
        }
    }

    // MARK: - Validation & formatting

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.scheduledAt >= .earliestReminderTime()
    }

    private var dateFieldTitle: LocalizedStringKey {
        "Date and Time"
    }

    private var dateFieldMode: NodusDateField.Mode {
        .dateAndTime
    }

    private var quickReminderPresets: [ReminderQuickPreset] {
        ReminderQuickPreset.all(settings: quickPresetSettings)
    }

    private var originDateBinding: Binding<Date> {
        Binding(
            get: { draft.originDate ?? Calendar.current.startOfDay(for: Date()) },
            set: { draft.originDate = $0 }
        )
    }

    private func dismissKeyboard() {
        isTitleFocused = false
        isNoteFocused = false
    }

    private func confirm() {
        Task {
            await save(draft)
            dismiss()
        }
    }
}
