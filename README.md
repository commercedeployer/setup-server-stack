# Setup Server Stack

[![CI](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/commercedeployer/setup-server-stack/actions/workflows/ci.yml)

**Setup Server Stack** is an open-source VPS infrastructure installer: one script, one `.env`, explicit opt-in services, and optional databases. Enable services with `ENABLE_*=1` flags; missing `ENABLE_*` means “do not install” — no separate stacks or manual compose wiring.

Works as a **main** host (Traefik, registry, panels) or a lean **node** via [Compose profiles](https://docs.docker.com/compose/profiles/).

**Русский:** [README.ru.md](README.ru.md)

---

## Features

Opt-in via `ENABLE_*=1` in `.env` (see [INSTALL.md](INSTALL.md) for URLs and passwords).

| For you | Service |
|---------|---------|
| HTTPS and `*.your-domain` routing | **Traefik** |
| Private `docker push` / `pull` for images | **Registry** + **Registry auth** |
| Manage containers in a browser | **Portainer** |
| Nightly image updates without manual pulls | **Watchtower** |
| Ansible playbooks and SSH tasks from the web | **Semaphore** |
| Git repos, issues, and CI in the repo (Gitea Actions) | **Gitea** (+ **Actions runner**) |
| See Docker disk usage by volume/image | **Doku** |
| Backups to S3, SFTP, etc. via a web wizard | **Duplicati** |
| Cron shell jobs (rsync, restic, rclone) in YAML | **gocron** |
| URL uptime checks and alerts | **Uptime Kuma** |
| CPU, RAM, disk charts for this VPS | **Beszel** (local agent auto-registered) |
| Edit files on the host over HTTPS | **Filebrowser** |
| Static landing page at `https://${DOMAIN}` | **NGINX** |
| Deploy app containers from JSON templates | **Deployer** (optional) |
| Databases for your apps (no public DB ports) | MongoDB, PostgreSQL, MariaDB, MySQL |
| Manage databases in a browser | mongo-express, pgAdmin, Adminer |

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

Installer version: **1.2.1** (`setup-server-stack.sh`). See [CHANGELOG.md](CHANGELOG.md).
