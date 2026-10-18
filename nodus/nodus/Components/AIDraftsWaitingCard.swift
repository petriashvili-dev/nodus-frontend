import SwiftUI

/// Takes the composer's place while a voice note is being untangled. Only
/// after the server accepted the job does it say the screen can be closed.
struct AIDraftsWaitingCard: View {
    let language: AppLanguage
    /// `false` while the request is still on its way.
    let isAccepted: Bool
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(NodusPalette.accent.opacity(0.9))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .frame(height: 40)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(language.localizedString("Untangling thoughts…"))
                    .font(.cormorant(28, weight: .regular, italic: true))
                    .foregroundStyle(NodusPalette.primary.opacity(0.96))

                if isAccepted {
                    Text(language.localizedString("You can close this screen — we will let you know when it is ready."))
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(NodusPalette.secondary.opacity(0.82))
                        .transition(.opacity)
                }
            }

            if isAccepted {
                NodusActionButton(title: LocalizedStringKey(language.localizedString("Close")), systemName: nil, action: close)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(NodusPalette.surface.opacity(0.99), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(NodusPalette.accent.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
        .animation(.easeOut(duration: 0.4), value: isAccepted)
        .accessibilityElement(children: .combine)
    }
}
