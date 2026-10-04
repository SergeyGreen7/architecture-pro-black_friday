# Задание 7. Схемы коллекций и шардирование

БД: `somedb`. Стратегия везде — **hashed**: равномерное распределение, точечные запросы по ключу.

Геозона не подходит как шард-ключ: значений мало, шарды будут перекошены.

---

## products

```js
{
  _id: ObjectId("..."),          // id товара
  name: "Смартфон X",
  category: "Электроника",
  price: 49990,
  stock: { MSK: 20, EKB: 50, KGD: 30 },
  attrs: { color: "black", size: "128GB" }
}
```

**Шард-ключ:** `{ _id: "hashed" }`

Почему: остатки и страница товара всегда идут по `_id` — запрос попадает в один шард. Категорий мало, `category` даст перекос. Поиск по категории и цене — scatter-gather + индекс.

```js
sh.enableSharding("somedb")
sh.shardCollection("somedb.products", { _id: "hashed" })
db.products.createIndex({ category: 1, price: 1 })

db.products.find({ _id: ObjectId("...") })
db.products.updateOne({ _id: ObjectId("...") }, { $inc: { "stock.EKB": -1 } })
db.products.find({ category: "Электроника", price: { $gte: 10000, $lte: 50000 } })
```

---

## orders

```js
{
  _id: ObjectId("..."),          // id заказа
  user_id: "u123",               // клиент
  created_at: ISODate("2026-10-04T12:00:00Z"),
  items: [
    { product_id: "p1", name: "Смартфон X", price: 49990, qty: 1 },
    { product_id: "p2", name: "Книга", price: 790, qty: 2 }
  ],
  status: "created",             // created | paid | shipped | done
  total: 51570,
  geo_zone: "MSK"
}
```

**Шард-ключ:** `{ user_id: "hashed" }`

Почему: история заказов — `find({ user_id })`, все заказы пользователя на одном шарде. Создание заказа тоже идёт в этот шард. `_id` сделал бы историю scatter-gather. `geo_zone` и `status` — мало значений.

```js
sh.shardCollection("somedb.orders", { user_id: "hashed" })
db.orders.createIndex({ user_id: 1, created_at: -1 })
db.orders.createIndex({ user_id: 1, _id: 1 })

db.orders.insertOne({ user_id: "u123", created_at: new Date(), items: [...], status: "created", total: 51570, geo_zone: "MSK" })
db.orders.find({ user_id: "u123" }).sort({ created_at: -1 })
db.orders.findOne({ user_id: "u123", _id: ObjectId("...") }, { status: 1 })
```

Статус ищем вместе с `user_id`, чтобы не сканировать все шарды.

---

## carts

```js
{
  _id: ObjectId("..."),
  owner_id: "u123",              // user_id или session_id гостя
  user_id: "u123",               // null у гостя
  session_id: "s456",
  items: [{ product_id: "p1", quantity: 2 }],
  status: "active",              // active | ordered | abandoned
  created_at: ISODate("..."),
  updated_at: ISODate("..."),
  expires_at: ISODate("...")     // TTL
}
```

`owner_id` = `user_id` у клиента, `session_id` у гостя. Так и гость, и пользователь имеют одно поле для шардирования.

**Шард-ключ:** `{ owner_id: "hashed" }`

Почему: корзину читают и меняют по `user_id` или `session_id` — это `owner_id`, один шард. `status` нельзя: почти все `active`. Гости с пустым `user_id` иначе свалятся на один шард.

```js
sh.shardCollection("somedb.carts", { owner_id: "hashed" })
db.carts.createIndex({ owner_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })

// гость
db.carts.insertOne({ owner_id: "s456", user_id: null, session_id: "s456", items: [], status: "active", created_at: new Date(), updated_at: new Date(), expires_at: new Date(Date.now() + 7*864e5) })
db.carts.findOne({ owner_id: "s456", status: "active" })

// пользователь
db.carts.findOne({ owner_id: "u123", status: "active" })

// добавить товар
db.carts.updateOne(
  { owner_id: "u123", status: "active" },
  { $push: { items: { product_id: "p1", quantity: 1 } }, $set: { updated_at: new Date() } }
)

// слияние гостевой в пользовательскую
const guest = db.carts.findOne({ owner_id: "s456", status: "active" })
db.carts.updateOne(
  { owner_id: "u123", status: "active" },
  { $push: { items: { $each: guest.items } }, $set: { updated_at: new Date() } }
)
db.carts.updateOne({ owner_id: "s456", status: "active" }, { $set: { status: "abandoned" } })

// заказ оформлен
db.carts.updateOne({ owner_id: "u123", status: "active" }, { $set: { status: "ordered" } })
```

