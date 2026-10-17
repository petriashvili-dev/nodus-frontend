import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Shared coordinate space name tying together where `MomentRow` measures
/// a card's frame and where `KnotActionMenuOverlay` positions its lifted
/// copy — both must measure against the same ancestor, not `.global`
/// (the window), or safe-area/nav-bar insets shift the lifted card off
/// from the real one.
enum ThreadCoordinateSpace {
    static let name = "nodusThreadRoot"
}

struct MomentRow: View {
    let item: TimelineItem
    let visible: Bool
    let index: Int
    let axisX: CGFloat
    let lineX: CGFloat
    /// True while this row's card is lifted into the custom action menu
    /// overlay elsewhere on screen — the row hides its own copy so the
    /// card doesn't appear twice at once.
    var isCardHidden: Bool = false
    var hapticsEnabled: Bool = true
    let action: () -> Void
    /// Fired once the long press on the card itself is recognized, with
    /// the card's own frame (in global coordinates) so the caller can
    /// anchor a custom menu precisely over it — never over the time text
    /// or thread marker beside it.
    let onLongPress: (TimelineItem, CGRect) -> Void

    @State private var isPressingCard = false
    @State private var cardFrame: CGRect = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(item.displayTime)
                .font(.cormorant(item.isNow ? 31 : 23, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.35), value: item.displayTime)
                .foregroundStyle(timeColor)
                .frame(width: item.isNow ? 112 : 88, alignment: .trailing)
                .position(x: axisX - (item.isNow ? 70 : 62), y: 24)

            MomentMarker(item: item)
                .frame(width: 44, height: 44)
                .position(x: lineX, y: 24)

            if let title = item.title {
                EventCard(item: item, title: title)
                    .scaleEffect(isPressingCard ? 0.97 : 1)
                    .brightness(isPressingCard ? -0.02 : 0)
                    .opacity(isCardHidden ? 0 : 1)
                    .background(cardFrameReader)
                    .onLongPressGesture(
                        minimumDuration: 0.38,
                        maximumDistance: 24,
                        pressing: { pressing in
                            withAnimation(.easeOut(duration: pressing ? 0.16 : 0.22)) {
                                isPressingCard = pressing
                            }
                        },
                        perform: {
                            #if os(iOS)
                            if hapticsEnabled {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            #endif
                            onLongPress(item, cardFrame)
                        }
                    )
                    .padding(.leading, axisX + 40)
                    .padding(.trailing, 22)
            } else {
                QuietMoment(text: item.kind)
                    .padding(.leading, axisX + 28)
                    .padding(.trailing, 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !item.isNow else { return }
            action()
        }
        .frame(height: item.title == nil ? 44 : 126)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 18)
        .animation(.spring(response: 1.15, dampingFraction: 0.9).delay(Double(index) * 0.08), value: visible)
        .accessibilityLabel(accessibilityLabel)
    }

    private var cardFrameReader: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(key: CardFramePreferenceKey.self, value: geometry.frame(in: .named(ThreadCoordinateSpace.name)))
        }
        .onPreferenceChange(CardFramePreferenceKey.self) { cardFrame = $0 }
    }

    private var timeColor: Color {
        if item.isNow {
            return NodusPalette.primary.opacity(0.9)
        }

        if item.isLost {
            return Color(hex: 0xA78368).opacity(0.66)
        }

        if item.isCompleted {
            return NodusPalette.secondary.opacity(0.46)
        }

        return NodusPalette.secondary.opacity(0.74)
    }

    private var accessibilityLabel: String {
        [item.title, item.displayTime, item.kind].compactMap { $0 }.joined(separator: ", ")
    }
}

struct MomentMarker: View {
    let item: TimelineItem

    var body: some View {
        if item.isNow {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.9) / 2.9
                let breath = 0.5 - cos(cycle * .pi * 2) * 0.5

                ZStack {
                    Circle()
                        .stroke(item.tint.opacity(0.22 * (1 - breath)), lineWidth: 1)
                        .frame(width: 18 + breath * 14, height: 18 + breath * 14)
                        .blur(radius: 0.7 + breath * 1.0)

                    Circle()
                        .fill(item.tint.opacity(0.22 + breath * 0.14))
                        .frame(width: 26 + breath * 4, height: 26 + breath * 4)
                        .blur(radius: 7 + breath * 2.2)

                    Circle()
                        .stroke(item.tint.opacity(0.76 + breath * 0.16), lineWidth: 1)
                        .background(Circle().fill(NodusPalette.background))
                        .frame(width: 12.5, height: 12.5)

                    Circle()
                        .fill(Color(hex: 0xF7D9A5).opacity(0.52 + breath * 0.18))
                        .frame(width: 4.8, height: 4.8)
                }
            }
        } else if item.isLost {
            EmptyView()
        } else if item.isCompleted {
            EmptyView()
        } else if item.isQuiet {
            ZStack {
                Circle()
                    .stroke(item.tint.opacity(0.14), lineWidth: 1)
                    .frame(width: 18, height: 18)
                    .blur(radius: 0.8)

                Circle()
                    .stroke(item.tint.opacity(0.46), lineWidth: 1)
                    .background(Circle().fill(NodusPalette.background))
                    .frame(width: 8, height: 8)

                Circle()
                    .fill(item.tint.opacity(0.28))
                    .frame(width: 3.2, height: 3.2)
            }
        } else {
            EmptyView()
        }
    }
}

