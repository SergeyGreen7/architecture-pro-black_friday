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
