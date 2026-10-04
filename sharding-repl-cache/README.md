# MongoDB sharding, replication and caching

Проект запускает приложение, Redis и шардированный кластер MongoDB. Каждый из двух шардов является replica set из трёх MongoDB-узлов.
Коллекция шардируется по хешированному ключу `name`.

## Требования

- Docker с плагином Docker Compose;
- Bash;
- свободный порт `8080`;
- не менее 4 ГБ памяти для Docker Desktop.

Все следующие команды выполняются из директории `sharding-repl-cache`.

## Запуск и инициализация

```bash
docker compose up -d --build
docker compose ps
bash ./scripts/mongo-init.sh
```

Скрипт:

1. Инициализирует config server replica set.
2. Создаёт по три участника в replica set `shard1` и `shard2`.
3. Ждёт состояние `1 PRIMARY + 2 SECONDARY` в каждом шарде.
4. Регистрирует оба shard replica set через `mongos`.
5. Включает шардирование `somedb.helloDoc` по ключу `{ name: "hashed" }`.
6. Загружает 1000 документов.
7. Проверяет состав replica set и распределение документов.
8. Проверяет Redis и очищает кеш перед тестированием.

Скрипт можно запускать повторно: конфигурация не дублируется, а коллекция снова
заполняется ровно 1000 документами.

## Проверка приложения

```bash
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

Корневой эндпоинт должен показать topology `Sharded`, оба шарда, полные строки
подключения к трём репликам каждого шарда и 1000 документов в `helloDoc`.
Swagger UI доступен по адресу `http://localhost:8080/docs`.

## Проверка кеширования

Убедитесь, что приложение подключилось к Redis:

```bash
curl http://localhost:8080/
docker compose exec -T redis redis-cli ping
```

В JSON приложения ожидается `"cache_enabled": true`, Redis должен вернуть
`PONG`.

Автоматическая проверка очищает Redis, выполняет один холодный и три
кешированных запроса:

```bash
bash ./scripts/check-cache.sh
```

Первый запрос к `/helloDoc/users` занимает больше времени. Каждый следующий
запрос должен завершиться намного быстрее.

## Остановка

```bash
docker compose down
```

Для полного сброса вместе с volumes выполните `docker compose down -v`.
