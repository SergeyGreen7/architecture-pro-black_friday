#!/bin/bash

###
# Инициализация шардирования и репликации MongoDB (шаги из README.md)
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

wait_for_rs_ready() {
  local service="$1"
  local port="$2"
  local expected_members="$3"
  local attempt
  local eval_js

  eval_js="const s = rs.status(); const healthy = s.members.filter(m => m.health === 1).length; const primary = s.members.some(m => m.stateStr === 'PRIMARY'); (healthy === ${expected_members} && primary);"

  for attempt in $(seq 1 40); do
    if docker compose exec -T "${service}" mongosh --port "${port}" --quiet --eval "${eval_js}" 2>/dev/null | grep -q true; then
      return 0
    fi
    sleep 2
  done

  echo "Не дождались replica set на ${service}:${port} (${expected_members} узла и PRIMARY)" >&2
  exit 1
}

echo "Ожидаем готовности mongod..."
wait_for_mongosh configSrv 27017
wait_for_mongosh shard1-1 27018
wait_for_mongosh shard1-2 27018
wait_for_mongosh shard1-3 27018
wait_for_mongosh shard2-1 27019
wait_for_mongosh shard2-2 27019
wait_for_mongosh shard2-3 27019

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

echo "2. Инициализация replica set shard1 (3 реплики)"
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1",
  members: [
    { _id: 0, host: "shard1-1:27018" },
    { _id: 1, host: "shard1-2:27018" },
    { _id: 2, host: "shard1-3:27018" }
  ]
})
EOF

echo "3. Инициализация replica set shard2 (3 реплики)"
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2",
  members: [
    { _id: 0, host: "shard2-1:27019" },
    { _id: 1, host: "shard2-2:27019" },
    { _id: 2, host: "shard2-3:27019" }
  ]
})
EOF

echo "Ожидаем PRIMARY и все реплики..."
wait_for_rs_ready configSrv 27017 1
wait_for_rs_ready shard1-1 27018 3
wait_for_rs_ready shard2-1 27019 3

echo "Перезапускаем mongos_router"
docker compose restart mongos_router
wait_for_mongosh mongos_router 27020

echo "4. Добавление шардов, шардирование и тестовые данные"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018")
sh.addShard("shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019")
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
docker compose exec -T shard1-1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "Проверка: документы в shard2"
docker compose exec -T shard2-1 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF

echo "Проверка: число реплик shard1"
docker compose exec -T shard1-1 mongosh --port 27018 --quiet --eval "rs.status().members.length"

echo "Проверка: число реплик shard2"
docker compose exec -T shard2-1 mongosh --port 27019 --quiet --eval "rs.status().members.length"
