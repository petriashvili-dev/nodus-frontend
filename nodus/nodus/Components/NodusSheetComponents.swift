import SwiftUI

#if os(iOS)
import UIKit
#endif

enum NodusSheetHeaderStyle {
    case titleAndClose
    case backOnly
    case backAndConfirm(action: () -> Void, isDisabled: Bool, accessibilityLabel: LocalizedStringKey)
}

struct NodusPlainSheetScaffold<Content: View>: View {

    let title: LocalizedStringKey
    let close: () -> Void
    var headerStyle: NodusSheetHeaderStyle = .titleAndClose
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()

                header

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        content
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(NodusPalette.background)
    }

    @ViewBuilder
    private var header: some View {
        switch headerStyle {
        case .titleAndClose:
            HStack {
                Spacer()

                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .foregroundStyle(NodusPalette.primary.opacity(0.92))

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.88))
                        .frame(width: 36, height: 36)
                        .background(Color(hex: 0x0B1020).opacity(0.54), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(NodusPalette.primary.opacity(0.06), lineWidth: 1)
                        }
                }
                .buttonStyle(NodeButtonStyle())
                .accessibilityLabel("Cancel")
            }
            .padding(.leading, 58)
            .padding(.trailing, 22)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .background(NodusPalette.background.opacity(0.92))
        case .backOnly:
            NodusSheetHeader(title: title, cancel: close)
        case let .backAndConfirm(action, isDisabled, accessibilityLabel):
            NodusSheetConfirmHeader(
                title: title,
                cancel: close,
                confirm: action,
                isDisabled: isDisabled,
                accessibilityLabel: accessibilityLabel
            )
        }
    }
}

/// A small echo of the app's own mark (the icon is a golden infinity
/// loop) standing in for a section rule — ties a sheet's chrome back to
/// the brand instead of using a plain generic divider. Shared by the
/// knot editor and the detail sheet.
struct NodusOrnamentDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            line(reversed: false)
            Circle()
                .fill(NodusPalette.accent.opacity(0.5))
                .frame(width: 4, height: 4)
            line(reversed: true)
        }
        .padding(.horizontal, 64)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    private func line(reversed: Bool) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, NodusPalette.accent.opacity(0.4)],
                    startPoint: reversed ? .trailing : .leading,
                    endPoint: reversed ? .leading : .trailing
                )
            )
            .frame(height: 1)
    }
}

struct NodusWaveDivider: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let midY = proxy.size.height / 2
                path.move(to: CGPoint(x: 0, y: midY))
                path.addCurve(
                    to: CGPoint(x: width, y: midY),
                    control1: CGPoint(x: width * 0.25, y: 0),
                    control2: CGPoint(x: width * 0.75, y: proxy.size.height)
                )
            }
            .stroke(
                LinearGradient(
                    colors: [.clear, NodusPalette.accent.opacity(0.32), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1
            )
        }
        .frame(height: 18)
        .padding(.horizontal, 50)
    }
}

struct NodusSheetDragIndicator: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(NodusPalette.secondary.opacity(0.34))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }
}

struct NodusSheetHeader: View {
    let title: LocalizedStringKey
    let cancel: () -> Void

    var body: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Cancel", action: cancel)
                .accessibilityHint(title)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// The compact editor-style header used by sheets that commit directly from
/// their calendar instead of reserving space for a bottom action button.
struct NodusSheetConfirmHeader: View {
    let title: LocalizedStringKey
    let cancel: () -> Void
    let confirm: () -> Void
    let isDisabled: Bool
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        HStack {
            IconCircleButton(systemName: "chevron.left", accessibilityLabel: "Cancel", action: cancel)
                .accessibilityHint(title)

            Spacer()

            NodusSheetConfirmButton(action: confirm, isDisabled: isDisabled, accessibilityLabel: accessibilityLabel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct NodusSheetConfirmButton: View {
    let action: () -> Void
    let isDisabled: Bool
    let accessibilityLabel: LocalizedStringKey

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isDisabled ? NodusPalette.secondary.opacity(0.5) : Color(hex: 0xF5D7A8).opacity(0.86))
                .frame(width: 46, height: 42)
                .background(Color(hex: 0x0B1020).opacity(0.58), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            isDisabled
                                ? LinearGradient(colors: [NodusPalette.primary.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                                : LinearGradient(
                                    colors: [Color(hex: 0xF0C98B).opacity(0.44), NodusPalette.accent.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(NodeButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct NodusSheetFooterButton: View {
    let title: LocalizedStringKey
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(isDisabled ? NodusPalette.dim.opacity(0.72) : Color(hex: 0xF5D7A8))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    isDisabled ? Color(hex: 0x0B1020).opacity(0.54) : NodusPalette.accent.opacity(0.18),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(isDisabled ? NodusPalette.primary.opacity(0.06) : NodusPalette.accent.opacity(0.36), lineWidth: 1)
                }
        }
        .buttonStyle(NodeButtonStyle())
        .disabled(isDisabled)
        .padding(.top, 4)
    }
}

struct NodusSheetSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .default))
                    .tracking(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(NodusPalette.secondary.opacity(0.64))
            }

            VStack(spacing: 12) {
                content
            }
            .padding(15)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(hex: 0x111827).opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(NodusPalette.primary.opacity(0.07), lineWidth: 1)
            }
        }
    }
}

struct NodusTextField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?
    /// Multiline `TextField`s treat Return as a newline, not a submit —
    /// set this to intercept the trailing "\n" and fire `onSubmit` instead.
    var dismissesOnReturn: Bool = false
    var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    init(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey? = nil,
        text: Binding<String>,
        axis: Axis = .horizontal,
        lineLimit: ClosedRange<Int>? = nil,
        submitLabel: SubmitLabel = .done,
        onSubmit: (() -> Void)? = nil,
        dismissesOnReturn: Bool = false,
        focus: FocusState<Bool>.Binding? = nil
    ) {
        self.title = title
        self.placeholder = placeholder ?? title
        self._text = text
        self.axis = axis
        self.lineLimit = lineLimit
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.dismissesOnReturn = dismissesOnReturn
        self.externalFocus = focus
    }

