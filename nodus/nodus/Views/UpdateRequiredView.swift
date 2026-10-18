import SwiftUI

/// Shown over everything when the installed version is below the server's
/// `min_supported_version`. There is no way past it except updating.
struct UpdateRequiredView: View {
    let language: AppLanguage
    let appStoreURL: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(spacing: 28) {
                NodusAnimatedLogo()
                    .frame(width: 120, height: 120)
                    .opacity(0.5)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(language.localizedString("Update Nodus"))
                        .font(.cormorant(30, weight: .regular, italic: true))
                        .foregroundStyle(NodusPalette.primary.opacity(0.96))
                        .accessibilityAddTraits(.isHeader)

                    Text(language.localizedString("This version is no longer supported. Update the app to keep your thread in sync."))
                        .font(.cormorant(17, weight: .regular))
                        .lineSpacing(5)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(NodusPalette.secondary.opacity(0.84))
                }

                if let appStoreURL {
                    NodusActionButton(
                        title: LocalizedStringKey(language.localizedString("Update")),
                        systemName: "arrow.down.circle",
                        tone: .primary
                    ) {
                        openURL(appStoreURL)
                    }
                    .frame(maxWidth: 280)
                }
            }
            .padding(.horizontal, 36)
        }
    }
}
