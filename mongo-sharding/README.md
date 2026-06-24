# MongoDB sharding

Проект запускает приложение и учебный шардированный кластер MongoDB из двух шардов.

## Требования

- Docker с плагином Docker Compose;
- Bash для запуска скрипта инициализации;
- свободный локальный порт `8080`.

В Windows используйте Git Bash. WSL подходит только после включения интеграции
для нужного дистрибутива в Docker Desktop. Все команды выполняются из
директории `mongo-sharding`.

## Запуск и инициализация

```bash
docker compose up -d --build
docker compose ps
bash ./scripts/mongo-init.sh
```

Скрипт выполняет следующие действия:

1. Инициализирует replica set `config_server`, `shard1` и `shard2`.
2. Регистрирует оба шарда через `mongos`.
3. Включает шардирование базы `somedb`.
4. Шардирует `somedb.helloDoc` по ключу `{ name: "hashed" }`.
5. Загружает 1000 документов.
6. Выводит общее количество документов и количество на каждом шарде.

Скрипт можно запускать повторно: существующие replica set и шарды повторно не
создаются, а коллекция снова заполняется ровно 1000 документами.

## Проверка MongoDB

Состояние шардированного кластера:

```bash
docker compose exec -T mongos mongosh --port 27020 --quiet --eval 'sh.status()'
```

Общее количество документов:

```bash
docker compose exec -T mongos mongosh --port 27020 --quiet --eval \
  'db.getSiblingDB("somedb").helloDoc.countDocuments({})'
```

Ожидаемый результат: `1000`.

Количество документов на каждом шарде:

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet --eval \
  'db.getSiblingDB("somedb").helloDoc.countDocuments({})'

docker compose exec -T shard2 mongosh --port 27019 --quiet --eval \
  'db.getSiblingDB("somedb").helloDoc.countDocuments({})'
```

На обоих шардах должно быть ненулевое количество документов. Сумма двух
значений должна быть равна `1000`; точное распределение может отличаться.


## Проверка приложения

```bash
curl http://localhost:8080/
curl http://localhost:8080/helloDoc/count
```

Swagger UI доступен по адресу `http://localhost:8080/docs`

## Остановка

```bash
docker compose down
```

Для полного сброса вместе с данными выполните `docker compose down -v`.
