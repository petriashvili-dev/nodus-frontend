import SwiftUI

/// Nodus' own context screen shown before the system microphone and speech prompts.
struct VoicePermissionPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let language: AppLanguage
    let allow: () async -> Void

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 0) {
                NodusSheetDragIndicator()
                header
                NodusOrnamentDivider()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        NodusSheetSection(title: LocalizedStringKey(language.localizedString("Voice input"))) {
                            VStack(spacing: 22) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(NodusPalette.accent.opacity(0.86))
                                    .frame(width: 76, height: 76)
                                    .overlay { Circle().stroke(NodusPalette.accent.opacity(0.42), lineWidth: 1) }

                                VStack(spacing: 12) {
                                    Text(language.localizedString("Say what matters."))
                                        .font(.cormorant(28, weight: .regular, italic: true))
                                        .foregroundStyle(NodusPalette.primary.opacity(0.96))

                                    Text(language.localizedString("Nodus records only when you start a voice note. You can stop, review, and edit your words before saving."))
                                        .font(.cormorant(17, weight: .regular))
                                        .lineSpacing(5)
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(NodusPalette.secondary.opacity(0.84))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }

                        NodusSheetSection(title: LocalizedStringKey(language.localizedString("Microphone"))) {
                            NodusActionButton(title: LocalizedStringKey(language.localizedString("Continue")), systemName: "mic", tone: .primary) {
                                Task {
                                    await allow()
                                    dismiss()
                                }
                            }
                            NodusActionButton(title: "Not Now", systemName: "mic.slash") { dismiss() }
                        }
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

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "xmark", accessibilityLabel: "Close") { dismiss() }
            Spacer()
            Text(language.localizedString("Voice input"))
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
            Spacer()
            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
    }
}
