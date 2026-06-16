# Security

**Русский:** [SECURITY.ru.md](SECURITY.ru.md)

## Secrets

**Never commit:**

- `.env`, `.env.stack`, `.setup-server-stack-secrets`
- `traefik/acme.json`
- `config/traefik/htpasswd*`, `config/docker_auth/auth_config.yml`, `config/docker/config.json`, `config/pgadmin/*`
- `certs/*.pem` (private keys)

The installer generates these on the server with `600` / `700` permissions.

## Network

- Database ports are not published on `0.0.0.0`.
- DB web UIs are reachable only via Traefik (HTTPS) with passwords from `.env`.
- Enable `UFW`, `fail2ban`, and `APPLY_SSH_HARDENING` in production.

## Web panels (HTTPS edge)

Panels are published as `https://<service>.${DOMAIN}`. **Traefik Basic Auth** (extra password prompt before the app) is enabled **only** for:

- **Traefik dashboard** (`admin` + `TRAEFIK_DASHBOARD_PASSWORD`)
- **Doku** (`doku` + `DOKU_DASHBOARD_PASSWORD`)

All other HTTPS panels rely on **application login only** (or a first-visit setup wizard):

| Application login | Portainer, Semaphore, Duplicati, Uptime Kuma, Filebrowser, Deployer (if enabled), mongo-express, pgAdmin, Adminer |
| Not a browser UI | Registry (`docker login`), docker_auth (`auth.${DOMAIN}`) |

**What this means**

- HTTPS encrypts traffic but does **not** add a second gate on most panels — protect them with strong app passwords and disable unused services (`ENABLE_*=0` in `.env`).
- **First-visit setup** (Portainer, Duplicati, Uptime Kuma): complete admin onboarding immediately after install so an anonymous visitor cannot claim the instance.
- **Filebrowser** exposes only `FILEBROWSER_ROOT_PATH` on the host (default: `$STACK_ROOT/filebrowser/files`). Do **not** set it to `/` on production.
- Optional hardening (IP allowlist, Traefik middleware, VPN-only access) is **not** configured by default.

## Report a vulnerability

Do not open a public Issue with an exploit. Contact maintainers privately (email or GitHub Security Advisory once the repository is published).