---

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

# Задание 9. Чтение с реплик и консистентность

Запись всегда идёт в **primary**. Ниже — только чтение.

Допустимая задержка: сколько secondary может отставать, чтобы бизнес это пережил. Если отставание больше — читать с primary.

```js
// secondary
db.getMongo().setReadPref("secondary", [{ lag: { $lt: 2 } }])  // maxStalenessSeconds в драйвере

// primary
db.getMongo().setReadPref("primary")
```

В приложении: `readPreference=secondary` + `maxStalenessSeconds=2` (или 5 для каталога). Для строгих чтений — `primary`.

---

## Таблица

| Коллекция | Операция | Куда | Задержка | Почему |
| --- | --- | --- | --- | --- |
| products | страница товара (название, цена, атрибуты) | secondary | до **5 с** | витрина, устаревшее описание не продаёт чужой товар |
| products | поиск по категории и цене | secondary | до **5 с** | фильтр каталога, обновляется редко |
| products | остаток перед покупкой / списанием | **primary** | **0** | иначе продадим то, чего нет |
| orders | история заказов пользователя | secondary | до **2 с** | список можно чуть отстать; только что созданный заказ лучше читать с primary |
| orders | статус заказа | **primary** | **0** | пользователь не должен видеть «создан», если уже «оплачен» |
| carts | текущая корзина `{ owner_id, status:"active" }` | **primary** | **0** | добавил товар — сразу должен его видеть |
| carts | слияние гостевой в пользовательскую | **primary** | **0** | иначе потеряем items с отставшей реплики |
| carts | корзина для оформления заказа | **primary** | **0** | состав должен совпасть с тем, что спишем |

---

## Обоснование

**products.** Карточка и каталог читаются часто, пишутся редко (кроме `stock`). Их можно отдать secondary и снять нагрузку с primary. Остатки меняются на каждой покупке: чтение `stock` с secondary → гонка, товар «есть» на сайте и «нет» при списании. Остаток для чекаута — только primary (лучше в одной транзакции со списанием).

**orders.** История — много чтений, мало критичности: 1–2 с нормально. Статус меняется редко, но для клиента это правда о заказе. Secondary может показать старый статус после оплаты. Статус — primary.

**carts.** Почти каждое действие — read + write. Корзина живёт минуты, обновления частые. Secondary почти наверняка без последнего `$push`. Слияние и чекаут с устаревшей копией ломают заказ. Вся корзина — primary.

---

## Настройка (пример)

```js
// каталог — можно со secondary, не старше 5 секунд
db.products.find({ category: "Электроника" }).readPref("secondary", [{ maxStalenessSeconds: 5 }])

// карточка без опоры на остаток
db.products.findOne({ _id: ObjectId("...") }, { stock: 0 }).readPref("secondary")

// остаток к списанию
db.products.findOne({ _id: ObjectId("...") }, { stock: 1 }).readPref("primary")

// история
db.orders.find({ user_id: "u123" }).sort({ created_at: -1 }).readPref("secondary", [{ maxStalenessSeconds: 2 }])

// статус
db.orders.findOne({ user_id: "u123", _id: ObjectId("...") }, { status: 1 }).readPref("primary")

// корзина
db.carts.findOne({ owner_id: "u123", status: "active" }).readPref("primary")
```

---

# Задание 10. Миграция на Cassandra

MongoDB с range-шардированием при addShard гоняет чанки по всему кластеру — в пик 50k rps это бьёт по latency. Cassandra режет кольцо токенами: новый узел забирает только свою долю, полного перекладывания нет. Репликация leaderless.

---

## 10.1 Что переносим

| Данные | Критичность | Cassandra? | Почему |
| --- | --- | --- | --- |
| orders / история | целостность + быстрая запись | **да** | пик записей, история по пользователю, можно QUORUM |
| carts | скорость | **да** | много мелких write, TTL, без мультидокументных транзакций |
| sessions | скорость | **да** | ключ-значение, TTL, георепликация |
| products (карточка, каталог) | скорость чтения | **да** | много чтения, редкие правки цены/описания |
| stock (остатки к списанию) | целостность | **нет / осторожно** | нужна строгая согласованность; лучше LWT или оставить списание в Mongo |
| оплата / деньги | целостность | **нет** | не для Cassandra |

В Cassandra: **orders**, **carts**, **sessions**, **products**. Списание остатка в пик — отдельный контур (Mongo или LWT), не обычный `UPDATE` с `ONE`.

