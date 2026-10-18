# Продолжение нити

Серверные предложения приходят с Delta Sync и snapshot. Локальная модель индексируется по `source_node_id`; предложение отображается только при развязывании одноразового узла, если оно уже было готово и ещё не показывалось. Показ и `POST /suggestions/{id}/shown` записываются вместе с untie в SwiftData.

## Действия

- «Завязать» открывает редактор с заголовком предложения. Подтверждение создаёт локальный узел и одну операцию `POST /suggestions/{id}/accept` с вложенным `CreateNode`.
- «Не сейчас» локально помечает предложение отклонённым и ставит `POST /suggestions/{id}/dismiss` в Outbox.
- Ответ accept обновляет предложение и локальный узел; узел до ответа остаётся оптимистичным.
- Событие удаления предложения удаляет его локальную копию.

## Файлы

- `nodus/nodus/Models/Suggestion.swift` — локальное состояние.
- `nodus/nodus/Data/AI/SuggestionDTO.swift` — DTO и тело составного accept.
- `nodus/nodus/Data/Sync/SyncEngine.swift` — snapshot, delta и ответы Outbox.
- `nodus/nodus/Services/ReminderService.swift` — атомарный показ, accept и dismiss.
- `nodus/nodus/Views/SuggestionPromptView.swift` — предложение и переход в редактор.
- `nodus/nodusTests/SyncEngineTests.swift` — проверка совместной записи untie и shown.

Импортные задания уже декодируются и сохраняются из snapshot/delta (`ImportJob`), но экран проверки импорта и сетевые команды экспорта/импорта описаны как незавершённая область в [аудите требований](08-requirements-audit.md).
