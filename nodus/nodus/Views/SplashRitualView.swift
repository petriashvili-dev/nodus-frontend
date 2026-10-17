import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit
import CoreHaptics
#endif

/// The infinity-knot symbol traced as a single stroke, matching the shape
/// used for the app icon and `NodusTimelineLogo` asset.
struct NodusKnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 60
        let sy = rect.height / 76
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx + rect.minX, y: y * sy + rect.minY)
        }

        var path = Path()
        path.move(to: p(30, 38))
        path.addCurve(to: p(52, 58), control1: p(43, 46), control2: p(52, 50))
        path.addCurve(to: p(30, 66), control1: p(52, 64), control2: p(38, 66))
        path.addCurve(to: p(8, 58), control1: p(22, 66), control2: p(8, 64))
        path.addCurve(to: p(30, 38), control1: p(8, 52), control2: p(17, 46))
        path.addCurve(to: p(52, 18), control1: p(43, 30), control2: p(52, 24))
        path.addCurve(to: p(30, 10), control1: p(52, 12), control2: p(38, 10))
        path.addCurve(to: p(8, 18), control1: p(22, 10), control2: p(8, 12))
        path.addCurve(to: p(30, 38), control1: p(8, 24), control2: p(17, 30))
        path.closeSubpath()

        return path
    }
}

struct SplashRitualView: View {
    var hapticsEnabled: Bool = true
    var soundEnabled: Bool = true

    @State private var progress: CGFloat = 0
    @State private var showName = false
    @State private var taglineVisible = false
    @State private var audioPlayer: AVAudioPlayer?
    #if os(iOS)
    @State private var hapticEngine: CHHapticEngine?
    #endif

    private let drawDuration: Double = 2.6

    var body: some View {
        ZStack {
            StaticBackdrop()

            VStack(spacing: 14) {
                ZStack {
                    NodusKnotShape()
                        .trim(from: 0, to: progress)
                        .stroke(NodusPalette.accent.opacity(0.3), lineWidth: 4)
                        .blur(radius: 6)

                    NodusKnotShape()
                        .trim(from: 0, to: progress)
                        .stroke(
                            NodusPalette.accent,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                }
                .frame(width: 120, height: 152)

                Text("Nodus")
                    .font(.cormorant(36, weight: .light))
                    .textCase(.uppercase)
                    .foregroundStyle(NodusPalette.primary)
                    .kerning(8)
                    .opacity(showName ? 1 : 0)

                VStack(spacing: 4) {
                    Text("Your plans")
                    Text("Tied to time")
                }
                .font(.cormorant(13, weight: .light))
                .tracking(1.6)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(hex: 0xD6C8B6).opacity(0.74))
                .opacity(taglineVisible ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: drawDuration)) {
                progress = 1
            }
            triggerDrawHaptics()
            playDrawSound()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                withAnimation(.easeIn(duration: 0.8)) {
                    showName = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
                withAnimation(.easeOut(duration: 0.7)) {
                    taglineVisible = true
                }
            }
        }
        .onDisappear {
            audioPlayer?.stop()
            audioPlayer = nil
            #if os(iOS)
            hapticEngine?.stop()
            hapticEngine = nil
            #endif
        }
    }

    /// Plays alongside the stroke animation, started at the same moment
    /// the trace begins so the sound and the symbol being drawn line up.
    private func playDrawSound() {
        guard soundEnabled, let url = Bundle.main.url(forResource: "splash", withExtension: "wav") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            // A missed sound on this one screen isn't worth surfacing.
        }
    }

    /// One unbroken, light haptic spanning the whole stroke animation
    /// above, so the knot is felt being drawn rather than just tapped at
    /// a few points along the way.
    private func triggerDrawHaptics() {
        guard hapticsEnabled else { return }
        #if os(iOS)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            let engine = try CHHapticEngine()
            engine.stoppedHandler = { _ in }
            engine.resetHandler = { }
            try engine.start()
            hapticEngine = engine

            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.32),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.22)
                ],
                relativeTime: 0,
                duration: drawDuration
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // A missed haptic on this one screen isn't worth surfacing.
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + drawDuration + 0.1) {
            hapticEngine?.stop()
            hapticEngine = nil
        }
        #endif
    }
}
