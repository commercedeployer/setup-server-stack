# Setup Server Stack

[![CI](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml)

**Setup Server Stack** — open-source установщик VPS-инфраструктуры: один скрипт, один `.env`, явно включаемые сервисы и опциональные базы данных. Сервис ставится только при `ENABLE_*=1`; если строки `ENABLE_*` нет, сервис не ставится — без отдельных «стеков» и ручной склейки compose.

Подходит для **main**-хоста (Traefik, registry, панели) и **node**-роли — через [Compose profiles](https://docs.docker.com/compose/profiles/).

**English:** [README.md](README.md)

---

## Возможности

Включение — `ENABLE_*=1` в `.env` (URL и пароли: [INSTALL.ru.md](INSTALL.ru.md)).

| Зачем | Сервис |
|-------|--------|
| HTTPS и маршруты `*.ваш-домен` | **Traefik** |
| Свой `docker push` / `pull` образов | **Registry** + **Registry auth** |
| Управление контейнерами в браузере | **Portainer** |
| Ночное обновление образов без ручного pull | **Watchtower** |
| Ansible-плейбуки и SSH-задачи из веб-UI | **Semaphore** |
| Git-репозитории, issues и CI в репо (Gitea Actions) | **Gitea** (+ **Actions runner**) |
| Сколько места занимают тома и образы Docker | **Doku** |
| Бэкапы в S3, SFTP и т.д. через мастер в UI | **Duplicati** |
| Cron-задания (rsync, restic, rclone) в YAML | **gocron** |
| Проверка доступности URL и алерты | **Uptime Kuma** |
| Графики CPU, RAM, диска этого VPS | **Beszel** (локальный агент авто-регистрируется) |
| Правка файлов на хосте по HTTPS | **Filebrowser** |
| Статическая визитка на `https://${DOMAIN}` | **NGINX** |
| Деплой приложений из JSON-шаблонов | **Deployer** (опционально) |
| Базы для ваших приложений (порты БД не в интернет) | MongoDB, PostgreSQL, MariaDB, MySQL |
| Админка БД в браузере | mongo-express, pgAdmin, Adminer |

Порты СУБД **не** публикуются в интернет; доступ — из Docker-сети или через HTTPS-морды (Traefik).

---

## Быстрый старт

**Требования:** Linux VPS (Ubuntu/Debian), root/sudo, домен с DNS на сервер, Docker Compose v2 (или `INSTALL_DOCKER=1`).

```bash
git clone https://github.com/commercedeployer/setup-server-stack.git setup-server-stack
cd setup-server-stack
cp .env.example .env
# .env.example — полный QA-стек; удалите ENABLE_*=1 для ненужных сервисов
# Заполните DOMAIN, ACME_EMAIL, SSH_PUBLIC_KEY
# TLS по умолчанию: TRAEFIK_CERT_MODE=auto ($STACK_ROOT/certs/<host>, если есть; иначе Let's Encrypt)
# Статический сайт: ENABLE_NGINX=1 публикует $STACK_ROOT/nginx/public на https://DOMAIN
# Для частых QA-переустановок: TRAEFIK_CERT_MODE=staging или selfsigned
# Deployer: ENABLE_DEPLOYER=1 и DEPLOYER_IMAGE=ghcr.io/commercedeployer/deployer:latest
chmod +x setup-server-stack.sh install.sh
sudo bash ./setup-server-stack.sh
```

**С Windows:** `.\deploy-from-windows.ps1` — см. [INSTALL.ru.md](INSTALL.ru.md) §2.5.

Повторный прогон (после правки `.env`): `sudo bash ./setup-server-stack.sh`.

---

## Документация

| Документ | Описание |
|----------|----------|
| [INSTALL.ru.md](INSTALL.ru.md) | Установка, DNS, пароли, Deployer, эксплуатация ([EN](INSTALL.md)) |
| [CONTRIBUTING.ru.md](CONTRIBUTING.ru.md) | Как участвовать ([EN](CONTRIBUTING.md)) |
| [SECURITY.ru.md](SECURITY.ru.md) | Секреты и уязвимости ([EN](SECURITY.md)) |
| [CHANGELOG.md](CHANGELOG.md) | История релизов |

---

## Экосистема

Setup Server Stack — **нижний слой** (инфраструктура VPS):

- **[Deployer](https://github.com/commercedeployer/deployer)** — open-source API и шаблоны Docker; `ENABLE_DEPLOYER=1` + `DEPLOYER_IMAGE` (GHCR или Docker Hub — оба публикует CI).
- **D-Commerce** — коммерческая витрина и биллинг; на проде вызывает Deployer по HTTP. Stack и Deployer работают **без** D-Commerce.

---

## Секреты

Пустые пароли в `.env` при первом запуске дополняются в серверный **`.secrets`** (chmod 600). Windows-deploy сохраняет локальную копию в **`secrets/<timestamp>`**. **Не коммитьте** `.env`, `.env.stack`, `.secrets`, `secrets/`, `traefik/acme.json`, сгенерированные `config/*`.

---

## Лицензия

[MIT](LICENSE)

---

## Статус

Версия установщика: **1.2.1** (`setup-server-stack.sh`). См. [CHANGELOG.md](CHANGELOG.md).
