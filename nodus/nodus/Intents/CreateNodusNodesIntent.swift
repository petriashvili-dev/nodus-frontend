import AppIntents
import Foundation

/// Runs without opening the app so Siri can create knots from the Lock Screen.
/// The system performs speech-to-text; this intent only receives the text.
///
/// Turning text into knots is an AI feature (`ai_drafts`) and goes only
/// through the backend AI drafts flow. App Shortcuts cannot be hidden per
/// user, so the shortcut stays installed and answers neutrally when the
/// feature is not available.
struct CreateNodusNodesIntent: AppIntent {
    static var title: LocalizedStringResource = "Завязать узлы Nodus"
    static var description = IntentDescription("Завязывает один или несколько узлов Nodus из продиктованного текста.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Текст", requestValueDialog: "Что нужно завязать в Nodus?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Завязать узлы из \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AIAccessStore.load().isAvailable(.drafts) else {
            return .result(dialog: Self.unavailableDialog)
        }
        // The backend AI drafts flow is not connected yet, so even with the
        // feature there is nowhere to send the text.
        return .result(dialog: Self.unavailableDialog)
    }

    private static let unavailableDialog: IntentDialog = "Эта функция сейчас недоступна."
}

struct NodusAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNodusNodesIntent(),
            phrases: [
                "Создай узел в \(.applicationName)",
                "Завяжи узел в \(.applicationName)",
                "Добавь узел в \(.applicationName)"
            ],
            shortTitle: "Завязать узел",
            systemImageName: "plus.circle"
        )
    }
}
