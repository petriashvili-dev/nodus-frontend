import SwiftUI

/// Asked once, at the first attempt to use an AI feature (App Review
/// Guideline 5.1.2(i)): what is sent, to whom and why. The answer lives on
/// the server (`ai_consent_at`) and follows the user to other devices.
struct AIConsentView: View {
    @Environment(\.dismiss) private var dismiss
    let language: AppLanguage
    let privacyPolicyURL: URL
    let allow: () async -> Void
    let decline: () -> Void

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
                        NodusSheetSection {
                            VStack(spacing: 20) {
                                Image(systemName: "wand.and.sparkles")
                                    .font(.system(size: 28, weight: .light))
                                    .foregroundStyle(NodusPalette.accent.opacity(0.86))
                                    .frame(width: 76, height: 76)
                                    .overlay { Circle().stroke(NodusPalette.accent.opacity(0.42), lineWidth: 1) }
                                    .accessibilityHidden(true)

                                Text(language.localizedString("Let AI untangle your thoughts?"))
                                    .font(.cormorant(26, weight: .regular, italic: true))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(NodusPalette.primary.opacity(0.96))
                                    .accessibilityAddTraits(.isHeader)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }

                        NodusSheetSection(title: LocalizedStringKey(language.localizedString("What is sent"))) {
                            explanation("The text of your voice notes and imported files, and the titles of knots you untie.")
                        }

                        NodusSheetSection(title: LocalizedStringKey(language.localizedString("To whom"))) {
                            explanation("Nodus servers pass it to an AI model provider. It is not used for advertising or sold.")
                        }

                        NodusSheetSection(title: LocalizedStringKey(language.localizedString("Why"))) {
                            explanation("To turn your words into draft knots and suggest what might come next. Nothing is created until you confirm it.")
                            NodusLinkRow(title: LocalizedStringKey(language.localizedString("Privacy policy")), destination: privacyPolicyURL)
                        }

                        VStack(spacing: 10) {
                            NodusActionButton(title: LocalizedStringKey(language.localizedString("Allow")), systemName: "checkmark", tone: .primary) {
                                Task {
                                    await allow()
                                    dismiss()
                                }
                            }
                            NodusActionButton(title: LocalizedStringKey(language.localizedString("Not Now")), systemName: nil) {
                                decline()
                                dismiss()
                            }
                        }
                        .padding(.top, 4)

                        Text(language.localizedString("You can change this any time in Settings → App → AI assistant."))
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(NodusPalette.secondary.opacity(0.64))
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

    private func explanation(_ key: String) -> some View {
        Text(language.localizedString(key))
            .font(.cormorant(17, weight: .regular))
            .lineSpacing(4)
            .foregroundStyle(NodusPalette.secondary.opacity(0.86))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack {
            IconCircleButton(systemName: "xmark", accessibilityLabel: "Close") {
                decline()
                dismiss()
            }
            Spacer()
            Text(language.localizedString("AI assistant"))
                .font(.cormorant(21, weight: .light, italic: true))
                .foregroundStyle(NodusPalette.primary.opacity(0.94))
            Spacer()
            Color.clear.frame(width: 46, height: 42)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
    }
}