---

## 10.2 Модель и ключи

Партиция = hash(partition key). Нельзя брать `category`, `geo_zone`, `status`, одну дату «чёрной пятницы» — получится горячая партиция.

Новый узел в кольце забирает диапазон токенов (~1/N данных), не весь датасет.

### orders

Запросы: создать заказ, история пользователя по времени.

```sql
CREATE TABLE orders (
  user_id     text,
  created_at  timestamp,
  order_id    uuid,
  status      text,
  total       decimal,
  geo_zone    text,
  items       text,   -- JSON списка товаров
  PRIMARY KEY ((user_id), created_at, order_id)
) WITH CLUSTERING ORDER BY (created_at DESC);
```

- partition: `user_id` — история одним запросом, пользователи размазаны по кольцу.
- clustering: `created_at, order_id` — свежие сверху, без горячей партиции «все заказы 29 ноября».

### carts

Запросы: одна активная корзина гостя или пользователя.

```sql
CREATE TABLE carts (
  owner_id    text,   -- user_id или session_id
  updated_at  timestamp,
  user_id     text,
  session_id  text,
  status      text,
  items       text,
  PRIMARY KEY ((owner_id))
);
```

Одна партиция = одна корзина. `owner_id` уникален, горячих категорий нет. TTL:

```sql
ALTER TABLE carts WITH default_time_to_live = 604800;  -- 7 дней
```

### sessions

```sql
CREATE TABLE sessions (
  session_id  text,
  user_id     text,
  payload     text,
  PRIMARY KEY ((session_id))
) WITH default_time_to_live = 86400;
```

Равномерно, точечное чтение.

### products

Не `(category)` — снова «Электроника» на одном токене.

```sql
CREATE TABLE products (
  product_id  text,
  name        text,
  category    text,
  price       decimal,
  attrs       text,
  PRIMARY KEY ((product_id))
);

-- выборка по категории — отдельная таблица (query-first)
CREATE TABLE products_by_category (
  category    text,
  product_id  text,
  name        text,
  price       decimal,
  PRIMARY KEY ((category), price, product_id)
);
```

Карточка — по `product_id`, ровно. Каталог «Электроника» останется горячее других категорий (это один partition). Если партиция огромная — дробим bucket:

```sql
PRIMARY KEY ((category, bucket), price, product_id)
```

`bucket = product_id hash % 8` — 8 партиций на категорию, нет одной гигантской.

---

## 10.3 Целостность: Hinted Handoff, Read Repair, Anti-Entropy

| Стратегия | Когда | Latency | Гарантия |
| --- | --- | --- | --- |
| **Hinted Handoff** | реплика кратко недоступна, координатор держит hint и догоняет | запись не ждёт мёртвый узел | временная, hints живут ограниченно |
| **Read Repair** | при чтении сравнивает реплики и чинит | чтение чуть дороже | хорошо для часто читаемых данных |
| **Anti-Entropy** (`nodetool repair`) | сверка merkle-деревьев по расписанию | не в запросе, но тяжёлая на кластере | полная, для редко читаемого |

### Что включаем

**carts, sessions** — Hinted Handoff. Пишем часто, читаем свою партицию. Короткий даун узла не должен тормозить пик. Read Repair по желанию (`always` не ставить — лишняя цена на каждый GET).

**products** — Read Repair. Каталог и карточки читают все. Рассинхрон цены/описания чинится на чтении. Hinted Handoff тоже (обычный дефолт).

**orders** — Hinted Handoff в пик + Anti-Entropy ночью. Заказы нельзя потерять, но `repair` в чёрную пятницу нельзя. Чтение истории не такое частое, как витрина, Read Repair не обязателен на каждом запросе. Консистентность записи: `QUORUM`.

```sql
-- примеры консистентности
-- запись заказа
CONSISTENCY QUORUM;
INSERT INTO orders (...) VALUES (...);

-- витрина
CONSISTENCY ONE;
SELECT * FROM products WHERE product_id = 'p1';

-- корзина (свой ключ, свежие данные)
CONSISTENCY LOCAL_QUORUM;
SELECT * FROM carts WHERE owner_id = 'u123';
```

```text
# hinted handoff — включён по умолчанию
hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000   # 3 часа

# read repair — не 100% запросов
# в таблице: read_repair_chance устарел; в 4.x достаточно QUORUM-чтений
# и периодического repair

# anti-entropy — не в пик
nodetool repair -pr somedb orders
```

Расписание: `repair` заказов в 03:00, не 29 ноября днём. В пик — HH + QUORUM, без full repair.

---