/// A small glyph standing in for the knot's repeat rule, shown right
/// before its title — a plain dot for one-off knots, a repeat arrow for
/// ordinary recurrence, and a calendar for yearly occasions.
struct RepeatMarker: View {
    let schedule: RepeatSchedule

    var body: some View {
        if schedule.isYearly {
            Image(systemName: "gift")
                .font(.system(size: 11, weight: .semibold))
        } else if schedule.kind == .none {
            Circle()
                .frame(width: 5, height: 5)
        } else {
            Image(systemName: "repeat")
                .font(.system(size: 10, weight: .semibold))
        }
    }
}

struct EventCard: View {
    @Environment(\.locale) private var locale
    let item: TimelineItem
    let title: String

    private var markerOpacity: Double {
        item.isLost ? 0.56 : (item.isCompleted ? 0.4 : 0.84)
    }

    private var anniversaryText: String? {
        guard item.repeatSchedule.isYearly, let originDate = item.originDate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: originDate, to: item.scheduledAt).year ?? 0
        guard years >= 0 else { return nil }
        return "\(years) \(yearWord(for: years))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                RepeatMarker(schedule: item.repeatSchedule)
                    .foregroundStyle(item.tint.opacity(markerOpacity))

                Text(title)
                    .font(.cormorant(18, weight: .regular))
                    .foregroundStyle(NodusPalette.primary.opacity(item.isLost ? 0.62 : (item.isCompleted ? 0.58 : 0.9)))
                    .strikethrough(item.isCompleted, color: NodusPalette.primary.opacity(0.28))
                    .fixedSize(horizontal: false, vertical: true)

