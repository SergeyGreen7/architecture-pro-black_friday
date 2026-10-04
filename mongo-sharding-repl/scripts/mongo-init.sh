#!/bin/bash

###
# Инициализация шардирования MongoDB (шаги из README.md)
###

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

wait_for_mongosh() {
  local service="$1"
  local port="$2"
  local attempt

  for attempt in $(seq 1 30); do
    if docker compose exec -T "${service}" mongosh --port "${port}" --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Не удалось дождаться ${service}:${port}" >&2
  exit 1
}

echo "Ожидаем готовности mongod..."
wait_for_mongosh configSrv 27017
wait_for_mongosh shard1 27018
wait_for_mongosh shard2 27019

echo "1. Инициализация configSrv"
docker compose exec -T configSrv mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [
    { _id: 0, host: "configSrv:27017" }
  ]
})
EOF

echo "2. Инициализация shard1"
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1:27018" }
  ]
})
EOF

echo "3. Инициализация shard2"
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2:27019" }
  ]
})
EOF

echo "Ожидаем выбор primary в replica set..."
sleep 10

echo "Перезапускаем mongos_router"
docker compose restart mongos_router
wait_for_mongosh mongos_router 27020

echo "4. Добавление шардов, шардирование и тестовые данные"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1:27018")
sh.addShard("shard2/shard2:27019")
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insertOne({ age: i, name: "ly" + i })
db.helloDoc.countDocuments()
EOF

echo
echo "Проверка: всего документов через mongos"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "Проверка: документы в shard1"
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "Проверка: документы в shard2"
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