    private var isFocused: Bool {
        externalFocus?.wrappedValue ?? internalFocus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NodusSoftChangingText(
                text: title,
                token: String(describing: title),
                font: .system(size: 12, weight: .regular, design: .default),
                color: NodusPalette.secondary.opacity(0.72)
            )

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    NodusSoftChangingText(
                        text: placeholder,
                        token: String(describing: placeholder),
                        font: .system(size: 16, weight: .regular, design: .default),
                        color: NodusPalette.secondary.opacity(0.36)
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
                }

                TextField("", text: $text, axis: axis)
                    .modifier(NodusLineLimitModifier(lineLimit: lineLimit))
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(NodusPalette.primary.opacity(0.92))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .focused(externalFocus ?? $internalFocus)
                    .submitLabel(submitLabel)
                    .onSubmit { onSubmit?() }
                    .onChange(of: text) { newValue in
                        guard dismissesOnReturn, newValue.hasSuffix("\n") else { return }
                        text = String(newValue.dropLast())
                        onSubmit?()
                    }
            }
                .background(Color(hex: 0x0B1020).opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isFocused ? NodusPalette.accent.opacity(0.6) : NodusPalette.primary.opacity(0.06), lineWidth: isFocused ? 1.4 : 1)
                }
                .shadow(color: isFocused ? NodusPalette.accent.opacity(0.22) : .clear, radius: isFocused ? 8 : 0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

private struct NodusSoftChangingText: View {
    let text: LocalizedStringKey
    let token: String
    let font: Font
    let color: Color

    var body: some View {
        Text(text)
            .id(token)
            .font(font)
            .foregroundStyle(color)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .move(edge: .top))
                )
            )
            .animation(.easeInOut(duration: 0.28), value: token)
    }
}

private struct NodusLineLimitModifier: ViewModifier {
    let lineLimit: ClosedRange<Int>?

    func body(content: Content) -> some View {
        if let lineLimit {
            content.lineLimit(lineLimit)
        } else {
            content.lineLimit(1)
        }
    }
}

struct NodusSegmentedPicker<Option: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Option, LocalizedStringKey)]
    @Binding var selection: Option
    var showsTitle = true
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.0) { option, label in
                    Button {
                        selection = option
                    } label: {
                        Text(label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(selection == option ? Color(hex: 0xF5D7A8) : NodusPalette.secondary.opacity(0.82))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(selection == option ? NodusPalette.accent.opacity(0.14) : Color(hex: 0x0B1020).opacity(0.46), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(selection == option ? NodusPalette.accent.opacity(0.34) : NodusPalette.primary.opacity(0.05), lineWidth: 1)
                            }
                    }
                    .disabled(isDisabled)
                }
            }
            .opacity(isDisabled ? 0.55 : 1)
        }
    }
}

/// Same chip look as `NodusSegmentedPicker`, but multiple options can be on
/// at once — used for things like "remind me before" where more than one
/// lead time can apply.
struct NodusMultiSelectChips<Option: Hashable>: View {
    let title: LocalizedStringKey
    let options: [(Option, LocalizedStringKey)]
    @Binding var selection: Set<Option>
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.0) { option, label in
                    let isSelected = selection.contains(option)
                    Button {
                        if isSelected {
                            selection.remove(option)
                        } else {
                            selection.insert(option)
                        }
                    } label: {
                        Text(label)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .foregroundStyle(isSelected ? Color(hex: 0xF5D7A8) : NodusPalette.secondary.opacity(0.82))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(isSelected ? NodusPalette.accent.opacity(0.14) : Color(hex: 0x0B1020).opacity(0.46), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .stroke(isSelected ? NodusPalette.accent.opacity(0.34) : NodusPalette.primary.opacity(0.05), lineWidth: 1)
                            }
                    }
                }
            }
        }
    }
}

/// A single-select pill row with a bolder, filled-gold selected state (and
/// a soft glow) than `NodusSegmentedPicker`'s grid — used where the choice
/// itself is the visual focal point of the row, like the knot editor's
/// repeat/notification pickers, rather than one control among many in a
/// settings list.
let nodusChipGridColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

struct NodusChipPicker<Option: Hashable>: View {
    let options: [(option: Option, label: LocalizedStringKey, icon: String?)]
    @Binding var selection: Option

    init(options: [(Option, LocalizedStringKey, String?)], selection: Binding<Option>) {
        self.options = options.map { (option: $0.0, label: $0.1, icon: $0.2) }
        self._selection = selection
    }

    var body: some View {
        LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
            ForEach(options, id: \.option) { entry in
                NodusChip(
                    label: entry.label,
                    icon: entry.icon,
                    isSelected: selection == entry.option
                ) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selection = entry.option
                    }
                }
            }
        }
    }
}

/// Same look as `NodusChipPicker`, but more than one chip can be lit at
/// once — used for "remind me before" lead times.
struct NodusChipMultiPicker<Option: Hashable>: View {
    let options: [(option: Option, label: LocalizedStringKey, icon: String?)]
    @Binding var selection: Set<Option>

    init(options: [(Option, LocalizedStringKey, String?)], selection: Binding<Set<Option>>) {
        self.options = options.map { (option: $0.0, label: $0.1, icon: $0.2) }
        self._selection = selection
    }

