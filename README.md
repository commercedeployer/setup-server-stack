# Setup Server Stack

[![CI](https://github.com/commerce-deployer/setup-server-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/commerce-deployer/setup-server-stack/actions/workflows/ci.yml)

**Setup Server Stack** is an open-source VPS infrastructure installer: one script, one `.env`, HTTPS services out of the box, and optional databases. Enable services with `ENABLE_*` flags — no separate stacks or manual compose wiring.

Works as a **main** host (Traefik, registry, panels) or a lean **node** via [Compose profiles](https://docs.docker.com/compose/profiles/).

**Русский:** [README.ru.md](README.ru.md)

---

## Features

| Category | Services |
|----------|----------|
| Network & TLS | Traefik 3.6, Let's Encrypt |
| Images | Private Docker Registry + `docker_auth` (token flow) |
| Operations | Portainer, Watchtower, Semaphore, Doku, Duplicati, Uptime Kuma, Filebrowser |
| App deployment | Deployer (optional, `ENABLE_DEPLOYER=1` + `DEPLOYER_IMAGE`) |
| Databases | MongoDB, PostgreSQL, MariaDB, MySQL (optional) |
| DB web UIs | mongo-express, pgAdmin (auto-linked to Postgres), Adminer |

Database ports are **not** exposed to the public internet; access is via the Docker network or HTTPS UIs behind Traefik.

---

## Quick start

**Requirements:** Linux VPS (Ubuntu/Debian), root/sudo, domain with DNS pointing to the server, Docker Compose v2 (or `INSTALL_DOCKER=1`).

```bash
git clone https://github.com/commerce-deployer/setup-server-stack.git setup-server-stack
cd setup-server-stack
cp .env.example .env
# Set DOMAIN, ACME_EMAIL, SSH_PUBLIC_KEY; enable desired ENABLE_*=1
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

- **[Deployer](https://github.com/commerce-deployer/deployer)** — open-source Docker deploy API; enable with `ENABLE_DEPLOYER=1` and `DEPLOYER_IMAGE`. Published images: `docker.io/commercedeployer/deployer:latest` (Docker Hub) or `ghcr.io/commerce-deployer/deployer:latest` (GHCR).
- **D-Commerce** — commercial storefront and billing; calls Deployer over HTTP. Stack and Deployer work **without** D-Commerce.

---

## Secrets

Empty passwords in `.env` are filled on first run into **`.setup-server-stack-secrets`** (chmod 600). **Do not commit** `.env`, `.env.stack`, `.setup-server-stack-secrets`, `traefik/acme.json`, or generated `config/*`.

---

## License

[MIT](LICENSE)

---

## Status

Installer version: **1.0.0** (`setup-server-stack.sh`). See [CHANGELOG.md](CHANGELOG.md).
