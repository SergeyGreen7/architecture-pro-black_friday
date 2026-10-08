# mongo-sharding

Запускать команды из директории `mongo-sharding`.

## Как запустить

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Инициализируем шардирование и заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```

Скрипт инициализирует `configSrv`, `shard1`, `shard2`, подключает шарды к `mongos_router`, шардирует коллекцию `somedb.helloDoc` и вставляет 1000 документов.

## Как проверить

### Если вы запускаете проект на локальной машине

Откройте в браузере http://localhost:8080

В ответе должны быть `mongo_topology_type: Sharded` и `collections.helloDoc.documents_count` ≥ 1000.

### Количество документов в каждом шарде

```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Сумма документов на `shard1` и `shard2` должна быть равна общему количеству (≥ 1000).

