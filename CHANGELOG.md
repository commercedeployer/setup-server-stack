# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

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