    var body: some View {
        LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
            ForEach(options, id: \.option) { entry in
                let isSelected = selection.contains(entry.option)
                NodusChip(label: entry.label, icon: entry.icon, isSelected: isSelected) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        if isSelected {
                            selection.remove(entry.option)
                        } else {
                            selection.insert(entry.option)
                        }
                    }
                }
            }
        }
    }
}

/// A square tile — icon (if any) above the label — rather than a pill, so
/// a full option set lays out as a grid instead of needing a horizontal
/// scroll to fit them all.
private struct NodusChip: View {
    let label: LocalizedStringKey
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color(hex: 0x1A1404) : NodusPalette.secondary.opacity(0.82))
            .frame(maxWidth: .infinity)
            .frame(height: icon != nil ? 60 : 44)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? NodusPalette.accent : Color(hex: 0x0B1020).opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? NodusPalette.accent : NodusPalette.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: isSelected ? NodusPalette.accent.opacity(0.45) : .clear, radius: isSelected ? 8 : 0, y: isSelected ? 2 : 0)
        }
        .buttonStyle(.plain)
    }
}

/// The universal "remind me before" constructor — the same mechanism
/// whether a knot needs exactly one reminder (a task) or several at once
/// (a yearly anniversary's 7-days/1-day/at-the-moment set). Every chip is
/// a plain press toggle — "at time" dims instead of disappearing (it's
/// the one fixed slot every knot always has), custom ones disappear on
/// tap since there's nothing to keep around once turned off. No "x" badge
/// anywhere; the press itself (a visible depress animation) is the
/// affordance.
struct NodusLeadTimePicker: View {
    @Binding var leadTimes: [ReminderLeadTime]
    @Environment(\.locale) private var locale
    @State private var isShowingAddSheet = false

    var body: some View {
        LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
            NodusLeadTimeChip(leadTime: .atTime, isActive: leadTimes.contains(.atTime)) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    if leadTimes.contains(.atTime) {
                        leadTimes.removeAll { $0 == .atTime }
                    } else {
                        leadTimes.append(.atTime)
                    }
                }
            }

            ForEach(customLeadTimes) { leadTime in
                NodusLeadTimeChip(leadTime: leadTime, isActive: true) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        leadTimes.removeAll { $0 == leadTime }
                    }
                }
            }

            NodusCustomValueChip(title: AppLanguage(locale: locale).localizedString("Before…")) {
                isShowingAddSheet = true
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            NodusLeadTimeBuilderSheet { newLeadTime in
                guard !leadTimes.contains(newLeadTime) else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    leadTimes.append(newLeadTime)
                }
            }
        }
    }

    private var customLeadTimes: [ReminderLeadTime] {
        leadTimes.filter { !$0.isAtTime }
    }
}

/// A momentary "pressed in" scale, distinct from the chip's own
/// active/inactive fill — every chip gets this on tap regardless of what
/// the tap ends up doing (toggle or remove).
struct NodusChipPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Opens a one-off custom value; it never adds an item to the visible list.
struct NodusCustomValueChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .foregroundStyle(NodusPalette.accent.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 4)
                .background(NodusPalette.surface.opacity(0.25), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(NodusPalette.accent.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
        }
        .buttonStyle(NodusChipPressButtonStyle())
        .accessibilityHint("Opens a custom value picker")
    }
}

private struct NodusLeadTimeChip: View {
    let leadTime: ReminderLeadTime
    let isActive: Bool
    let action: () -> Void
    @Environment(\.locale) private var locale

    private var language: AppLanguage {
        AppLanguage(locale: locale)
    }

    var body: some View {
        Button(action: action) {
            Text(labelText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isActive ? Color(hex: 0x1A1404) : NodusPalette.secondary.opacity(0.72))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 4)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isActive ? NodusPalette.accent : Color(hex: 0x0B1020).opacity(0.5))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isActive ? NodusPalette.accent : NodusPalette.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: isActive ? NodusPalette.accent.opacity(0.4) : .clear, radius: isActive ? 6 : 0, y: isActive ? 2 : 0)
        }
        .buttonStyle(NodusChipPressButtonStyle())
    }

    /// Russian and English put the "before" word on opposite sides of the
    /// number ("за 15 минут" vs "15 minutes before"), so this assembles
    /// the phrase per language rather than just concatenating a shared
    /// prefix.
    private var labelText: String {
        guard !leadTime.isAtTime else { return language.localizedString("At time") }
        let unitWord = leadTime.unit.localizedLabel(for: leadTime.amount, language: language)
        guard language != .ru else {
            return "за \(leadTime.amount) \(unitWord)"
        }
        return "\(leadTime.amount) \(unitWord) before"
    }
}

