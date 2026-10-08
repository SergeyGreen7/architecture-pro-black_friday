# mongo-sharding-repl

Запускать команды из директории `mongo-sharding-repl`.

## Как запустить

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Инициализируем шардирование и заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```