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