/// Builds one custom `ReminderLeadTime` at a time — the "at the moment"
/// reminder is always on already (see `NodusLeadTimePicker`), so this is
/// only ever for the extra, specific ones.
struct NodusLeadTimeBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amount = 15
    @State private var unit: LeadTimeUnit = .minutes
    let onAdd: (ReminderLeadTime) -> Void

    var body: some View {
        NodusPlainSheetScaffold(title: "Remind before", close: { dismiss() }, headerStyle: .backOnly) {
            NodusSheetSection(title: "Remind before") {
                // Unit picked first, then the amount — choosing "hours"
                // before "2" reads more naturally than the reverse, and it
                // lets the amount wheel's own range adapt to the unit
                // (e.g. hours stops at 23, since 24 is just "1 day").
                HStack(spacing: 12) {
                    NodusWheelPicker(title: "Unit", values: Array(0..<LeadTimeUnit.allCases.count), selection: unitIndexBinding, label: unitLabel)
                    NodusWheelPicker(title: "Amount", values: amountValues, selection: $amount, label: { "\($0)" })
                }
            }

            NodusSheetFooterButton(title: "Add", isDisabled: false) {
                onAdd(ReminderLeadTime(amount: amount, unit: unit))
                dismiss()
            }
        }
        .onChange(of: unit) { _, newUnit in
            // Switching units can land on a value the new unit doesn't
            // have at all (minutes only offers multiples of 5) — snap to
            // whichever valid value is closest instead of just clamping.
            let validValues = amountValues(for: newUnit)
            if !validValues.contains(amount) {
                amount = validValues.min(by: { abs($0 - amount) < abs($1 - amount) }) ?? amount
            }
        }
    }

    private var unitIndexBinding: Binding<Int> {
        Binding(
            get: { LeadTimeUnit.allCases.firstIndex(of: unit) ?? 0 },
            set: { unit = LeadTimeUnit.allCases[$0] }
        )
    }

    private var amountValues: [Int] {
        amountValues(for: unit)
    }

    /// Minutes only offers multiples of 5 (matching the date/time picker's
    /// own minute wheel elsewhere in the app). Hours stops at 23 — past
    /// that it's just "1 day", already its own unit. Days goes up to a
    /// month out.
    private func amountValues(for unit: LeadTimeUnit) -> [Int] {
        switch unit {
        case .minutes: Array(stride(from: 5, through: 55, by: 5))
        case .hours: Array(1...23)
        case .days: Array(1...30)
        }
    }

    /// Pluralized against the amount wheel's current value, so the unit
    /// column itself reads grammatically correct as the user scrolls
    /// (e.g. switches from "минута" to "минуты" past 1) rather than
    /// showing a fixed plural regardless of the chosen number.
    private func unitLabel(_ index: Int) -> String {
        guard LeadTimeUnit.allCases.indices.contains(index) else { return "" }
        return LeadTimeUnit.allCases[index].localizedLabel(for: amount, language: AppLanguage(locale: locale))
    }
}

/// The universal repeat constructor — "no repeat", "weekdays", and the
/// common yearly cadence stay as fixed, single-select chips. The first two
/// do not fit the "every N units" shape; the yearly option makes birthdays
/// fast to create. Any other interval goes through the wheel builder.
struct NodusRepeatPicker: View {
    @Binding var schedule: RepeatSchedule
    @Environment(\.locale) private var locale
    @State private var isShowingBuilder = false

    private static let yearlySchedule = RepeatSchedule.every(1, .years)

    private var language: AppLanguage {
        AppLanguage(locale: locale)
    }

    var body: some View {
        LazyVGrid(columns: nodusChipGridColumns, spacing: 8) {
            NodusToggleChip(title: language.localizedString("No repeat"), isActive: schedule == .none) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    schedule = .none
                }
            }

            NodusToggleChip(title: language.localizedString("Weekdays"), isActive: schedule == .weekdays) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    schedule = .weekdays
                }
            }

            NodusToggleChip(title: Self.yearlySchedule.displayLabel(language: language), isActive: schedule == Self.yearlySchedule) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    schedule = Self.yearlySchedule
                }
            }

            if schedule.kind == .interval, schedule != Self.yearlySchedule {
                NodusToggleChip(title: schedule.displayLabel(language: language), isActive: true) {
                    isShowingBuilder = true
                }
            }

            NodusCustomValueChip(title: language.localizedString("Custom repeat…")) {
                isShowingBuilder = true
            }
        }
        .sheet(isPresented: $isShowingBuilder) {
            NodusRepeatBuilderSheet(initial: schedule.kind == .interval ? schedule : .every(1, .days)) { newSchedule in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    schedule = newSchedule
                }
            }
        }
    }
}

struct NodusToggleChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isActive ? Color(hex: 0x241E16) : NodusPalette.secondary.opacity(0.74))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 4)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isActive ? NodusPalette.accent : NodusPalette.surface.opacity(0.42))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isActive ? NodusPalette.accent.opacity(0.72) : NodusPalette.softLine.opacity(0.58),
                            lineWidth: 1
                        )
                }
                // A quiet halo keeps the selected option tactile without
                // turning the chip into the screen's visual focal point.
                .shadow(color: isActive ? NodusPalette.accent.opacity(0.22) : .clear, radius: isActive ? 10 : 0, y: isActive ? 3 : 0)
        }
        .buttonStyle(NodusChipPressButtonStyle())
    }
}

/// Builds one "every N days/weeks/months/years" schedule — opened either
/// fresh (defaulting to "every 1 day") or pre-filled with whatever custom
/// interval is already active, so re-tapping it to tweak the value feels
/// like editing rather than starting over.
struct NodusRepeatBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amount: Int
    @State private var unit: RepeatIntervalUnit
    let onAdd: (RepeatSchedule) -> Void

    init(initial: RepeatSchedule, onAdd: @escaping (RepeatSchedule) -> Void) {
        self._amount = State(initialValue: initial.amount)
        self._unit = State(initialValue: initial.unit)
        self.onAdd = onAdd
    }

    var body: some View {
        NodusPlainSheetScaffold(title: "Repeat", close: { dismiss() }, headerStyle: .backOnly) {
            NodusSheetSection(title: "Repeat") {
                HStack(spacing: 12) {
                    NodusWheelPicker(title: "Unit", values: Array(0..<RepeatIntervalUnit.allCases.count), selection: unitIndexBinding, label: unitLabel)
                    NodusWheelPicker(title: "Amount", values: amountValues, selection: $amount, label: { "\($0)" })
                }
            }

            NodusSheetFooterButton(title: "Add", isDisabled: false) {
                onAdd(.every(amount, unit))
                dismiss()
            }
        }
        .onChange(of: unit) { _, newUnit in
            let validValues = amountValues(for: newUnit)
            if !validValues.contains(amount) {
                amount = validValues.min(by: { abs($0 - amount) < abs($1 - amount) }) ?? amount
            }
        }
    }

    private var unitIndexBinding: Binding<Int> {
        Binding(
            get: { RepeatIntervalUnit.allCases.firstIndex(of: unit) ?? 0 },
            set: { unit = RepeatIntervalUnit.allCases[$0] }
        )
    }

    private var amountValues: [Int] {
        amountValues(for: unit)
    }

    private func amountValues(for unit: RepeatIntervalUnit) -> [Int] {
        switch unit {
        case .days: Array(1...30)
        case .weeks: Array(1...12)
        case .months: Array(1...24)
        case .years: Array(1...10)
        }
    }

    private func unitLabel(_ index: Int) -> String {
        guard RepeatIntervalUnit.allCases.indices.contains(index) else { return "" }
        return RepeatIntervalUnit.allCases[index].localizedLabel(for: amount, language: AppLanguage(locale: locale))
    }
}

