import SwiftUI

/// Opens the voice composer. Recording itself is deliberately controlled in
/// the composer, where the user always has an explicit stop action.
struct VoiceCaptureButton: View {
    let isRecording: Bool
    let language: AppLanguage
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: size > 46 ? 18 : 16, weight: .medium))
                .foregroundStyle(isRecording ? NodusPalette.background : NodusPalette.accent.opacity(0.92))
                .frame(width: size, height: size)
                .background {
                    if isRecording {
                        Capsule(style: .continuous)
                            .fill(NodusPalette.accent)
                    } else {
                        NodusTranslucentCapsuleBackground()
                    }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color(hex: 0xF7D9A5).opacity(isRecording ? 0.18 : 0.4), lineWidth: 2.5)
                        .blur(radius: 3.5)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: 0xF0C98B).opacity(0.55),
                                    NodusPalette.accent.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
                .shadow(color: NodusPalette.accent.opacity(isRecording ? 0.2 : 0.08), radius: 16)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NodeButtonStyle(intensity: .subtle))
        .accessibilityLabel(language.localizedString("Voice input"))
        .accessibilityHint(language.localizedString("Open voice recording"))
        .accessibilityValue(isRecording ? language.localizedString("Recording") : "")
        .animation(.easeInOut(duration: 0.18), value: isRecording)
    }
}
