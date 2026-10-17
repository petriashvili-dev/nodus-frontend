import Foundation
import SwiftUI

/// Converts URLs and Russian mobile phone numbers in a note into links.
/// `tel:` is deliberately limited to mobile-looking Russian numbers so dates,
/// reminder times, and other ordinary numbers do not become tappable calls.
private enum NoteLinkifier {
    static func attributedText(for text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let fullRange = NSRange(text.startIndex..., in: text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

        detector?.matches(in: text, options: [], range: fullRange).forEach { match in
            guard let stringRange = Range(match.range, in: text),
                  let start = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let end = AttributedString.Index(stringRange.upperBound, within: attributed)
            else { return }
            let attributedRange = start..<end

            switch match.resultType {
            case .link:
                if let url = match.url {
                    attributed[attributedRange].link = url
                }
            case .phoneNumber:
                guard let number = match.phoneNumber, isRussianMobile(number) else { return }
                let dialableNumber = number.filter { $0.isNumber || $0 == "+" }
                if let url = URL(string: "tel://\(dialableNumber)") {
                    attributed[attributedRange].link = url
                }
            default:
                break
            }
        }

        return attributed
    }

    private static func isRussianMobile(_ number: String) -> Bool {
        let digits = number.filter(\.isNumber)
        switch digits.count {
        case 11:
            return (digits.first == "7" || digits.first == "8") && digits.dropFirst().first == "9"
        case 10:
            return digits.first == "9"
        default:
            return false
        }
    }
}

extension Date {
    /// Rounds to the nearest 5-minute mark, so a prefilled picker never
    /// shows an off-grid time like 17:51.
    nonisolated func roundedToNearest5Minutes() -> Date {
        let interval: TimeInterval = 5 * 60
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / interval).rounded() * interval)
    }

    /// The earliest time a new or edited knot may use. Keeping this in one
    /// place makes the editor's initial value and its calendar boundary
    /// identical.
    nonisolated static func earliestReminderTime(now: Date = .now) -> Date {
        now.addingTimeInterval(5 * 60).roundedToNearest5Minutes()
    }
}

struct ReminderDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    let untie: () async -> Void
    let tie: () async -> Void
    let retie: (Date) async -> Void
    let delete: () -> Void
    let edit: () -> Void
    let quickPresetSettings: SettingsSnapshot

    init(
        item: TimelineItem,
        quickPresetSettings: SettingsSnapshot,
        untie: @escaping () async -> Void,
        tie: @escaping () async -> Void,
        retie: @escaping (Date) async -> Void,
        delete: @escaping () -> Void,
        edit: @escaping () -> Void
    ) {
        self.item = item
        self.quickPresetSettings = quickPresetSettings
        self.untie = untie
        self.tie = tie
        self.retie = retie
        self.delete = delete
        self.edit = edit
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
                    VStack(alignment: .leading, spacing: 22) {
                        summary
                        RetieSection(item: item, quickPresetSettings: quickPresetSettings, retie: retie, onComplete: { dismiss() })
                        actions
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                    NodusWaveDivider()
                        .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
    }

    // MARK: - Header

    /// Same chrome as the editor's header — chevron back, centered serif
    /// title — but the trailing slot is "edit" instead of "confirm",
    /// since a detail sheet doesn't commit a form, it just leads
    /// somewhere else.
    private var header: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Cancel") {
                dismiss()
            }

            Spacer()

            Text(item.title ?? "")
                .font(.cormorant(21, weight: .regular))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
                .lineLimit(1)

            Spacer()

            Button {
                edit()
                dismiss()
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xF5D7A8).opacity(0.86))
                    .frame(width: 46, height: 42)
                    .background(Color(hex: 0x0B1020).opacity(0.58), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(hex: 0xF0C98B).opacity(0.44), NodusPalette.accent.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(NodeButtonStyle())
            .accessibilityLabel("Edit")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let note = item.note {
                Text(NoteLinkifier.attributedText(for: note))
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.82))
                    .tint(NodusPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if !item.isCompleted {
                NodusActionButton(title: "Untie", systemName: "checkmark", tone: .primary) {
                    Task {
                        await untie()
                        dismiss()
                    }
                }
            } else {
                NodusActionButton(title: "Tie", systemName: "arrow.counterclockwise", tone: .primary) {
                    Task {
                        await tie()
                        dismiss()
                    }
                }
            }

            NodusActionButton(title: "Delete", systemName: "trash", tone: .destructive) {
                delete()
                dismiss()
            }
        }
    }
}