/// Hours/days/weeks only — retying is always relative to "now," and
/// nobody reschedules a knot by a custom number of minutes or reaches for
/// months/years here (the absolute calendar below covers anything that
/// far out).
enum RetieOffsetUnit: String, CaseIterable, Identifiable {
    case hours
    case days
    case weeks

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .hours: 60 * 60
        case .days: 24 * 60 * 60
        case .weeks: 7 * 24 * 60 * 60
        }
    }

    /// Accusative, since this always reads as "через ..." ("через 3
    /// часа") — only the singular week form differs from nominative
    /// ("неделю" vs "неделя"); hour and day are masculine inanimate, so
    /// their accusative is identical to nominative.
    func localizedLabel(for amount: Int, language: AppLanguage) -> String {
        guard language == .ru else {
            switch self {
            case .hours: return amount == 1 ? "hour" : "hours"
            case .days: return amount == 1 ? "day" : "days"
            case .weeks: return amount == 1 ? "week" : "weeks"
            }
        }

        let forms: (one: String, few: String, many: String)
        switch self {
        case .hours: forms = ("час", "часа", "часов")
        case .days: forms = ("день", "дня", "дней")
        case .weeks: forms = ("неделю", "недели", "недель")
        }

        let mod100 = amount % 100
        if (11...14).contains(mod100) {
            return forms.many
        }
        switch amount % 10 {
        case 1: return forms.one
        case 2, 3, 4: return forms.few
        default: return forms.many
        }
    }
}

/// Builds a relative "retie in N hours/days/weeks from now" offset — the
/// same unit-then-amount wheel pair as the repeat and reminder
/// constructors, just computing a one-shot date instead of storing a
/// rule.
struct NodusRetieOffsetBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amount = 3
    @State private var unit: RetieOffsetUnit = .hours
    let onPick: (Date) -> Void

    var body: some View {
        NodusPlainSheetScaffold(title: "Retie the Knot", close: { dismiss() }, headerStyle: .backOnly) {
            NodusSheetSection(title: "Retie the Knot") {
                HStack(spacing: 12) {
                    NodusWheelPicker(title: "Unit", values: Array(0..<RetieOffsetUnit.allCases.count), selection: unitIndexBinding, label: unitLabel)
                    NodusWheelPicker(title: "Amount", values: amountValues, selection: $amount, label: { "\($0)" })
                }
            }

            NodusSheetFooterButton(title: "Retie", isDisabled: false) {
                onPick(Date().addingTimeInterval(unit.seconds * Double(amount)).roundedToNearest5Minutes())
                dismiss()
            }
        }
        .onChange(of: unit) { _, newUnit in
            let validValues = amountValues(for: newUnit)
            if !validValues.contains(amount) {
                amount = validValues.min(by: { abs($0 - amount) < abs($1 - amount) }) ?? amount
            }
        }
    }

    private var unitIndexBinding: Binding<Int> {
        Binding(
            get: { RetieOffsetUnit.allCases.firstIndex(of: unit) ?? 0 },
            set: { unit = RetieOffsetUnit.allCases[$0] }
        )
    }

    private var amountValues: [Int] {
        amountValues(for: unit)
    }

    private func amountValues(for unit: RetieOffsetUnit) -> [Int] {
        switch unit {
        case .hours: Array(1...23)
        case .days: Array(1...30)
        case .weeks: Array(1...8)
        }
    }

    private func unitLabel(_ index: Int) -> String {
        guard RetieOffsetUnit.allCases.indices.contains(index) else { return "" }
        return RetieOffsetUnit.allCases[index].localizedLabel(for: amount, language: AppLanguage(locale: locale))
    }
}

/// Not a view — just the shared `Mode` namespace used by `NodusDateTimeRow`
/// and `NodusDatePickerSheet`.
enum NodusDateField {
    enum Mode {
        case dateAndTime
        case dateOnly
    }
}

