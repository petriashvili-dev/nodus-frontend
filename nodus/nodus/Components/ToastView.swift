import SwiftUI

/// A brief confirmation shown at the top of the thread. Its visual rhythm is
/// deliberately close to an iOS notification banner, so confirmation does
/// not interrupt the task the user was already looking at.
struct ToastPresentation: Identifiable {
    let id = UUID()
    let text: String
    var onUndo: (() -> Void)?

    init(text: String, onUndo: (() -> Void)? = nil) {
        self.text = text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.onUndo = onUndo
    }
}

struct ToastView: View {
    let toast: ToastPresentation
    /// How long the undo ring takes to fill — must match how long the
    /// caller actually waits before finalizing the action it's undoing.
    let undoDuration: Double

    @Environment(\.locale) private var locale
    @State private var undoProgress: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.onUndo == nil ? "checkmark" : "trash")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NodusPalette.accent)
                .frame(width: 30, height: 30)
                .background(NodusPalette.accent.opacity(0.13), in: Circle())

            Text(toast.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(NodusPalette.primary.opacity(0.96))
                .lineLimit(2)

            Spacer(minLength: 4)

            if let onUndo = toast.onUndo {
                Button(action: onUndo) {
                    Text(AppLanguage(locale: locale).localizedString("Undo"))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(NodusPalette.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(NodusPalette.accent.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(NodeButtonStyle(intensity: .subtle))
                .accessibilityLabel(AppLanguage(locale: locale).localizedString("Undo"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(NodusPalette.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NodusPalette.primary.opacity(0.1), lineWidth: 1)
        }
        .overlay(alignment: .bottomLeading) {
            if toast.onUndo != nil {
                Capsule(style: .continuous)
                    .fill(NodusPalette.accent.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 2)
                    .scaleEffect(x: undoProgress, anchor: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 5)
            }
        }
        .shadow(color: .black.opacity(0.26), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard toast.onUndo != nil else { return }
            withAnimation(.linear(duration: undoDuration)) {
                undoProgress = 1
            }
        }
    }
}