/// The retie controls (common quick presets + a custom relative offset + the
/// full calendar) shared between the knot detail sheet and the standalone
/// retie sheet opened from the thread's long-press menu — both need the
/// exact same picking behavior, just wrapped in a different scaffold.
struct RetieSection: View {
    let item: TimelineItem
    let quickPresetSettings: SettingsSnapshot
    let retie: (Date) async -> Void
    let onComplete: () -> Void
    @Environment(\.locale) private var locale
    @State private var retieDate: Date
    @State private var isShowingOffsetBuilder = false

    init(item: TimelineItem, quickPresetSettings: SettingsSnapshot, retie: @escaping (Date) async -> Void, onComplete: @escaping () -> Void) {
        self.item = item
        self.quickPresetSettings = quickPresetSettings
        self.retie = retie
        self.onComplete = onComplete
        let now = Date()
        // Preserve a still-upcoming scheduled time so retie begins from the
        // knot's actual plan. Only a past occurrence needs a fresh slot.
        self._retieDate = State(initialValue: item.scheduledAt < now
            ? .earliestReminderTime(now: now)
            : item.scheduledAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Retie the Knot")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            NodusDateTimeRow(
                title: "Pick date and time",
                date: $retieDate,
                mode: .dateAndTime,
                doneTitle: "Retie",
                minimumDate: Date(),
                maximumDate: dailyRetieEnd,
                showsLabel: false
            ) {
                perform(retieDate)
            }

            // Same chip-grid + wheel-builder logic as the repeat and
            // reminder constructors: a handful of common presets, plus a
            // "+" that builds an arbitrary "in N hours/days/weeks" offset
            // instead of being limited to fixed suggestions. `isActive`
            // stays false for all of them — gold fill means "this is the
            // current state" elsewhere (the at-time toggle, the active
            // repeat schedule), but these are one-shot actions that close
            // the sheet immediately, with nothing left to show as active.
            LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
                ForEach(quickPresets) { preset in
                    NodusToggleChip(title: preset.label(language: AppLanguage(locale: locale)), isActive: false) {
                        perform(preset.date)
                    }
                }

                if !isDaily {
                    NodusCustomValueChip(title: AppLanguage(locale: locale).localizedString("In…")) {
                        isShowingOffsetBuilder = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingOffsetBuilder) {
            NodusRetieOffsetBuilderSheet { date in
                perform(date)
            }
        }
    }

    private func perform(_ date: Date) {
        Task {
            await retie(date)
            onComplete()
        }
    }

    private var isDaily: Bool {
        item.repeatSchedule == .every(1, .days)
    }

    private var dailyRetieEnd: Date? {
        guard isDaily else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1)
    }

    private var quickPresets: [ReminderQuickPreset] {
        ReminderQuickPreset.all(settings: quickPresetSettings)
            .filter { preset in
                guard isDaily else { return true }
                return Calendar.current.isDateInToday(preset.date)
            }
    }

}

/// Opened directly from the thread's long-press action menu. It uses the same
/// common presets as the editor and detail sheet.
struct RetieSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    let quickPresetSettings: SettingsSnapshot
    let retie: (Date) async -> Void

    init(item: TimelineItem, quickPresetSettings: SettingsSnapshot, retie: @escaping (Date) async -> Void) {
        self.item = item
        self.quickPresetSettings = quickPresetSettings
        self.retie = retie
    }

    var body: some View {
        NodusPlainSheetScaffold(title: "Retie the Knot", close: { dismiss() }, headerStyle: .backOnly) {
            RetieSection(item: item, quickPresetSettings: quickPresetSettings, retie: retie) {
                dismiss()
            }
        }
        // Retie only presents a date picker and a few shortcuts, so a
        // compact sheet keeps the timeline visible behind it.
        .presentationDetents([.fraction(0.45)])
    }
}

/// A pause is a schedule-level exception for a recurring knot, not a move
/// of one occurrence. It therefore only needs an absolute end date.
struct PauseUntilSheet: View {
    let pause: (Date) async -> Void
    @State private var pauseUntil: Date

    init(initialDate: Date? = nil, pause: @escaping (Date) async -> Void) {
        self.pause = pause
        self._pauseUntil = State(initialValue: initialDate ?? Date().addingTimeInterval(24 * 60 * 60))
    }

    var body: some View {
        NodusDatePickerSheet(
            title: "Pause",
            date: $pauseUntil,
            mode: .dateAndTime,
            doneTitle: "Pause",
            minimumDate: .earliestReminderTime(),
            showsFooterButton: false
        ) {
            Task { await pause(pauseUntil) }
        }
    }
}
