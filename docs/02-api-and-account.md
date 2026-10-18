# API-клиент, авторизация и аккаунт

Контракт — `nodus_backend/docs/ios/01-auth-and-account.md`, `02-outbox-and-errors.md` (коды ошибок), `09-api-reference.md`.

## Адрес сервера

`NodusAPIBaseURL` в `nodus/nodus-Info.plist` берётся из build setting `NODUS_API_BASE_URL` таргета `nodus`:

| Конфигурация | Значение |
|---|---|
| Debug | `http://localhost:5258/v1` — локальный backend (`docs/09-operations.md` backend) |
| Release | `https://api.nodus.app/v1` — **заглушка**, заменить на реальный домен (`NODUS_DOMAIN`) |

`NSAllowsLocalNetworking` разрешает HTTP только к локальным адресам. В том же plist — схема `nodus://` (раньше задавалась ключом `INFOPLIST_KEY_CFBundleURLTypes`, который автогенерация Info.plist не поддерживает, и deep links не работали).

## Слои

| Файл | Роль |
|---|---|
| `Data/API/APIClient.swift` | actor: собирает запрос, ставит `Authorization`, `Idempotency-Key`, `X-Request-Id`, разбирает ответ и problem details. После `401` — один refresh (single-flight) и один повтор **с тем же** ключом. Других повторов не делает: это решение Outbox |
| `Data/API/APIError.swift` | `transport` (нет ответа), `server(status, problem, body, requestId)`, `invalidResponse`, `sessionEnded`; `isRetryableWithSameKey` — по таблице из `02-outbox-and-errors.md` (сеть, 5xx, `429 rate_limited`) |
| `Data/API/APICoding.swift` | `snake_case`, моменты ISO 8601 (с долями секунды и без); даты и локальное время в DTO — строки |
| `Data/API/HTTPTransport.swift` | единственная точка выхода в сеть (`URLSession`); в тестах подменяется |
| `Data/Auth/AuthSession.swift` | actor: токены, анонимный вход, refresh |
| `Data/Auth/TokenStore.swift` | Keychain (`app.nodus.auth`): сессия (`AuthTokens` + `isAnonymous`) и `installation_id`; доступ `AfterFirstUnlockThisDeviceOnly` |
| `Data/Account/AccountService.swift` | регистрация устройства, профиль → `AIAccessStore` |
| `App/AppServices.swift` | создаёт и связывает сервисы один раз при запуске |

## Токены

- **Первый доступ к сети** (не первый запуск): `POST /auth/anonymous`. Параллельные первые запросы ждут один вход.
- **Refresh — строго один одновременно.** Все, кому нужен refresh, ждут текущий; если пара уже обновлена другим запросом, повторного refresh нет. Новая пара записывается в Keychain **до** использования. Заранее — за 60 с до `access_token_expires_at`.
- Сетевая ошибка при refresh: старая пара остаётся (сервер примет её повторно в течение 2 минут).
- `401 invalid_refresh_token`:
  - анонимный аккаунт — создаётся новый анонимный, событие `AuthSession.Loss.anonymousAccountReplaced`;
  - аккаунт с email — сессия очищается, `APIError.sessionEnded` и событие `.sessionEnded` (экран «Сессия завершена» и восстановление — шаг «Аккаунт»).

В логах нет токенов и тел запросов; для поддержки пишется метод, путь, статус, `code` и `X-Request-Id`.

## Запуск и foreground

`ContentView` при каждом переходе в `active` запускает `AccountService.refresh()` в фоне (UI не ждёт):

1. гарантировать аккаунт;
2. `POST /devices { installation_id, apns_token?, apns_environment?, app_version }` — только если изменился аккаунт, токен APNs или версия;
3. `GET /me` → `AIAccessStore.apply` (доступ к AI, `docs/01-ai-access.md`) и признак анонимности в сессию.

Без сети ошибка молча проглатывается: приложение работает локально с последним известным профилем.

`apns_environment` определяется по встроенному provisioning-профилю (`APNsEnvironment`), не по `#if DEBUG`.

## Тесты

`nodusTests/AuthSessionTests.swift`, `nodusTests/APIClientTests.swift`: один анонимный вход и один refresh на параллельные запросы, refresh за минуту до истечения, потеря анонимной и email-сессии, сохранение старой пары при сетевой ошибке, повтор после `401` с тем же `Idempotency-Key`, разбор problem details, таблица повторяемости, `snake_case` и моменты. Сеть подменена `FakeTransport`, время — `TestClock`.
