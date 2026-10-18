# Nodus iOS: как работает клиент

Документы на русском: как устроены экраны, потоки и состояния на клиенте. Контракт с сервером — `~/Desktop/nodus/nodus_backend/docs/ios/`, визуальный язык — [`../DESIGN_SYSTEM.md`](../DESIGN_SYSTEM.md).

| Файл | Содержание |
|---|---|
| [01-ai-access.md](01-ai-access.md) | доступ к AI-функциям по `user.features`, согласие, скрытие точек входа |
| [02-api-and-account.md](02-api-and-account.md) | адрес сервера, API-клиент, токены и refresh, Keychain, регистрация устройства, профиль |
| [03-outbox-and-sync.md](03-outbox-and-sync.md) | локальный кеш, Outbox, Delta Sync, лента из `/feed`, уведомления по окну экземпляров, смена пояса, виджет |
| [04-app-config.md](04-app-config.md) | ссылки, минимальная и последняя версия, лимиты из `GET /v1/app-config` |
| [05-ai-drafts.md](05-ai-drafts.md) | голосовые AI-черновики: согласие, отправка, ожидание, проверка, «Черновики», Siri |
| [06-account.md](06-account.md) | имя, сохранение и восстановление по email, «Сессия завершена», выход, удаление аккаунта |
| [07-push.md](07-push.md) | APNs: регистрация, foreground-toast вместо баннера, маршрутизация нажатий, дедупликация |
