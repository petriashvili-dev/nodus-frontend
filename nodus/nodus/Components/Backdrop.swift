import SwiftUI

/// The living backdrop of the main screen: a few soft, slowly drifting
/// pools of light whose direction, warmth and intensity track the time of
/// day. The palette never changes — only how that existing light falls.
struct Backdrop: View {
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 3)) { context in
            let light = AmbientLight(date: context.date)
            let drift = BackgroundDrift(date: context.date)

            ZStack {
                NodusPalette.background

                // Primary source: warm light whose vertical anchor and
                // strength follow the time-of-day curve below. Carries a
                // mid-stop so the glow reads clearly against the very dark
                // base instead of dissolving into it.
                RadialGradient(
                    colors: [
                        NodusPalette.accent.opacity(light.warmIntensity),
                        NodusPalette.accent.opacity(light.warmIntensity * 0.45),
                        .clear
                    ],
                    center: drift.offset(light.anchor, amplitude: 0.05, period: 1860, phase: 0),
                    startRadius: 10,
                    endRadius: light.primaryRadius
                )

                // Neutral fill light — strongest at midday for readability,
                // nearly absent at night so the thread itself reads as the
                // only light source.
                RadialGradient(
                    colors: [
                        NodusPalette.secondary.opacity(light.coolIntensity),
                        NodusPalette.secondary.opacity(light.coolIntensity * 0.4),
                        .clear
                    ],
                    center: drift.offset(.bottomLeading, amplitude: 0.06, period: 2460, phase: 0.31),
                    startRadius: 20,
                    endRadius: 460
                )

                // A second, smaller warm pool offset from the primary one —
                // gives the space depth instead of a single flat glow.
                RadialGradient(
                    colors: [NodusPalette.accent.opacity(light.accentIntensity), .clear],
                    center: drift.offset(UnitPoint(x: 0.78, y: 0.62), amplitude: 0.045, period: 3120, phase: 0.62),
                    startRadius: 30,
                    endRadius: 360
                )

                // Shadows deepen toward evening and night without touching
                // the base color.
                RadialGradient(
                    colors: [.clear, Color.black.opacity(light.vignette)],
                    center: .center,
                    startRadius: 200,
                    endRadius: 520
                )

                // Night doesn't just dim the light pools at the edges —
                // it darkens the whole screen, center included, so the
                // thread reads as the only thing still lit.
                Color.black.opacity(light.nightDarken)

                // A handful of fixed, barely-twinkling points — only late
                // in the evening and through the night, when the ambient
                // light has receded enough for them to make sense.
                StarField(date: context.date, visibility: light.starVisibility)
            }
            .animation(.linear(duration: 3), value: drift.tick)
        }
        .ignoresSafeArea()
    }
}

/// Direction, warmth and intensity of the ambient light, derived purely
/// from the time of day. Every color drawn from this comes straight out of
/// `NodusPalette` — only the mix and placement shift across morning, day,
/// evening and night, each blended smoothly into the next so there is no
/// visible cut between them.
private struct AmbientLight {
    let anchor: UnitPoint
    let warmIntensity: Double
    let coolIntensity: Double
    let accentIntensity: Double
    let primaryRadius: CGFloat
    let vignette: Double
    let nightDarken: Double
    let starVisibility: Double

    init(date: Date) {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date))
        let minute = Double(calendar.component(.minute, from: date))
        let t = hour + minute / 60

        let morning = Self.bell(t, center: 8, width: 2.6)
        let day = Self.bell(t, center: 14, width: 4.0)
        let evening = Self.bell(t, center: 19.5, width: 2.2)
        let night = max(0, 1 - morning - day - evening)

        // Morning light sits high and soft; day light sits a touch lower
        // and broader for even coverage; evening sinks further down,
        // giving the lower part of the screen deeper shadow; night settles
        // near the middle, close to the thread it's meant to cede focus to.
        anchor = UnitPoint(
            x: 0.5,
            y: 0.12 * morning + 0.26 * day + 0.52 * evening + 0.38 * night
        )

        // Tuned against the near-black `NodusPalette.background` (0x0B1020)
        // so each period is clearly distinguishable at a glance, not just
        // in theory — morning/evening run the warm light the strongest,
        // day leans on the neutral fill for readability. Night carries no
        // glow of its own at all (no `night` term here) — once the
        // greeting reads "Good night" the thread is the only light left.
        warmIntensity = 0.34 * morning + 0.16 * day + 0.40 * evening
        coolIntensity = 0.14 * morning + 0.30 * day + 0.10 * evening
        accentIntensity = 0.10 * morning + 0.07 * day + 0.16 * evening
        primaryRadius = 360 + 140 * day + 70 * morning
        vignette = 0.06 + 0.16 * evening + 0.30 * night
        // On top of the edge vignette above, deep night also flattens
        // the whole screen darker — not just its corners.
        nightDarken = 0.22 * night

        // Stars piggyback on the same evening/night weights driving the
        // light above, so they line up with the same "Good evening" →
        // "Good night" transition the greeting uses: a few show late in
        // the evening, more once it's properly night.
        starVisibility = min(1, 0.4 * evening + night)
    }

    /// A smooth bell curve over the 24h clock (wrapping at midnight) used
    /// to blend each period into its neighbors instead of switching at a
    /// hard boundary.
    private static func bell(_ t: Double, center: Double, width: Double) -> Double {
        let delta = min(abs(t - center), 24 - abs(t - center))
        return exp(-(delta * delta) / (2 * width * width))
    }
}

