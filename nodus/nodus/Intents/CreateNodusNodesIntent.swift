import AppIntents
import Foundation

/// Runs without opening the app so Siri can create knots from the Lock Screen.
/// The system performs speech-to-text; this intent only receives the text.
///
/// Turning text into knots is an AI feature (`ai_drafts`) and goes only
/// through the backend AI drafts flow; the drafts are reviewed in the app.
/// App Shortcuts cannot be hidden per user, so the shortcut stays installed
/// and answers neutrally when the feature is not available.
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
            return .result(dialog: "Эта функция сейчас недоступна.")
        }
        // The same flow as the voice composer: the drafts come back to the
        // review screen in the app; nothing is created from here.
        switch await Self.submit(text) {
        case .accepted:
            return .result(dialog: "Разбираю. Черновики будут ждать в Nodus.")
        case .savedOffline:
            return .result(dialog: "Нет связи. Запись сохранена в черновиках Nodus.")
        case .needsConsent:
            return .result(dialog: "Сначала разрешите AI-помощника в приложении Nodus.")
        case .unavailable:
            return .result(dialog: "Эта функция сейчас недоступна.")
        case .quotaExceeded:
            return .result(dialog: "Лимит AI на сегодня исчерпан.")
        case .failed:
            return .result(dialog: "Не получилось разобрать запись.")
        }
    }

    @MainActor
    private static func submit(_ text: String) async -> AIDraftsService.SubmitResult {
        await AppServices.shared.aiDrafts.service.submit(text)
    }
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