                if let anniversaryText {
                    Text("•")
                        .foregroundStyle(item.tint.opacity(markerOpacity))

                    Text(anniversaryText)
                        .font(.cormorant(16, weight: .regular))
                        .foregroundStyle(NodusPalette.secondary.opacity(item.isLost ? 0.52 : (item.isCompleted ? 0.48 : 0.76)))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let note = item.note {
                Text(note)
                    .font(.cormorant(14, weight: .light))
                    .lineSpacing(4)
                    .foregroundStyle(NodusPalette.secondary.opacity(item.isLost ? 0.52 : (item.isCompleted ? 0.48 : 0.82)))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The type itself is no longer spelled out here — the dot next
            // to the title already carries it via tint. This row only
            // speaks up when something needs explaining: the knot got lost,
            // or it was untied.
            if item.isLost {
                Text("lost knot")
                    .font(.cormorant(11, weight: .regular))
                    .tracking(0.6)
                    .foregroundStyle(item.tint.opacity(0.70))
                    .padding(.top, 2)
            } else if item.isCompleted {
                Text("untied knot")
                    .font(.cormorant(11, weight: .regular))
                    .tracking(0.6)
                    .foregroundStyle(item.tint.opacity(0.5))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A frosted glass look — the real blurred background shows
            // through a soft tint instead of a flat opaque fill, so the
            // card reads as part of the scene rather than a hard-edged
            // dark slab sitting on top of it.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: item.isLost ? 0x191A1D : 0x20232A).opacity(0.62),
                                    Color(hex: item.isLost ? 0x111216 : 0x171A20).opacity(0.62)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke((item.isLost ? item.tint : NodusPalette.primary).opacity(item.isLost ? 0.08 : 0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(item.isLost ? 0.12 : 0.18), radius: 20, y: 12)
    }

    private func yearWord(for count: Int) -> String {
        guard AppLanguage(locale: locale) == .ru else {
            return count == 1 ? "year" : "years"
        }

        let lastTwoDigits = count % 100
        guard !(11...14).contains(lastTwoDigits) else { return "лет" }

        switch count % 10 {
        case 1: return "год"
        case 2, 3, 4: return "года"
        default: return "лет"
        }
    }
}

struct QuietMoment: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.cormorant(17, weight: .light))
                .foregroundStyle(NodusPalette.secondary.opacity(0.72))

            Rectangle()
                .fill(LinearGradient(colors: [NodusPalette.accent.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .frame(maxWidth: 116)
        }
        .padding(.top, 11)
    }
}

struct NodeButtonStyle: ButtonStyle {
    enum Intensity {
        case regular
        case subtle
    }

    var intensity: Intensity = .regular

    func makeBody(configuration: Configuration) -> some View {
        let glowMultiplier = intensity == .subtle ? 0.32 : 1
        let brightness = intensity == .subtle ? 0.04 : 0.12
        let scale = intensity == .subtle ? 0.96 : 0.92

        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? brightness : 0)
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0xF7D9A5).opacity(configuration.isPressed ? 0.42 * glowMultiplier : 0),
                                NodusPalette.accent.opacity(configuration.isPressed ? 0.30 * glowMultiplier : 0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.plusLighter)
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color(hex: 0xFFEACB).opacity(configuration.isPressed ? 0.95 * glowMultiplier : 0), lineWidth: 1.4)
            }
            .shadow(color: Color(hex: 0xF7D9A5).opacity(configuration.isPressed ? 0.7 * glowMultiplier : 0), radius: configuration.isPressed ? 18 * glowMultiplier : 0)
            .shadow(color: NodusPalette.accent.opacity(configuration.isPressed ? 0.5 * glowMultiplier : 0), radius: configuration.isPressed ? 30 * glowMultiplier : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// A custom stand-in for the system context menu, drawn in the app's own
/// palette and serif type instead of the OS blur/menu chrome — opened from
/// `MomentRow`'s long press on the card, anchored to that card's exact
/// frame so the rest of the row (time, thread marker) never lifts with it.
struct KnotActionMenuOverlay: View {
    let item: TimelineItem
    let anchor: CGRect
    let dismiss: () -> Void
    let untie: () -> Void
    let tie: () -> Void
    let retie: () -> Void
    let pause: () -> Void
    let delete: () -> Void

    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                NodusPalette.background.opacity(isVisible ? 0.74 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAnimated() }

                EventCard(item: item, title: item.title ?? "")
                    .frame(width: anchor.width, height: anchor.height)
                    .position(x: anchor.midX, y: anchor.midY)
                    .scaleEffect(isVisible ? 1.035 : 1)
                    .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
                    .allowsHitTesting(false)

                menuPanel(in: proxy.size)
                    .opacity(isVisible ? 1 : 0)
                    .scaleEffect(isVisible ? 1 : 0.94, anchor: opensBelow(in: proxy.size) ? .top : .bottom)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
    }

    private func dismissAnimated() {
        withAnimation(.easeOut(duration: 0.16)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            dismiss()
        }
    }

    private func perform(_ action: @escaping () -> Void) {
        action()
        dismissAnimated()
    }

    /// A completed knot can be restored; all active schedules can be untied.
    private var showsUntie: Bool {
        !item.isCompleted
    }

    private var rowCount: Int {
        3 + (item.repeatSchedule.isRepeating ? 1 : 0)
    }

    private var panelHeight: CGFloat {
        CGFloat(rowCount) * 48
    }

    private func opensBelow(in screenSize: CGSize) -> Bool {
        anchor.maxY + 12 + panelHeight <= screenSize.height - 24
    }

    private func menuPanel(in screenSize: CGSize) -> some View {
        let panelWidth: CGFloat = min(240, max(anchor.width, 200))
        let below = opensBelow(in: screenSize)
        let panelY = below ? anchor.maxY + 12 : anchor.minY - 12 - panelHeight
        let panelX = min(max(anchor.minX, 16), screenSize.width - panelWidth - 16)

        return VStack(spacing: 0) {
            if showsUntie {
                menuRow(title: "Untie", systemImage: "checkmark", tone: .primary) {
                    perform(untie)
                }
            } else {
                menuRow(title: "Tie", systemImage: "arrow.counterclockwise", tone: .primary) {
                    perform(tie)
                }
            }

            divider

            menuRow(title: "Retie", systemImage: "point.topleft.down.curvedto.point.bottomright.up", tone: .secondary) {
                perform(retie)
            }

            divider

            if item.repeatSchedule.isRepeating {
            menuRow(title: "Pause", systemImage: "pause.circle", tone: .secondary) {
                    perform(pause)
                }
                divider
            }

            menuRow(title: "Delete", systemImage: "trash", tone: .destructive) {
                perform(delete)
            }
        }
        .frame(width: panelWidth)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(hex: 0x20232A).opacity(0.62))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NodusPalette.primary.opacity(0.08), lineWidth: 1)
        }
        .position(x: panelX + panelWidth / 2, y: panelY + panelHeight / 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(NodusPalette.primary.opacity(0.06))
            .frame(height: 1)
    }

    private enum Tone {
        case primary
        case secondary
        case destructive
    }

    private func menuRow(title: LocalizedStringKey, systemImage: String, tone: Tone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)

                Text(title)
                    .font(.cormorant(17, weight: .regular))

                Spacer()
            }
            .foregroundStyle(color(for: tone))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(for tone: Tone) -> Color {
        switch tone {
        case .primary:
            NodusPalette.accent.opacity(0.92)
        case .secondary:
            NodusPalette.primary.opacity(0.9)
        case .destructive:
            Color(hex: 0xD8A48F).opacity(0.92)
        }
    }
}