/// A combined calendar+clock row — date on the left, time on the right
/// (separated by a thin divider), chevron pinned to the trailing edge
/// independent of how wide the date/time text is. Shared by the knot
/// editor and the detail sheet's retie controls so both pick a date the
/// same way.
struct NodusDateTimeRow: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringKey
    @Binding var date: Date
    var mode: NodusDateField.Mode = .dateAndTime
    var doneTitle: LocalizedStringKey = "Done"
    var minimumDate: Date?
    var maximumDate: Date?
    var showsLabel: Bool = true
    var onDone: (() -> Void)?
    @State private var isShowingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                Text(title)
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            }

            Button {
                isShowingPicker = true
            } label: {
                ZStack {
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            Image(systemName: "calendar")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(NodusPalette.accent.opacity(0.86))
                            Text(dateOnlyText)
                                .font(.system(size: 15, weight: .regular, design: .default))
                                .foregroundStyle(NodusPalette.primary.opacity(0.92))
                                .monospacedDigit()
                        }

                        if mode == .dateAndTime {
                            Rectangle()
                                .fill(NodusPalette.primary.opacity(0.08))
                                .frame(width: 1, height: 18)

                            HStack(spacing: 9) {
                                Image(systemName: "clock")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(NodusPalette.accent.opacity(0.86))
                                Text(timeOnlyText)
                                    .font(.system(size: 15, weight: .regular, design: .default))
                                    .foregroundStyle(NodusPalette.primary.opacity(0.92))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NodusPalette.secondary.opacity(0.5))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0x0B1020).opacity(0.66), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(NodusPalette.primary.opacity(0.06), lineWidth: 1)
                }
            }
            .buttonStyle(NodeButtonStyle(intensity: .subtle))
            .sheet(isPresented: $isShowingPicker) {
                NodusDatePickerSheet(title: title, date: $date, mode: mode, doneTitle: doneTitle, minimumDate: minimumDate, maximumDate: maximumDate) {
                    onDone?()
                }
            }
        }
    }

    private var dateOnlyText: String {
        date.formatted(.dateTime.day().month(.wide).year().locale(locale))
    }

    private var timeOnlyText: String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Not private: also used directly (without `NodusDateField`'s extra tap
/// to open it) wherever a calendar + time picker needs to be the very
/// first thing shown, such as the thread's "Retie" action menu item.
struct NodusDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let title: LocalizedStringKey
    @Binding var date: Date
    let mode: NodusDateField.Mode
    var doneTitle: LocalizedStringKey = "Done"
    var minimumDate: Date?
    var maximumDate: Date?
    var onDone: (() -> Void)?
    var showsFooterButton = true
    @State private var visibleMonth: Date
    @State private var monthDirection = 1
    @State private var isShowingMonthYearPicker = false
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }

    init(
        title: LocalizedStringKey,
        date: Binding<Date>,
        mode: NodusDateField.Mode,
        doneTitle: LocalizedStringKey = "Done",
        minimumDate: Date? = nil,
        maximumDate: Date? = nil,
        showsFooterButton: Bool = true,
        onDone: (() -> Void)? = nil
    ) {
        self.title = title
        self._date = date
        self.mode = mode
        self.doneTitle = doneTitle
        self.minimumDate = minimumDate
        self.maximumDate = maximumDate
        self.showsFooterButton = showsFooterButton
        self.onDone = onDone
        self._visibleMonth = State(initialValue: Calendar.current.startOfMonth(for: date.wrappedValue))
    }

    var body: some View {
        NodusPlainSheetScaffold(title: title, close: { dismiss() }, headerStyle: headerStyle) {
            calendarSection
            if mode == .dateAndTime {
                timeSection
            }
            if showsFooterButton {
                NodusSheetFooterButton(title: doneTitle, isDisabled: isOutOfRange) {
                    confirm()
                }
            }
        }
    }

    private var headerStyle: NodusSheetHeaderStyle {
        guard !showsFooterButton else { return .backOnly }
        return .backAndConfirm(action: confirm, isDisabled: isOutOfRange, accessibilityLabel: doneTitle)
    }

    private func confirm() {
        onDone?()
        dismiss()
    }

    private var isOutOfRange: Bool {
        if let minimumDate, date < minimumDate { return true }
        if let maximumDate, date > maximumDate { return true }
        return false
    }

    private func isDayDisabled(_ day: Date) -> Bool {
        if let minimumDate, calendar.startOfDay(for: day) < calendar.startOfDay(for: minimumDate) {
            return true
        }
        if let maximumDate, calendar.startOfDay(for: day) > calendar.startOfDay(for: maximumDate) {
            return true
        }
        return false
    }

    private var calendarSection: some View {
        NodusSheetSection(title: "Date") {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    NodusMiniIconButton(systemName: "chevron.left", accessibilityLabel: "Previous Month") {
                        moveMonth(by: -1)
                    }
                    .disabled(!canMoveMonth(by: -1))

                    Button {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            isShowingMonthYearPicker.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(visibleMonth.formatted(.dateTime.month(.wide).year().locale(locale)))
                                .font(.system(size: 16, weight: .medium, design: .default))

                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(isShowingMonthYearPicker ? 180 : 0))
                        }
                        .foregroundStyle(NodusPalette.primary.opacity(0.9))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NodeButtonStyle(intensity: .subtle))
                    .accessibilityLabel("Month and Year")

                    NodusMiniIconButton(systemName: "chevron.right", accessibilityLabel: "Next Month") {
                        moveMonth(by: 1)
                    }
                    .disabled(!canMoveMonth(by: 1))
                }

                if isShowingMonthYearPicker {
                    monthYearPicker
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ZStack {
                    calendarGrid
                        .id(visibleMonth)
                        .transition(monthTransition)
                }
                .frame(minHeight: 278)
                .clipped()
                .contentShape(Rectangle())
                .gesture(monthSwipeGesture)
            }
        }
    }

    private var monthYearPicker: some View {
        HStack(spacing: 12) {
            NodusWheelPicker(
                title: "Month",
                values: availableMonths,
                selection: monthBinding,
                label: monthName
            )

            NodusWheelPicker(title: "Year", values: yearValues, selection: yearBinding)
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium, design: .default))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.62))
                    .frame(height: 22)
            }

            ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    Button {
                        select(day)
                    } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(dayForeground(for: day))
                            .frame(width: 36, height: 36)
                            .background(dayBackground(for: day), in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(dayStroke(for: day), lineWidth: 1)
                            }
                            .opacity(isDayDisabled(day) ? 0.32 : 1)
                    }
                    .buttonStyle(NodeButtonStyle(intensity: .subtle))
                    .disabled(isDayDisabled(day))
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }
        }
    }

    private var timeSection: some View {
        NodusSheetSection(title: "Time") {
            VStack(spacing: 14) {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)))
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(NodusPalette.secondary.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    NodusWheelPicker(title: "Hour", values: availableHours, selection: hourBinding)
                    NodusWheelPicker(title: "Minute", values: availableMinutes, selection: minuteBinding)
                }
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols.map {
            $0
                .replacingOccurrences(of: ".", with: "")
                .lowercased(with: locale)
        }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var calendarDays: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        let firstDay = calendar.startOfMonth(for: visibleMonth)
        let leading = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        var days = Array(repeating: Optional<Date>.none, count: leading)
        days += range.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        let remainder = days.count % 7
        if remainder != 0 {
            days += Array(repeating: Optional<Date>.none, count: 7 - remainder)
        }
        return days
    }

    private var hour: Int {
        calendar.component(.hour, from: date)
    }

    private var minute: Int {
        calendar.component(.minute, from: date)
    }

    private var roundedMinute: Int {
        min(55, max(0, Int((Double(minute) / 5.0).rounded()) * 5))
    }

    /// True once the day currently selected is the same day as `minimumDate`
    /// — that's the only day where some hours/minutes are still in the past.
    private var isOnMinimumDay: Bool {
        guard let minimumDate else { return false }
        return calendar.isDate(date, inSameDayAs: minimumDate)
    }

    private var availableHours: [Int] {
        guard let minimumDate, isOnMinimumDay else { return Array(0..<24) }
        let minHour = calendar.component(.hour, from: minimumDate)
        let minMinute = calendar.component(.minute, from: minimumDate)
        // If the minimum minute is past the last 5-minute mark in its hour
        // (56-59), that hour has no valid mark left — start from the next one.
        let startHour = minMinute <= 55 ? minHour : minHour + 1
        return Array(startHour..<24)
    }

    private var availableMinutes: [Int] {
        let allMinutes = Array(stride(from: 0, through: 55, by: 5))
        guard let minimumDate, isOnMinimumDay, hour == calendar.component(.hour, from: minimumDate) else {
            return allMinutes
        }
        let minMinute = calendar.component(.minute, from: minimumDate)
        let ceilMinMinute = min(55, ((minMinute + 4) / 5) * 5)
        return allMinutes.filter { $0 >= ceilMinMinute }
    }

    private var visibleYear: Int {
        calendar.component(.year, from: visibleMonth)
    }

    private var visibleMonthNumber: Int {
        calendar.component(.month, from: visibleMonth)
    }

    /// Keep the month wheel aligned with the calendar navigation boundary.
    /// Without this, a new knot could expose previous months through the
    /// wheel even though selecting a day in them is disabled.
    private var availableMonths: [Int] {
        var range = 1...12

        if let minimumDate,
           visibleYear == calendar.component(.year, from: minimumDate) {
            range = calendar.component(.month, from: minimumDate)...12
        }

        if let maximumDate,
           visibleYear == calendar.component(.year, from: maximumDate) {
            range = range.lowerBound...calendar.component(.month, from: maximumDate)
        }

        return Array(range)
    }

    private var yearValues: [Int] {
        let currentYear = calendar.component(.year, from: Date())
        let firstYear = calendar.component(.year, from: minimumDate ?? Date())
        switch mode {
        case .dateOnly:
            return Array((minimumDate == nil ? currentYear - 120 : firstYear)...currentYear)
        case .dateAndTime:
            return Array(firstYear...(currentYear + 10))
        }
    }

    private var monthBinding: Binding<Int> {
        Binding(
            get: { visibleMonthNumber },
            set: { setVisibleMonth(month: $0, year: visibleYear) }
        )
    }

    private var yearBinding: Binding<Int> {
        Binding(
            get: { visibleYear },
            set: { setVisibleMonth(month: visibleMonthNumber, year: $0) }
        )
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { hour },
            set: { setTime(hour: $0, minute: roundedMinute) }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { roundedMinute },
            set: { setTime(hour: hour, minute: $0) }
        )
    }

    private var monthTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: monthDirection > 0 ? .trailing : .leading)),
            removal: .opacity.combined(with: .move(edge: monthDirection > 0 ? .leading : .trailing))
        )
    }

    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 44 else { return }
                moveMonth(by: value.translation.width < 0 ? 1 : -1)
            }
    }

    private func moveMonth(by value: Int) {
        guard canMoveMonth(by: value) else { return }
        monthDirection = value >= 0 ? 1 : -1
        withAnimation(.easeInOut(duration: 0.28)) {
            visibleMonth = calendar.date(byAdding: .month, value: value, to: visibleMonth) ?? visibleMonth
        }
    }

    private func canMoveMonth(by value: Int) -> Bool {
        guard let proposedMonth = calendar.date(byAdding: .month, value: value, to: visibleMonth) else { return false }
        if let minimumDate, proposedMonth < calendar.startOfMonth(for: minimumDate) {
            return false
        }
        if let maximumDate, proposedMonth > calendar.startOfMonth(for: maximumDate) {
            return false
        }
        return true
    }

    private func setVisibleMonth(month: Int, year: Int) {
        let previousMonth = visibleMonth
        var components = calendar.dateComponents([.day, .hour, .minute], from: date)
        components.year = year
        components.month = month
        components.day = min(components.day ?? 1, numberOfDays(inMonth: month, year: year))

        guard let proposedDate = calendar.date(from: components) else { return }
        // The wheel can select a month in the same year even when the
        // previous-month button is disabled. Clamp its resulting date too,
        // otherwise a new knot can temporarily be placed in the past.
        let newDate: Date
        if let minimumDate, proposedDate < minimumDate {
            newDate = minimumDate
        } else if let maximumDate, proposedDate > maximumDate {
            newDate = maximumDate
        } else {
            newDate = proposedDate
        }
        monthDirection = newDate >= previousMonth ? 1 : -1
        withAnimation(.easeInOut(duration: 0.28)) {
            visibleMonth = calendar.startOfMonth(for: newDate)
            date = mode == .dateOnly
                ? (calendar.date(bySettingHour: 9, minute: 0, second: 0, of: newDate) ?? newDate)
                : newDate
        }
    }

    private func select(_ day: Date) {
        let selectedHour = mode == .dateOnly ? 9 : hour
        let selectedMinute = mode == .dateOnly ? 0 : minute
        var newDate = calendar.date(bySettingHour: selectedHour, minute: selectedMinute, second: 0, of: day) ?? day
        if let minimumDate, newDate < minimumDate, calendar.isDate(newDate, inSameDayAs: minimumDate) {
            newDate = minimumDate
        }
        date = newDate
        withAnimation(.easeInOut(duration: 0.24)) {
            visibleMonth = calendar.startOfMonth(for: date)
        }
    }

    private func setTime(hour: Int, minute: Int) {
        date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    private func monthName(_ month: Int) -> String {
        guard calendar.monthSymbols.indices.contains(month - 1) else { return "\(month)" }
        return calendar.monthSymbols[month - 1].capitalized(with: locale)
    }

    private func numberOfDays(inMonth month: Int, year: Int) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = month
        guard let date = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 28
        }
        return range.count
    }

    private func dayForeground(for day: Date) -> Color {
        calendar.isDate(day, inSameDayAs: date) ? Color(hex: 0xF5D7A8) : NodusPalette.primary.opacity(0.86)
    }

    private func dayBackground(for day: Date) -> Color {
        if calendar.isDate(day, inSameDayAs: date) {
            return NodusPalette.accent.opacity(0.18)
        }
        if calendar.isDateInToday(day) {
            return NodusPalette.accent.opacity(0.06)
        }
        return Color(hex: 0x0B1020).opacity(0.38)
    }

    private func dayStroke(for day: Date) -> Color {
        if calendar.isDate(day, inSameDayAs: date) {
            return NodusPalette.accent.opacity(0.36)
        }
        if calendar.isDateInToday(day) {
            return NodusPalette.accent.opacity(0.18)
        }
        return NodusPalette.primary.opacity(0.04)
    }
}

