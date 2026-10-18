import SwiftUI

/// The session of an email account ended (revoked or expired). The knots on
/// the device stay; signing in again restores the account.
struct SessionEndedView: View {
    @Environment(\.dismiss) private var dismiss
    let language: AppLanguage
    let account: AccountService
    @State private var isSigningIn = false

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 24) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(NodusPalette.accent.opacity(0.86))
                    .frame(width: 76, height: 76)
                    .overlay { Circle().stroke(NodusPalette.accent.opacity(0.42), lineWidth: 1) }
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(language.localizedString("The session has ended"))
                        .font(.cormorant(28, weight: .regular, italic: true))
                        .foregroundStyle(NodusPalette.primary.opacity(0.96))
                        .accessibilityAddTraits(.isHeader)
                    Text(language.localizedString("Sign in with your email to keep the thread in sync."))
                        .font(.cormorant(17, weight: .regular))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(NodusPalette.secondary.opacity(0.84))
                }

                VStack(spacing: 10) {
                    NodusActionButton(title: LocalizedStringKey(language.localizedString("Sign in")), systemName: "envelope", tone: .primary) {
                        isSigningIn = true
                    }
                    NodusActionButton(title: LocalizedStringKey(language.localizedString("Later")), systemName: nil) {
                        dismiss()
                    }
                }
                .frame(maxWidth: 300)
            }
            .padding(.horizontal, 32)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(NodusPalette.background)
        .sheet(isPresented: $isSigningIn) {
            EmailCodeSheet(mode: .recover, language: language, account: account) {
                dismiss()
            }
        }
    }
}
