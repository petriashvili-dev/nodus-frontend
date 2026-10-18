import SwiftUI

struct EmptyDayContent: View {
    let action: () -> Void
    /// `nil` hides the voice button (no AI drafts for this user).
    let voiceAction: (() -> Void)?
    let isRecording: Bool
    let language: AppLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var localizer: NodusLocalizer
    @State private var isBreathing = false

    var body: some View {
        VStack(spacing: 26) {
            NodusAnimatedLogo()
                .frame(width: 177, height: 177)
                .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.02 : 0.98))
                .opacity(0.42)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                        isBreathing = true
                    }
                }

            HStack(spacing: 16) {
                NewNodeButton(title: localizer.string("Tie the first knot"), systemName: "plus", height: 52, action: action)
                if let voiceAction {
                    VoiceCaptureButton(isRecording: isRecording, language: language, size: 52, action: voiceAction)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
    }
}
