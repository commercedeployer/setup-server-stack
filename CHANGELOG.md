# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] — 2026-06-16

### Added

- Unified **Setup Server Stack** installer (`setup-server-stack.sh`).
- Compose profiles: Traefik, registry, docker_auth, Portainer, Watchtower, Semaphore, Doku, Duplicati, Uptime Kuma, Filebrowser.
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
