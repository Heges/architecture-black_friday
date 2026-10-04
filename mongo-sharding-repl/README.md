# MongoDB sharding with replication

Проект запускает приложение и шардированный кластер MongoDB.
Каждый из двух шардов является replica set из трёх MongoDB-узлов.

Все следующие команды выполняются из директории `mongo-sharding-repl`.
Коллекция шардируется по хешированному ключу `name`.

## Требования

- Docker с плагином Docker Compose;
- Bash для запуска скрипта инициализации;
- свободный локальный порт `8080`.

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

## Остановка

```bash
docker compose down
```

Для полного сброса вместе с volumes выполните `docker compose down -v`.