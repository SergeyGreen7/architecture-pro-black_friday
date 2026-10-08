# Задание 8. Горячие шарды

Проблема: категория «Электроника» даёт ~70% запросов.
Если шард-ключ — `category`, все эти товары лежат на одном шарде.
Шард перегревается по CPU, I/O и соединениям, остальные простаивают.

Правило: один только `category` / `geo_zone` / `status` как шард-ключ нельзя — мало значений, всё на одном шарде. Для зон берут составной ключ `{ category: 1, _id: 1 }` и вешают горячую зону на несколько шардов.

---

## 1. Метрики

Смотрим **на каждом шарде** и сравниваем между собой. Горячий шард — если доля ops / CPU / данных сильно выше 1/N (при двух шардах — заметно больше 50%, у нас 70%).

| Метрика | Зачем | Откуда |
| --- | --- | --- |
| `opcounters.query / update / insert` | непропорциональный трафик | `db.serverStatus().opcounters` |
| connections | шторм запросов на один узел | `db.serverStatus().connections` |
| latency (`opLatencies`) | шард не успевает | `db.serverStatus().opLatencies` |
| CPU, disk IOPS, `wiredTiger.cache` | железо упирается | хост + `serverStatus` |
| размер данных и число чанков | перекос хранения | `sh.status()`, `config.chunks` |
| replication lag | secondary не успевает | `rs.printSecondaryReplicationInfo()` |
| balancer | чанки не едут | `sh.getBalancerState()`, `sh.isBalancerRunning()` |

```js
// нагрузка шарда
db.serverStatus().opcounters
db.serverStatus().connections
db.serverStatus().opLatencies

// данные и чанки
sh.status()
db.getSiblingDB("config").chunks.aggregate([
  { $match: { ns: "somedb.products" } },
  { $group: { _id: "$shard", chunks: { $sum: 1 } } }
])

// размер коллекции на шарде (запускать на primary шарда)
db.products.stats()

// лаг реплик
rs.printSecondaryReplicationInfo()

// балансировщик
sh.getBalancerState()
sh.isBalancerRunning()
```

Алерты (пример): CPU шарда > 80% дольше 5 мин; доля `opcounters` шарда > 60% от суммы; число чанков отличается больше чем в 1.5 раза; replication lag > 10 с.

---

## 2. Что делать

### Сейчас: убрать причину

Перешардировать `products` на `{ _id: "hashed" }`. Документы «Электроники» разъедутся по всем шардам. Запросы к карточке и остаткам по `_id` останутся точечными.

```js
sh.setBalancerState(true)
sh.startBalancer()

sh.reshardCollection("somedb.products", { _id: "hashed" })
```

Пока `reshardCollection` идёт, можно смотреть прогресс:

```js
db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, idleConnections: true } },
  { $match: { desc: { $regex: "reshard" } } }
])
```

### Автоперераспределение чанков

Balancer сам двигает чанки, если включён. Не выключать его в проде без причины.

```js
sh.setBalancerState(true)
sh.startBalancer()

// окно, чтобы не двигать чанки в пик (UTC)
db.adminCommand({
  setBalancerState: true
})
use config
db.settings.updateOne(
  { _id: "balancer" },
  { $set: { stopped: false, activeWindow: { start: "01:00", stop: "05:00" } } },
  { upsert: true }
)
```

Горячий чанк (много запросов в узкий диапазон ключа) — разрезать и увезти:

```js
sh.status()
sh.splitAt("somedb.products", { _id: ObjectId("...") })
sh.moveChunk("somedb.products", { _id: ObjectId("...") }, "shard2")
```

Jumbo-чанк балансировщик не двигает — сначала `split`.

### Zone / tag-aware sharding

Hashed `{ _id }` размазывает все категории равномерно. Если каталог «Электроника» нужно держать на выделенных узлах (больше CPU), включают **зоны**: balancer кладёт чанки только на шарды с нужным тегом.

Одна зона на один шард для «Электроники» — это снова горячий шард. Зону `electronics` вешают на **несколько** шардов. Шард-ключ ranged, не hashed: `{ category: 1, _id: 1 }`. Поле `_id` режет категорию на чанки, теги раскладывают их по шардам зоны.

```js
// ключ с префиксом category, иначе диапазоны зоны не задать
sh.reshardCollection("somedb.products", { category: 1, _id: 1 })

sh.addShardToZone("shard1", "electronics")
sh.addShardToZone("shard2", "electronics")   // горячая категория на двух шардах
sh.addShardToZone("shard3", "other")

sh.updateZoneKeyRange(
  "somedb.products",
  { category: "Электроника", _id: MinKey },
  { category: "Электроника", _id: MaxKey },
  "electronics"
)
sh.updateZoneKeyRange(
  "somedb.products",
  { category: MinKey, _id: MinKey },
  { category: "Электроника", _id: MinKey },
  "other"
)
sh.updateZoneKeyRange(
  "somedb.products",
  { category: "Электроника", _id: MaxKey },
  { category: MaxKey, _id: MaxKey },
  "other"
)

sh.status()
```

Balancer сам уедет чанки «Электроники» на `shard1`+`shard2`. Запрос `{ category: "Электроника" }` идёт только в зону, не в scatter-gather по всему кластеру.

Когда ops в зоне снова > 60% — добавить шард в ту же зону, не перешардировать всё:

```js
sh.addShard("shard4/shard4:27018")
sh.addShardToZone("shard4", "electronics")
```

Снять зону:

```js
sh.removeRangeFromZone("somedb.products", { category: "Электроника", _id: MinKey }, { category: "Электроника", _id: MaxKey })
sh.removeShardFromZone("shard1", "electronics")
```

Hashed-ключ с зонами не сочетается: диапазон `{ _id: hashed }` нельзя привязать к категории. Сначала ranged `{ category: 1, _id: 1 }`, потом теги.

### Чтобы не повторилось

1. Не шардировать **только** по `category`. Либо hashed `_id`, либо `{ category: 1, _id: 1 }` + зона `electronics` на 2+ шардах.
2. Популярные карточки — кеш Redis (`GET /products/:id`), чтобы не бить один документ на шарде.
3. Расти горизонтально: `sh.addShard(...)` и при зонах — `addShardToZone` в горячую зону.
4. После смены ключа / зон проверить чанки и ops (`sh.status()`, `opcounters`).

```js
db.products.createIndex({ category: 1, price: 1 })

// каталог «Электроника» — scatter-gather, но нагрузка на все шарды, не на один
db.products.find({ category: "Электроника", price: { $gte: 10000, $lte: 50000 } })
```

---
