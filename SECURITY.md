# Security

**Русский:** [SECURITY.ru.md](SECURITY.ru.md)

## Secrets

**Never commit:**

- `.env`, `.env.stack`, `.secrets`, `secrets/`
- `traefik/acme.json`
- `config/traefik/htpasswd*`, `config/docker_auth/auth_config.yml`, `config/docker/config.json`, `config/pgadmin/*`
- `certs/*.pem` (private keys)

The installer generates these on the server with `600` / `700` permissions.

## Network

- Database ports are not published on `0.0.0.0`.
- DB web UIs are reachable only via Traefik (HTTPS) with passwords from `.env`.
- Enable `UFW`, `fail2ban`, and `APPLY_SSH_HARDENING` in production.

## Web panels (HTTPS edge)

Panels are published as `https://<service>.${DOMAIN}` (NGINX uses `DOMAIN` or `NGINX_HOST`). See [INSTALL.md](INSTALL.md) §1 for **what each service is for**; this section covers **how they are protected**.

**Traefik Basic Auth** (extra password before the app) — only:

- **Traefik dashboard** (`admin` + `TRAEFIK_DASHBOARD_PASSWORD`)
- **Doku** (`STACK_ADMIN_USER` + `DOKU_DASHBOARD_PASSWORD`; `DOKU_DASHBOARD_USER` can override)

All other HTTPS panels rely on **application login only** (or a first-visit setup wizard):

| Application login | Portainer, Semaphore, Gitea (`GITEA_ADMIN` + `GITEA_ADMIN_PASSWORD`), Duplicati (`DUPLICATI_WEBSERVICE_PASSWORD`), Uptime Kuma, Beszel (`STACK_ADMIN_EMAIL` + `BESZEL_USER_PASSWORD`), Filebrowser (`STACK_ADMIN_USER` + `FILEBROWSER_PASSWORD`; `FILEBROWSER_USER` can override), Deployer (if enabled), mongo-express, pgAdmin, Adminer |
| Elevated container access | **Gitea Actions runner** (`ENABLE_GITEA_RUNNER=1`) mounts `/var/run/docker.sock` so workflow jobs can build images — treat like a CI worker with host Docker access |
| No application login | **gocron** (`ENABLE_GOCRON=1`) — anyone who can reach `https://gocron.${DOMAIN}` can view and edit cron jobs; restrict by network, VPN, or Traefik middleware |
| Not a browser UI | Registry (`docker login`), Registry auth (`registry-auth.${DOMAIN}`) |

**What this means**

- HTTPS encrypts traffic but does **not** add a second gate on most panels — protect them with strong app passwords and leave unused services unset (or set `ENABLE_*=0`).
- `TRAEFIK_CERT_MODE=auto` can load private keys from `certs/<host>/privkey.pem`; real host folders are ignored by git and must be treated like secrets.
- `TRAEFIK_CERT_MODE=staging` and `TRAEFIK_CERT_MODE=selfsigned` are QA modes. They keep HTTPS routing, but browsers will not trust the certificate.
- **First-visit setup** (Portainer, Uptime Kuma): complete admin onboarding immediately after install so an anonymous visitor cannot claim the instance.
- **Filebrowser** exposes only `FILEBROWSER_ROOT_PATH` on the host (default: `/opt` — stack under `/opt/setup-server-stack` and Deployer data under `/opt/deploy-data`). Do **not** set it to `/` on production.
- **NGINX static site** publishes everything under `$STACK_ROOT/nginx/public`. Do not put secrets, backups, `.env` files, or private keys there.
- Optional hardening (IP allowlist, Traefik middleware, VPN-only access) is **not** configured by default.

## Report a vulnerability

Do not open a public Issue with an exploit. Contact maintainers privately (email or GitHub Security Advisory once the repository is published).