private struct NodusMiniIconButton: View {
    let systemName: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0xF5D7A8).opacity(0.86))
                .frame(width: 34, height: 32)
                .background(Color(hex: 0x0B1020).opacity(0.54), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(NodusPalette.accent.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(NodeButtonStyle(intensity: .subtle))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NodusWheelPicker: View {
    let title: LocalizedStringKey
    let values: [Int]
    @Binding var selection: Int
    var label: (Int) -> String = { String(format: "%02d", $0) }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(label(value))
                        .font(.system(size: 21, weight: .regular, design: .default))
                        .monospacedDigit()
                        .foregroundStyle(NodusPalette.primary.opacity(0.9))
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 112)
            .clipped()
            .tint(NodusPalette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: 0x0B1020).opacity(0.42), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NodusPalette.primary.opacity(0.05), lineWidth: 1)
        }
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? startOfDay(for: date)
    }
}

struct NodusInlineValidation: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(NodusPalette.secondary.opacity(0.72))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NodusInfoRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            Spacer(minLength: 16)

            Text(value)
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(NodusPalette.primary.opacity(0.86))
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

struct NodusToggleRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var hapticsEnabled: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(NodusPalette.primary.opacity(0.86))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(NodusPalette.secondary.opacity(0.68))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button {
                #if os(iOS)
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                #endif
                withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule(style: .continuous)
                        .fill(isOn ? NodusPalette.accent.opacity(0.22) : Color(hex: 0x0B1020).opacity(0.7))
                        .frame(width: 48, height: 28)

