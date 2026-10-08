# sharding-repl-cache
Запускать команды из директории `sharding-repl-cache`.

## Как запустить

Запускаем mongodb и приложение

```shell
docker compose up -d
```

Инициализируем шардирование и заполняем mongodb данными

```shell
./scripts/mongo-init.sh
```