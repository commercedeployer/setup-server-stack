# Setup Server Stack

[![CI](https://github.com/commerce-deployer/setup-server-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/commerce-deployer/setup-server-stack/actions/workflows/ci.yml)

**Setup Server Stack** — open-source установщик VPS-инфраструктуры: один скрипт, один `.env`, готовые HTTPS-сервисы и опциональные базы данных. Состав сервисов включается флагами `ENABLE_*` — без отдельных «стеков» и ручной склейки compose.

Подходит для **main**-хоста (Traefik, registry, панели) и **node**-роли — через [Compose profiles](https://docs.docker.com/compose/profiles/).

**English:** [README.md](README.md)

---

## Возможности

| Категория | Сервисы |
|-----------|---------|
| Сеть и TLS | Traefik 3.6, Let's Encrypt |
| Образы | Private Docker Registry + `docker_auth` (token flow) |
| Операции | Portainer, Watchtower, Semaphore, Doku, Duplicati, Uptime Kuma, Filebrowser |
| Деплой приложений | Deployer (опционально, `ENABLE_DEPLOYER=1` + `DEPLOYER_IMAGE`) |
| Базы данных | MongoDB, PostgreSQL, MariaDB, MySQL (опционально) |
| Веб-морды БД | mongo-express, pgAdmin (автопривязка к Postgres), Adminer |

Порты СУБД **не** публикуются в интернет; доступ — из Docker-сети или через HTTPS-морды (Traefik).

---

## Быстрый старт

**Требования:** Linux VPS (Ubuntu/Debian), root/sudo, домен с DNS на сервер, Docker Compose v2 (или `INSTALL_DOCKER=1`).

```bash
git clone https://github.com/commerce-deployer/setup-server-stack.git setup-server-stack
cd setup-server-stack
cp .env.example .env
# Заполните DOMAIN, ACME_EMAIL, SSH_PUBLIC_KEY; включите нужные ENABLE_*=1
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

- **[Deployer](https://github.com/commerce-deployer/deployer)** — open-source API и шаблоны Docker; `ENABLE_DEPLOYER=1` и `DEPLOYER_IMAGE` (`docker.io/commerce-deployer/deployer:latest` или `ghcr.io/commerce-deployer/deployer:latest` после релиза).
- **D-Commerce** — коммерческая витрина и биллинг; на проде вызывает Deployer по HTTP. Stack и Deployer работают **без** D-Commerce.

---

## Секреты

Пустые пароли в `.env` при первом запуске дополняются в **`.setup-server-stack-secrets`** (chmod 600). **Не коммитьте** `.env`, `.env.stack`, `.setup-server-stack-secrets`, `traefik/acme.json`, сгенерированные `config/*`.

---

## Лицензия

[MIT](LICENSE)

---

## Статус

Версия установщика: **1.0.0** (`setup-server-stack.sh`). См. [CHANGELOG.md](CHANGELOG.md).
