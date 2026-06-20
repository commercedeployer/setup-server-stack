# TLS-сертификаты

Эта папка нужна для переиспользуемых TLS-сертификатов Traefik. На сервере это всегда `$STACK_ROOT/certs`; отдельной настройки пути в `.env` нет.

Одна папка = один точный host:

```text
certs/<host>/fullchain.pem
certs/<host>/privkey.pem
```

Примеры:

```text
certs/portainer.example.com/fullchain.pem
certs/portainer.example.com/privkey.pem

certs/registry.example.com/fullchain.pem
certs/registry.example.com/privkey.pem
```

Сертификат может быть от Let's Encrypt, панели хостинга или платного CA. Для Traefik это одинаковый формат.

Как режимы используют эту папку:

- `TRAEFIK_CERT_MODE=auto`: сначала берёт `certs/<host>/`; если пары нет, запрашивает production Let's Encrypt.
- `TRAEFIK_CERT_MODE=provided`: использует только `certs/<host>/`; в Let's Encrypt не обращается.
- `TRAEFIK_CERT_MODE=letsencrypt`: игнорирует `certs/<host>/` для маршрутизации и запрашивает production Let's Encrypt.

После успешного выпуска production Let's Encrypt в режиме `auto` или `letsencrypt` установщик экспортирует сертификат на сервере в ту же структуру `certs/<host>/`. Уже существующие `fullchain.pem` или `privkey.pem` не перезаписываются.

Private key - секрет. Не коммитьте реальные host-папки.

Важно: setup-server-stack может создавать в этой папке служебные файлы вроде `registry-token.pem`. Пользовательские TLS-сертификаты кладите только в папки с именем host-а.