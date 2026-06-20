# Безопасность

**English:** [SECURITY.md](SECURITY.md)

## Секреты

**Никогда не коммитьте:**

- `.env`, `.env.stack`, `.secrets`, `secrets/`
- `traefik/acme.json`
- `config/traefik/htpasswd*`, `config/docker_auth/auth_config.yml`, `config/docker/config.json`, `config/pgadmin/*`
- `certs/*.pem` (приватные ключи)

Установщик генерирует их на сервере с правами `600` / `700`.

## Сеть

- Порты СУБД не публикуются на `0.0.0.0`.
- Веб-морды БД — только через Traefik (HTTPS) с паролями из `.env`.
- Включайте `UFW`, `fail2ban`, `APPLY_SSH_HARDENING` на проде.

## Веб-панели (край HTTPS)

Панели открываются как `https://<сервис>.${DOMAIN}`. **Traefik Basic Auth** (дополнительный пароль до входа в приложение) включён **только** для:

- **dashboard Traefik** (`admin` + `TRAEFIK_DASHBOARD_PASSWORD`)
- **Doku** (`STACK_ADMIN_USER` + `DOKU_DASHBOARD_PASSWORD`; `DOKU_DASHBOARD_USER` может переопределить)

Остальные HTTPS-панели защищены **только логином приложения** (или мастером «первого захода»):

| Логин в приложении | Portainer, Semaphore, Duplicati (`DUPLICATI_WEBSERVICE_PASSWORD`), Uptime Kuma, Filebrowser (`STACK_ADMIN_USER` + `FILEBROWSER_PASSWORD`; `FILEBROWSER_USER` может переопределить), Deployer (если включён), mongo-express, pgAdmin, Adminer |
| Не браузерная панель | Registry (`docker login`), Registry auth (`registry-auth.${DOMAIN}`) |

**Практика**

- HTTPS шифрует трафик, но **не** добавляет второй барьер на большинстве панелей — используйте сильные пароли в `.env` / secrets и не включайте ненужные сервисы (или ставьте `ENABLE_*=0`).
- `TRAEFIK_CERT_MODE=auto` может загрузить private keys из `certs/<host>/privkey.pem`; реальные host-папки игнорируются git и должны считаться секретами.
- `TRAEFIK_CERT_MODE=staging` и `TRAEFIK_CERT_MODE=selfsigned` — QA-режимы. HTTPS-маршрутизация остаётся, но браузер не будет доверять сертификату.
- **Первый заход** (Portainer, Uptime Kuma): сразу после установки завершите создание админа, пока URL не стал публичным.
- **Filebrowser** отдаёт только `FILEBROWSER_ROOT_PATH` на хосте (по умолчанию `$STACK_ROOT/filebrowser/files`). На проде **не** ставьте `/`.
- **Статический сайт NGINX** публикует всё из `$STACK_ROOT/nginx/public`. Не кладите туда секреты, бэкапы, `.env` и private keys.
- IP-фильтр, middleware Traefik, доступ только через VPN — **по умолчанию не настраиваются**.

## Сообщить об уязвимости

Не создавайте публичный Issue с эксплойтом. Опишите проблему приватно maintainers репозитория (email или Security Advisory в GitHub, когда репозиторий будет опубликован).