/// A slow, near-imperceptible wander for each light pool so the background
/// never sits perfectly still. Each call site picks its own period/phase so
/// the pools drift independently rather than in lockstep. Shared with
/// `OnboardingView`, which borrows the same drift for its own, simpler glow.
struct BackgroundDrift {
    let tick: Double

    private let referenceTime: TimeInterval

    init(date: Date) {
        referenceTime = date.timeIntervalSinceReferenceDate
        tick = referenceTime
    }

    /// `amplitude` is a fraction of the view's size; `period` is the full
    /// loop duration in seconds (tuned to the 20–60 minute range so the
    /// motion stays below conscious perception).
    func offset(_ base: UnitPoint, amplitude: CGFloat, period: Double, phase: Double) -> UnitPoint {
        let angle = (referenceTime / period + phase) * 2 * .pi
        let dx = CGFloat(cos(angle)) * amplitude
        let dy = CGFloat(sin(angle * 0.82)) * amplitude
        return UnitPoint(x: base.x + dx, y: base.y + dy)
    }
}

/// A small, fixed set of points standing in for stars — present only late
/// in the evening and through the night (`visibility`), each holding its
/// own slow, independent twinkle so the field never flickers as a whole.
private struct StarField: View {
    let date: Date
    let visibility: Double

    private struct Star {
        let position: UnitPoint
        let size: CGFloat
        let baseOpacity: Double
        let period: Double
        let phase: Double
    }

    private static let stars: [Star] = [
        Star(position: UnitPoint(x: 0.14, y: 0.09), size: 1.6, baseOpacity: 0.55, period: 47, phase: 0.0),
        Star(position: UnitPoint(x: 0.78, y: 0.06), size: 1.2, baseOpacity: 0.40, period: 63, phase: 0.8),
        Star(position: UnitPoint(x: 0.36, y: 0.14), size: 1.4, baseOpacity: 0.48, period: 55, phase: 0.4),
        Star(position: UnitPoint(x: 0.92, y: 0.20), size: 1.2, baseOpacity: 0.38, period: 71, phase: 0.2),
        Star(position: UnitPoint(x: 0.60, y: 0.10), size: 1.8, baseOpacity: 0.60, period: 39, phase: 0.6),
        Star(position: UnitPoint(x: 0.22, y: 0.24), size: 1.2, baseOpacity: 0.36, period: 67, phase: 0.9)
    ]

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate

        GeometryReader { geo in
            ZStack {
                ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                    let twinkle = 0.5 - 0.5 * cos((t / star.period + star.phase) * 2 * .pi)
                    Circle()
                        .fill(NodusPalette.primary.opacity(visibility * star.baseOpacity * (0.6 + 0.4 * twinkle)))
                        .frame(width: star.size, height: star.size)
                        .position(x: geo.size.width * star.position.x, y: geo.size.height * star.position.y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct StaticBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x05070D),
                    Color(hex: 0x08111F),
                    Color(hex: 0x05070D)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(hex: 0x162741).opacity(0.34),
                    Color(hex: 0x0B1424).opacity(0.08),
                    .clear
                ],
                center: UnitPoint(x: 0.50, y: 0.35),
                startRadius: 12,
                endRadius: 520
            )

            RadialGradient(
                colors: [
                    Color(hex: 0x3C2B1F).opacity(0.12),
                    .clear
                ],
                center: UnitPoint(x: 0.48, y: 0.56),
                startRadius: 20,
                endRadius: 300
            )
        }
        .ignoresSafeArea()
    }
}