                    Circle()
                        .fill(isOn ? Color(hex: 0xF5D7A8) : NodusPalette.secondary.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .padding(.horizontal, 3)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(isOn ? NodusPalette.accent.opacity(0.28) : NodusPalette.primary.opacity(0.05), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(subtitle ?? "")
            .accessibilityValue(Text(isOn ? "On" : "Off"))
        }
    }
}

struct NodusActionButton: View {
    enum Tone {
        case primary
        case secondary
        case destructive
    }

    let title: LocalizedStringKey
    let systemName: String?
    var tone: Tone = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 14, weight: .medium))
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(background, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            }
        }
        .buttonStyle(NodeButtonStyle())
    }

    private var foreground: Color {
        switch tone {
        case .primary:
            Color(hex: 0xF5D7A8)
        case .secondary:
            NodusPalette.secondary.opacity(0.9)
        case .destructive:
            Color(hex: 0xD8A48F).opacity(0.92)
        }
    }

    private var background: Color {
        switch tone {
        case .primary:
            NodusPalette.accent.opacity(0.16)
        case .secondary:
            Color(hex: 0x0B1020).opacity(0.58)
        case .destructive:
            Color(hex: 0x2A1414).opacity(0.46)
        }
    }

    private var stroke: Color {
        switch tone {
        case .primary:
            NodusPalette.accent.opacity(0.34)
        case .secondary:
            NodusPalette.primary.opacity(0.06)
        case .destructive:
            Color(hex: 0xD8A48F).opacity(0.18)
        }
    }
}

struct NodusLinkRow: View {
    let title: LocalizedStringKey
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .medium, design: .default))
                    .foregroundStyle(NodusPalette.primary.opacity(0.86))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NodusPalette.accent.opacity(0.82))
            }
        }
    }
}

struct TodayThreadFreeView: View {
    var body: some View {
        Text("Today the thread is free.")
            .font(.system(size: 14, weight: .regular, design: .serif))
            .foregroundStyle(NodusPalette.secondary.opacity(0.76))
            .padding(.leading, 132)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
