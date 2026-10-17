import SwiftUI

/// Reports the rendered width of the smart phrase up to `HomeTimelineView`
/// so the divider beneath it can size itself to match instead of always
/// spanning the full row.
struct PhraseWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SmartPhraseText: View {
    let phrase: String
    let animation: SmartPhraseAnimation
    let event: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedPhrase = ""
    @State private var opacity = 1.0
    @State private var yOffset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        Text(visiblePhrase)
            .font(.cormorant(16, weight: .light, italic: true))
            .foregroundStyle(NodusPalette.secondary.opacity(0.86))
            .opacity(opacity)
            .offset(y: yOffset)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PhraseWidthKey.self, value: proxy.size.width)
                }
            }
            .onAppear {
                runAnimation()
            }
            // `event` alone drives this — it's bumped exactly once per
            // real change in HomeTimelineViewModel. Also watching `phrase`
            // here used to fire a second, redundant `runAnimation()` for
            // the same change (both properties change together), racing
            // two unstructured Tasks against the same `displayedPhrase`
            // state and occasionally leaving it stuck a few characters in
            // or with opacity stranded at 0.
            .onChange(of: event) { _, _ in
                runAnimation()
            }
            .onDisappear {
                animationTask?.cancel()
            }
            .accessibilityLabel(phrase)
    }

    private var visiblePhrase: String {
        displayedPhrase.isEmpty ? phrase : displayedPhrase
    }

    private func runAnimation() {
        animationTask?.cancel()

        if reduceMotion || animation == .none {
            displayedPhrase = phrase
            opacity = 1
            yOffset = 0
            return
        }

        switch animation {
        case .none:
            displayedPhrase = phrase
            opacity = 1
            yOffset = 0
        case .appear:
            displayedPhrase = phrase
            opacity = 0
            yOffset = 5
            withAnimation(.easeOut(duration: 0.3)) {
                opacity = 1
                yOffset = 0
            }
        case .crossfade:
            animationTask = Task {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.17)) {
                        opacity = 0
                        yOffset = -3
                    }
                }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else {
                    // A cancelled crossfade must not leave the text
                    // stranded at opacity 0 — the next real update will
                    // still show the right phrase, but invisible text in
                    // between looks like the row failed to render.
                    await MainActor.run {
                        displayedPhrase = phrase
                        opacity = 1
                        yOffset = 0
                    }
                    return
                }
                await MainActor.run {
                    displayedPhrase = phrase
                    yOffset = 3
                    withAnimation(.easeOut(duration: 0.24)) {
                        opacity = 1
                        yOffset = 0
                    }
                }
            }
        case .typewriter:
            animationTask = Task {
                guard !Task.isCancelled else { return }
                let characters = Array(phrase)
                await MainActor.run {
                    displayedPhrase = characters.first.map(String.init) ?? phrase
                    opacity = 1
                    yOffset = 0
                }

                let delay = typewriterDelay(characterCount: characters.count)
                for index in characters.indices.dropFirst() {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(delay))
                    await MainActor.run {
                        displayedPhrase = String(characters[...index])
                    }
                }

                await MainActor.run {
                    displayedPhrase = phrase
                }
            }
        }
    }

    private func typewriterDelay(characterCount: Int) -> Int {
        guard characterCount > 0 else { return 30 }
        return min(35, max(25, 1_350 / characterCount))
    }
}
