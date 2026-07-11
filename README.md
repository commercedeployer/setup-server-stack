# Setup Server Stack

[![CI](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml)

**Setup Server Stack** is an open-source VPS infrastructure installer: one script, one `.env`, explicit opt-in services, and optional databases. Enable services with `ENABLE_*=1` flags; missing `ENABLE_*` means “do not install” — no separate stacks or manual compose wiring.

Works as a **main** host (Traefik, registry, panels) or a lean **node** via [Compose profiles](https://docs.docker.com/compose/profiles/).

**Русский:** [README.ru.md](README.ru.md)

---

## Features

| Category | Services |
|----------|----------|
| Network & TLS | Traefik 3.6, custom certs from `certs/<host>/`, Let's Encrypt production/staging, self-signed QA mode |
| Images | Private Docker Registry + Registry auth (`docker_auth` token flow) |
| Operations | Portainer, Watchtower, Semaphore, Doku, Duplicati, gocron, Uptime Kuma, Beszel (with auto-registered local agent), Filebrowser, NGINX static site |
| App deployment | Deployer (optional, `ENABLE_DEPLOYER=1` + `DEPLOYER_IMAGE`) |
| Databases | MongoDB, PostgreSQL, MariaDB, MySQL (optional) |
| DB web UIs | mongo-express, pgAdmin (auto-linked to Postgres), Adminer |

Database ports are **not** exposed to the public internet; access is via the Docker network or HTTPS UIs behind Traefik.

---

## Quick start

**Requirements:** Linux VPS (Ubuntu/Debian), root/sudo, domain with DNS pointing to the server, Docker Compose v2 (or `INSTALL_DOCKER=1`).

```bash
git clone https://github.com/commercedeployer/setup-server-stack.git setup-server-stack
cd setup-server-stack
cp .env.example .env
# .env.example is a full QA stack; remove ENABLE_*=1 lines you do not need
# Set DOMAIN, ACME_EMAIL, SSH_PUBLIC_KEY
# TLS default: TRAEFIK_CERT_MODE=auto ($STACK_ROOT/certs/<host> if present, otherwise Let's Encrypt)
# Static site: ENABLE_NGINX=1 publishes $STACK_ROOT/nginx/public on https://DOMAIN
# For reinstall-heavy QA: TRAEFIK_CERT_MODE=staging or selfsigned
# Deployer: ENABLE_DEPLOYER=1 and DEPLOYER_IMAGE=ghcr.io/commercedeployer/deployer:latest
chmod +x setup-server-stack.sh install.sh
sudo bash ./setup-server-stack.sh
```

**From Windows:** `.\deploy-from-windows.ps1` — see [INSTALL.md](INSTALL.md) §2.5.

Re-run after editing `.env`: `sudo bash ./setup-server-stack.sh`.

---

## Documentation

| Document | Description |
|----------|-------------|
| [INSTALL.md](INSTALL.md) | Install, DNS, passwords, Deployer, day-2 ops ([RU](INSTALL.ru.md)) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute ([RU](CONTRIBUTING.ru.md)) |
| [SECURITY.md](SECURITY.md) | Secrets and vulnerability reports ([RU](SECURITY.ru.md)) |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

---

## Ecosystem

Setup Server Stack is the **infrastructure layer**:

- **[Deployer](https://github.com/commercedeployer/deployer)** — open-source Docker deploy API; `ENABLE_DEPLOYER=1` + `DEPLOYER_IMAGE` (GHCR or Docker Hub — both published by CI).
- **D-Commerce** — commercial storefront and billing; calls Deployer over HTTP. Stack and Deployer work **without** D-Commerce.

---

## Secrets

Empty passwords in `.env` are filled on first run into server **`.secrets`** (chmod 600). Windows deploys archive a local copy in **`secrets/<timestamp>`**. **Do not commit** `.env`, `.env.stack`, `.secrets`, `secrets/`, `traefik/acme.json`, or generated `config/*`.

---

## License

[MIT](LICENSE)

---

## Status

Installer version: **1.2.0** (`setup-server-stack.sh`). See [CHANGELOG.md](CHANGELOG.md).
