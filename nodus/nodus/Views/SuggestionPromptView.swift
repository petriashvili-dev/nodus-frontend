import SwiftUI

struct SuggestionPromptView: View {
    let suggestion: Suggestion
    let language: AppLanguage
    let quickPresetSettings: SettingsSnapshot
    let accept: (ReminderDraft) async -> Bool
    let dismissSuggestion: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    var body: some View {
        ZStack {
            NodusPalette.background.ignoresSafeArea()
            Backdrop()

            VStack(alignment: .leading, spacing: 22) {
                NodusSheetDragIndicator().frame(maxWidth: .infinity)
                Text(language.localizedString("Continue the thread"))
                    .font(.cormorant(32, weight: .light, italic: true))
                    .foregroundStyle(NodusPalette.primary)
                Text(suggestion.title)
                    .font(.cormorant(25, weight: .regular))
                    .foregroundStyle(NodusPalette.primary)
                if let detail = suggestion.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(NodusPalette.secondary)
                }
                NodusSheetFooterButton(title: "Tie the knot", isDisabled: false) {
                    isEditing = true
                }
                Button(language.localizedString("Not now"), action: dismissSuggestion)
                    .font(.system(size: 15))
                    .foregroundStyle(NodusPalette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(24)
        }
        .presentationDetents([.medium])
        .sheet(isPresented: $isEditing) {
            ReminderEditorView(
                title: "Continue the thread",
                confirmTitle: "Tie the knot",
                draft: ReminderDraft(title: suggestion.title),
                quickPresetSettings: quickPresetSettings
            ) { draft in
                if await accept(draft) {
                    dismiss()
                }
            }
        }
    }
}
