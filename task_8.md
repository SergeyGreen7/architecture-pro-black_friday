# Задание 8. Горячие шарды

Проблема: категория «Электроника» даёт ~70% запросов.
Если шард-ключ — `category`, все эти товары лежат на одном шарде.
Шард перегревается по CPU, I/O и соединениям, остальные простаивают.

Правило: шард-ключ с малой кардинальностью (`category`, `geo_zone`, `status`) нельзя использовать.

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

### Чтобы не повторилось

1. Не шардировать по `category`. Категория — только индекс: `{ category: 1, price: 1 }`.
2. Популярные карточки — кеш Redis (`GET /products/:id`), чтобы не бить один документ на шарде.
3. Расти горизонтально: `sh.addShard("shard3/...")`, balancer разложит чанки.
4. После смены ключа проверить, что чанки и ops выровнялись (`sh.status()`, `opcounters`).

```js
db.products.createIndex({ category: 1, price: 1 })

// каталог «Электроника» — scatter-gather, но нагрузка на все шарды, не на один
db.products.find({ category: "Электроника", price: { $gte: 10000, $lte: 50000 } })
```

---
