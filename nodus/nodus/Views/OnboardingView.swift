import SwiftUI

/// First-launch welcome screen shown once, right after the splash —
/// sets the philosophical tone of the app before the user reaches the
/// timeline. Visually distinct from the rest of the app on purpose (its
/// own background tone and a serif display face) since it's a one-time
/// threshold, not a recurring surface.
struct OnboardingView: View {
    let continueAction: () -> Void

    @Environment(\.locale) private var locale
    @State private var knotGlow = false

    var body: some View {
        ZStack {
            OnboardingPalette.background.ignoresSafeArea()
            ambientGlow

            content
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                knotGlow = true
            }
        }
    }

    /// No hero art at all — just a couple of slow-drifting warm pools of
    /// light, the same mechanism (`BackgroundDrift`) the main timeline's
    /// `Backdrop` uses, so the page feels like a quieter version of the
    /// same living background rather than a flat, inert color.
    private var ambientGlow: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 3)) { context in
            let drift = BackgroundDrift(date: context.date)

            ZStack {
                RadialGradient(
                    colors: [OnboardingPalette.bronze.opacity(0.12), .clear],
                    center: drift.offset(UnitPoint(x: 0.5, y: 0.05), amplitude: 0.05, period: 2100, phase: 0),
                    startRadius: 20,
                    endRadius: 480
                )
                RadialGradient(
                    colors: [OnboardingPalette.bronze.opacity(0.06), .clear],
                    center: drift.offset(UnitPoint(x: 0.5, y: 1.0), amplitude: 0.05, period: 2700, phase: 0.4),
                    startRadius: 40,
                    endRadius: 420
                )
            }
            .animation(.linear(duration: 3), value: drift.tick)
        }
        .ignoresSafeArea()
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text("Welcome to")
                .font(.cormorant(18, weight: .regular))
                .foregroundStyle(OnboardingPalette.textWelcome)
                .padding(.bottom, 2)

            Text("NODUS")
                .font(.cormorant(52, weight: .light))
                .tracking(18)
                .foregroundStyle(OnboardingPalette.textPrimary)
                .padding(.bottom, 14)
                .padding(.leading, 18)

            knotSymbol
                .padding(.bottom, 26)

            divider
                .padding(.bottom, 20)

            tagline
                .padding(.bottom, 26)

            divider
                .padding(.bottom, 20)

            features

            Spacer(minLength: 12)

            ctaButton
                .padding(.bottom, 14)

            quote
        }
        .padding(.horizontal, 28)
        .padding(.top, 64)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var knotSymbol: some View {
        NodusKnotShape()
            .stroke(OnboardingPalette.bronze, lineWidth: 2)
            .frame(width: 56, height: 56)
            .opacity(knotGlow ? 1 : 0.5)
            .shadow(color: OnboardingPalette.bronze.opacity(knotGlow ? 0.8 : 0.55), radius: knotGlow ? 14 : 8)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            LinearGradient(colors: [.clear, OnboardingPalette.bronze.opacity(0.25)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            Circle()
                .fill(OnboardingPalette.bronze.opacity(0.5))
                .frame(width: 4, height: 4)
            LinearGradient(colors: [OnboardingPalette.bronze.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
    }

    private var tagline: some View {
        VStack(spacing: 10) {
            (
                Text("For centuries, people have tied knots") +
                Text("\n") +
                Text("so they would remember what matters.")
            )
            .font(.cormorant(19, weight: .light))
            .lineSpacing(11)
            .foregroundStyle(OnboardingPalette.textTagline)

            Text("Nodus continues this tradition, helping you hold on to what truly matters.")
                .font(.cormorant(18, weight: .light, italic: true))
                .lineSpacing(7)
                .foregroundStyle(OnboardingPalette.textTaglineDim)
        }
    }

    private var features: some View {
        HStack(alignment: .top, spacing: 6) {
            FeatureColumn(label: "Tie a\nknot", description: "Everything important begins with the first knot.") {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnboardingPalette.bronze)
            }

            FeatureColumn(label: "Untie a\nknot", description: "When something has been carried through.") {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.bronze)
            }

            FeatureColumn(label: "Lost\nknot", description: "A reminder that something was left behind.") {
                Circle()
                    .fill(OnboardingPalette.bronze.opacity(0.4))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var ctaButton: some View {
        NewNodeButton(
            title: AppLanguage(locale: locale).localizedString("Start weaving your thread"),
            systemName: "arrow.right",
            iconAlignment: .trailing,
            action: continueAction
        )
    }

    private var quote: some View {
        Text("The thread of time cannot be stopped. But you can choose which knots remain on it.")
            .font(.cormorant(17, weight: .light, italic: true))
            .lineSpacing(6)
            .foregroundStyle(OnboardingPalette.textQuote)
            .padding(.bottom, 8)
    }
}

/// A single gentle S-curve from edge to edge — the same "thread" idea as
/// `TimelineThread` on the main screen, just one short, simple wave
/// instead of a whole path of knots.
private struct WavyThread: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let amplitude = rect.height / 2
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.33, y: midY - amplitude),
            control2: CGPoint(x: rect.minX + rect.width * 0.66, y: midY + amplitude)
        )
        return path
    }
}

/// Same circle chrome as `IconCircleButton` (the settings button on the
/// main screen) — dark fill, bronze gradient border, soft drop shadow —
/// so the feature icons read as the same family of control.
private struct FeatureColumn<Icon: View>: View {
    let label: LocalizedStringKey
    let description: LocalizedStringKey
    let icon: Icon

    init(label: LocalizedStringKey, description: LocalizedStringKey, @ViewBuilder icon: () -> Icon) {
        self.label = label
        self.description = description
        self.icon = icon()
    }

    var body: some View {
        VStack(spacing: 9) {
            icon
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(Color(hex: 0x0B1020).opacity(0.58))
                        .overlay {
                            Circle().fill(OnboardingPalette.bronze.opacity(0.05))
                        }
                }
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: 0xF0C98B).opacity(0.44),
                                    OnboardingPalette.bronze.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                .shadow(color: OnboardingPalette.bronze.opacity(0.06), radius: 14)

            Text(label)
                .font(.cormorant(17, weight: .regular))
                .foregroundStyle(OnboardingPalette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(description)
                .font(.cormorant(15, weight: .light))
                .foregroundStyle(OnboardingPalette.textFeatureDescription)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Colors specific to the onboarding screen — intentionally a touch
/// different from `NodusPalette` (per design handoff, the onboarding
/// background tone is its own value, not the app's main background).
private enum OnboardingPalette {
    static let background = Color(hex: 0x0C0E1C)
    static let bronze = Color(hex: 0xC9A46A)
    static let textPrimary = Color(hex: 0xEAE5DC)
    static let textWelcome = Color(hex: 0xD2C3AA).opacity(0.75)
    static let textTagline = Color(hex: 0xDACDB6).opacity(0.78)
    static let textTaglineDim = Color(hex: 0xDACDB6).opacity(0.8)
    static let textQuote = Color(hex: 0xAF9E82).opacity(0.58)
    static let textFeatureDescription = Color(hex: 0xDACDB6).opacity(0.75)
}
