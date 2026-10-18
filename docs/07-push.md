# Push и маршрутизация

Требования — §8, §12 `03_Nodus_iOS_Requirements.md`, контракт — `nodus_backend/docs/ios/05-push-and-deeplinks.md`.

## Принцип

APNs — только внешние события (совместные узлы, связи, готовые черновики, импорт) и только сигнал «сходи в sync». Обычные напоминания — локальные уведомления. Всё, о чём сообщает push, видно и без него.

## Регистрация

- Разрешение на уведомления спрашивается в контексте (первое напоминание). После разрешения и при каждом возврате в foreground — `registerForRemoteNotifications()`; отказ ничего не блокирует.
- Токен (`didRegisterForRemoteNotificationsWithDeviceToken`, hex) → `AccountService.apnsToken` → `POST /devices` с `apns_environment` из provisioning-профиля (`APNsEnvironment`).
- `aps-environment` в `nodus.entitlements` — `development`; при выгрузке в App Store Connect Xcode подставляет `production`.

## Обработка (`PushRouter`, `NotificationActionHandler`)

| Когда | Что |
|---|---|
| приложение открыто (`willPresent`) | системный баннер не показывается; sync и фирменный toast с заголовком push. `ai_drafts_ready` — без toast: о готовых черновиках говорит сам поток черновиков после sync |
| нажатие | sync, затем экран: `ai_drafts_ready` → проверка черновиков (тот же экран, что из foreground), `shared_node_changed` → карточка узла, если он ещё есть, `connection_changed` → экран связей, `import_ready` → экран проверки импорта; неизвестный тип — sync |
| холодный запуск по нажатию | нажатие ставится в очередь и выполняется, когда экран готов |

Повтор одного события не показывается: `event_id` показанных событий хранится 7 дней (`PushEventLog`).

## Тесты

`nodusTests/PushRouterTests.swift`: разбор payload, неизвестный тип, однократный toast, черновики после sync, забывание через неделю. Проверено в симуляторе через `xcrun simctl push`.
