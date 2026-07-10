# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Changed

- **Deployer MCP env:** removed `DEPLOYER_MCP_ENABLED` and `DEPLOYER_MCP_KEY_PEPPER`; MCP key hashes use `DEPLOYER_SESSION_SECRET` only. Added **`DEPLOYER_PUBLIC_BASE_URL`** (default `https://deployer.${DOMAIN}` in compose) for Cursor/MCP hints. **`DEPLOYER_MCP_TOOLS_DENY`** — optional MCP tool denylist on deploy.

### Added

- **`DEPLOYER_SOFTWARE`** — optional Alpine tools inside the Deployer container for provision/deprovision (default `bash,curl`; e.g. add `psql` for `umami-pg`). Passed from `.env` via `deployer/docker/entrypoint.sh`. Documented in INSTALL § Deployer; Commerce/Deployer admin docs cross-link here.
- Optional **gocron** cron scheduler (`ENABLE_GOCRON=1`): Traefik at `gocron.${DOMAIN}`, config under `$STACK_ROOT/gocron/config.yaml`. Installer preconfigures `software:` from `GOCRON_SOFTWARE` (default `rsync`; optional restic, rclone, …). Read-only `${STACK_ROOT}:/source/stack` mount for backup jobs. No built-in UI auth — see SECURITY.md. **Documented only in setup-server-stack** (not Commerce/Deployer admin docs).
- Beszel server monitoring (`ENABLE_BESZEL`): hub behind Traefik at `beszel.${DOMAIN}` with first user auto-created from `BESZEL_USER_EMAIL`/`BESZEL_USER_PASSWORD` (password generated into `.secrets`). A local agent (`ENABLE_BESZEL_AGENT`, defaults to `ENABLE_BESZEL`) is auto-registered to monitor this server out of the box: the installer reads the hub public key and a universal token from the hub API and writes them as the agent's `KEY`/`TOKEN` files, so no manual "Add System" step is needed. The agent connects over WebSocket only (`DISABLE_SSH=true`, no inbound port); the hub is published on loopback (`127.0.0.1:8090`) for local provisioning while public access stays via Traefik. Data lives under `$STACK_ROOT/beszel` and `$STACK_ROOT/beszel-agent`.
- Optional per-service data path overrides `<SERVICE>_DATA_PATH` (e.g. `POSTGRES_DATA_PATH`), default `$STACK_ROOT/<service>`, to relocate a single service's data (e.g. a database onto a separate disk). Documented as an advanced block in `.env.example`.

### Changed

- All persistent data moved from Docker named volumes to bind mounts under `$STACK_ROOT/<service>` (`registry`, `portainer`, `semaphore`, `duplicati`, `gocron`, `kuma`, `pgadmin`, `postgres`, `mongo`, `mariadb`, `mysql`), so one copy of `$STACK_ROOT` is a full backup. The installer creates each directory only for enabled services and sets ownership where required (pgAdmin `5050:5050`, Semaphore `1001:0`); Windows deploy preserves them across redeploys.
- NGINX seed page moved from the top-level `public/` to `nginx/public/` so there is a single, clearly named site folder.

## [2.0.0] — 2026-07-10

### Changed

- **License:** MIT replaced by [D-commerce Deployer Source License 1.0](LICENSE). Releases **before 2.0.0** remain under [MIT](LICENSE-MIT.md).
- Installer version **2.0.0** (`setup-server-stack.sh`).

### Added

- Russian license summary: [docs/LICENSE-SUMMARY-RU.md](docs/LICENSE-SUMMARY-RU.md).

## [1.1.0] — 2026-06-20

### Added

- TLS certificate modes via `TRAEFIK_CERT_MODE`: `auto` (default), `provided`, `letsencrypt`, `staging`, `selfsigned`, with per-host diagnostics and Let's Encrypt rate-limit hints.
- Custom certificate layout `$STACK_ROOT/certs/<host>/fullchain.pem` + `privkey.pem` (see `certs/README.md`).
- NGINX static site service (`ENABLE_NGINX`): serves `$STACK_ROOT/nginx/public`, optional `NGINX_HOST` (default `DOMAIN`); seed content is never overwritten on re-runs.
- Deployer auth modes via `DEPLOYER_AUTH_MODE`: `dual` (default), `api`, `ui`; `DEPLOYER_API_KEY` is generated into `.secrets` only in `dual`/`api`.
- Safety guard: refuse to regenerate secrets when Docker Compose state exists but `.secrets` is missing.

### Changed

- `.env.example` restructured for clarity: each comment sits with its parameter; global toggle and secret rules documented in the header.
- Windows deploy (`deploy-from-windows.ps1`) preserves runtime state (`.secrets`, `traefik`, `certs`, `nginx/public`, …) across redeploys.
- All generated passwords, encryption keys, and session secrets are captured in `.secrets` for reproducible setups.

### Fixed

- `deploy-from-windows.ps1`: remote preserve/restore scripts no longer collapse newlines into `; ` (fixes `bash: syntax error near unexpected token ';'`).
- `REGISTRY_AUTH_TOKEN_ISSUER` now defaults safely under `set -u`.
- `print_urls` and `https_service_hosts` return success when trailing services are disabled.

[1.1.0]: https://github.com/commercedeployer/setup-server-stack/releases/tag/v1.1.0

## [1.0.0] — 2026-06-16

### Added

- Unified **Setup Server Stack** installer (`setup-server-stack.sh`).
- Compose profiles: Traefik, Registry, Registry auth, Portainer, Watchtower, Semaphore, Doku, Duplicati, Uptime Kuma, Filebrowser.
- Optional databases: MongoDB, PostgreSQL, MariaDB, MySQL.
- DB web UIs: mongo-express, pgAdmin (auto-linked to Postgres), Adminer.
- Deployer integration (`ENABLE_DEPLOYER`, build into registry).
- Windows deploy: `deploy-from-windows.ps1` (root password once via SSH multiplexing).
- Local CI: `tests/run-ci.sh` (shellcheck, compose config fixtures, validation unit tests).
- GitHub Actions: `.github/workflows/ci.yml` runs the same suite on push/PR.
- Public docs (EN + RU): README, INSTALL, CONTRIBUTING, SECURITY.

### Changed

- Unified product name **Setup Server Stack** (replaced legacy “head stack”).
- Default `REGISTRY_AUTH_TOKEN_ISSUER`: `setup-server-registry`.
- Installer code comments and CLI messages in English.
- Trimmed doc set for GitHub: single INSTALL guide (EN/RU), agent context in `.cursor/rules/`.
- **Deployer:** image-only install via `DEPLOYER_IMAGE`; removed `DEPLOYER_SOURCE_PATH` and local build.

### Removed

- Internal-only docs from public tree (TZ, ARCHITECTURE, ADMIN*, ECOSYSTEM*, STACK-IMPROVEMENTS, `docs/`).
- Deployer source-folder install (`DEPLOYER_INSTALL_MODE`, build from `../deployer`).

[1.0.0]: https://github.com/commercedeployer/setup-server-stack/releases/tag/v1.0.0
