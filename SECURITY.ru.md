# Безопасность

**English:** [SECURITY.md](SECURITY.md)

## Секреты

**Никогда не коммитьте:**

- `.env`, `.env.stack`, `.setup-server-stack-secrets`
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
- **Doku** (`doku` + `DOKU_DASHBOARD_PASSWORD`)

Остальные HTTPS-панели защищены **только логином приложения** (или мастером «первого захода»):

| Логин в приложении | Portainer, Semaphore, Duplicati, Uptime Kuma, Filebrowser, Deployer (если включён), mongo-express, pgAdmin, Adminer |
| Не браузерная панель | Registry (`docker login`), docker_auth (`auth.${DOMAIN}`) |

**Практика**

- HTTPS шифрует трафик, но **не** добавляет второй барьер на большинстве панелей — используйте сильные пароли в `.env` / secrets и отключайте ненужные сервисы (`ENABLE_*=0`).
- **Первый заход** (Portainer, Duplicati, Uptime Kuma): сразу после установки завершите создание админа, пока URL не стал публичным.
- **Filebrowser** отдаёт только `FILEBROWSER_ROOT_PATH` на хосте (по умолчанию `$STACK_ROOT/filebrowser/files`). На проде **не** ставьте `/`.
- IP-фильтр, middleware Traefik, доступ только через VPN — **по умолчанию не настраиваются**.

## Сообщить об уязвимости

Не создавайте публичный Issue с эксплойтом. Опишите проблему приватно maintainers репозитория (email или Security Advisory в GitHub, когда репозиторий будет опубликован).
