import SwiftUI

struct NodusAnimatedLogo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            staticLogo
                .accessibilityHidden(true)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18.0) / 18.0
                let shimmerStart = cycle - 0.11
                let shimmerEnd = cycle + 0.13

                ZStack {
                    staticLogo

                    shimmerSegment(from: max(0, shimmerStart), to: min(1, shimmerEnd))

                    if shimmerStart < 0 {
                        shimmerSegment(from: 1 + shimmerStart, to: 1)
                    }

                    if shimmerEnd > 1 {
                        shimmerSegment(from: 0, to: shimmerEnd - 1)
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var staticLogo: some View {
        NodusKnotShape()
            .stroke(
                LinearGradient(
                    colors: [.clear, NodusPalette.accent.opacity(0.42), NodusPalette.accent.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                style: strokeStyle(lineWidth: 1.9)
            )
    }

    private func shimmerSegment(from start: Double, to end: Double) -> some View {
        NodusKnotShape()
            .trim(from: start, to: end)
            .stroke(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color(hex: 0xF1C98E).opacity(0.16), location: 0.22),
                        .init(color: Color(hex: 0xF1C98E).opacity(0.52), location: 0.5),
                        .init(color: Color(hex: 0xF1C98E).opacity(0.16), location: 0.78),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                style: strokeStyle(lineWidth: 1.65)
            )
            .blur(radius: 0.75)
    }

    private func strokeStyle(lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}
