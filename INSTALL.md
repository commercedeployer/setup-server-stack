# Setup Server Stack — Installation

**Русский:** [INSTALL.ru.md](INSTALL.ru.md)

Guide for first-time install: prerequisites, passwords, post-install checks, and day-2 operations.

---

## 1. What this stack does

One Linux VPS runs Docker containers for:

| Purpose | Service |
|---------|---------|
| HTTPS and subdomains | **Traefik** |
| Docker image storage | **Registry** + **Registry auth** (`docker login`) |
| Docker UI | **Portainer** |
| Scheduled image updates | **Watchtower** |
| CI / tasks | **Semaphore** |
| Docker disk usage | **Doku** |
| Backups | **Duplicati** |
| Uptime monitoring | **Uptime Kuma** |
| Server metrics | **Beszel** (local agent auto-registered) |
| File manager | **Filebrowser** |
| Optional deploy app | **Deployer** (pre-built image via `DEPLOYER_IMAGE`) |
| Optional DBs + web UIs | Mongo, Postgres, MariaDB, MySQL, mongo-express, pgAdmin, Adminer |

All services use `https://service.your-domain`. Set **`DOMAIN`** once in `.env`.

---

## 2. Before you install

### 2.1 Server

- **Linux** (Ubuntu/Debian) with **SSH** access.
- **Docker** and **Docker Compose v2** (`docker compose`). Set **`INSTALL_DOCKER=1`** in `.env` to install Docker from the official repo.
- With **`ENABLE_REGISTRY=1`**, the installer installs **`gettext-base`** on Debian/Ubuntu if `envsubst` is missing (registry `auth_config.yml` generation).
- Run **`sudo bash ./setup-server-stack.sh`** on the VPS (not on Windows as the production host). **`./install.sh`** is a thin wrapper.

### 2.2 Domain and DNS

1. Use a domain (e.g. `example.com`).
2. Create DNS records:
   - one **A** record for `*.example.com` → VPS public IP, or
   - separate **A** records per subdomain (`traefik`, `registry`, `portainer`, …).

Without DNS pointing to the server, **Let's Encrypt** will not issue certificates.

### 2.3 ACME email

Set a real **`ACME_EMAIL`** in `.env` for Let's Encrypt. The installer rejects placeholder values from `.env.example` (`example.com`, `you@example.com`).

### 2.4 Copy files to the server

Copy the full **`setup-server-stack`** directory (`docker-compose.yml`, scripts, `lib/`, `.env.example`, `config/`, …).

### 2.5 Remote install from Windows

Install **OpenSSH Client**, open PowerShell in `setup-server-stack`:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
.\deploy-from-windows.ps1
```

Or: `.\deploy-from-windows.ps1 -RemoteHost 203.0.113.50`

| Parameter | Meaning |
|-----------|---------|
| `-RemoteHost` | IP or DNS if `DOMAIN` is not set in local `.env` |
| `-RemotePath` | Absolute path on VPS (default `/opt/setup-server-stack` or `SETUP_SERVER_STACK_ROOT`) |
| `-SshPort` / `SSH_PORT` | SSH port if not 22 |
| `-SshIdentityFile` | SSH key path (no password prompts) |
| `-RootPassword` | `SecureString` — password once without interactive prompt (optional) |
| `-SkipInstall` | Copy only, do not run installer |
| `-ForceSecrets` | Pass `--force-secrets` on the server |

**Important:** create local **`cp .env.example .env`** with at least **`DOMAIN`** and **`ACME_EMAIL`** before running — otherwise the template goes to the server unchanged.

On success, **`deploy-from-windows.ps1`** downloads server **`.secrets`** to local **`secrets/<timestamp>`**, copies newly exported TLS cert files back to local **`certs/<host>/`** without overwriting existing files, then applies SSH hardening on the server.

Connects as **`root`**. Password is asked **once** at the start (SSH multiplexing); or use **`-SshIdentityFile`** / **`-RootPassword`**.

---

## 3. Install steps

### Step 1. SSH to the server

```bash
ssh ubuntu@203.0.113.50
```

### Step 2. Enter the stack directory

```bash
cd /opt/setup-server-stack
```

### Step 3. Create `.env`

```bash
cp .env.example .env
nano .env
```

**Minimum manual values:**

| Variable | Example | Purpose |
|----------|---------|---------|
| `DOMAIN` | `example.com` | All `*.example.com` subdomains |
| `ACME_EMAIL` | `you@example.com` | Let's Encrypt (`letsencrypt` / `staging` modes) |
| `STACK_ADMIN_USER` | `admin` | Default admin login for stack services |
| `STACK_ADMIN_EMAIL` | `admin@example.com` | Default admin email for panels that require email login |

Services are opt-in: a service is installed only when its `ENABLE_*=1` flag is present. Missing `ENABLE_*` means `0`. `ENABLE_DOCKER_AUTH` follows `ENABLE_REGISTRY` unless set explicitly.

`.env.example` is intentionally a full QA/example stack with all supported services enabled. For production, keep only the `ENABLE_*=1` lines you need.

Empty passwords are filled on first run into **`.secrets`**.

```env
DOMAIN=example.com
ACME_EMAIL=admin@example.com
STACK_ADMIN_USER=admin
STACK_ADMIN_EMAIL=admin@example.com
TRAEFIK_CERT_MODE=auto
STACK_ROOT=.
TZ=Europe/Helsinki
```

`STACK_ROOT=.` keeps data next to `docker-compose.yml`. Use an absolute path if you prefer.

**TLS certificate modes:**

| `TRAEFIK_CERT_MODE` | Use for | Browser trust |
|---------------------|---------|---------------|
| `auto` | Default production mode | Custom cert from `certs/<host>/` if present, otherwise trusted Let's Encrypt if DNS/ports/rate limits are OK |
| `provided` | Bring your own certs only | Trusted only if your cert/key pair is valid for the exact host |
| `letsencrypt` | Force production Let's Encrypt | Trusted if DNS/ports/rate limits are OK; custom certs are ignored by routing |
| `staging` | Reinstall-heavy QA | Test Let's Encrypt cert; browser warning is expected |
| `selfsigned` | QA without custom certs or Let's Encrypt | Traefik default/self-signed TLS; browser warning is expected |

`ACME_EMAIL` is required for `auto`, `letsencrypt`, and `staging`; `provided` and `selfsigned` do not contact Let's Encrypt.

Custom certificates are optional. Put them in this form before running the installer:

```text
certs/<host>/fullchain.pem
certs/<host>/privkey.pem
```

Example: `certs/portainer.example.com/fullchain.pem` + `certs/portainer.example.com/privkey.pem`. On the server this directory is always `${STACK_ROOT}/certs`; the path is intentionally not configurable in `.env`. The `<host>` folder name must be the exact FQDN used by the service. Private keys are ignored by git; Windows deploy uploads host folders from `certs/` to the server.

When production Let's Encrypt succeeds in `auto` or `letsencrypt` mode, the installer exports issued certificates back into the same structure (`certs/<host>/fullchain.pem` + `privkey.pem`) on the server. Existing files are kept and are not overwritten.

Production and staging ACME storage files are separate (`acme.json` / `acme-staging.json`), so QA certificates do not pollute production checks.

After `docker compose up`, the installer checks every enabled HTTPS host and prints `TLS OK` or `TLS WARN`. This matters because Let's Encrypt can issue some host certificates and then reject the rest due to DNS, ports, or rate limits.

**NGINX static site:**

Set `ENABLE_NGINX=1` to publish a static site through Traefik. By default it uses the root domain:

```env
ENABLE_NGINX=1
# NGINX_HOST=www.example.com  # optional; empty = DOMAIN
```

Runtime files always live in `${STACK_ROOT}/nginx/public/`. The repo ships a default page in `setup-server-stack/nginx/public/`; on first install only, when the runtime folder is empty, it is used as the seed. On every re-run, if the folder already contains any file, the installer keeps the existing site and does not overwrite it.

### Step 4. Run the installer

```bash
chmod +x setup-server-stack.sh install.sh
sudo bash ./setup-server-stack.sh
```

On first run the script:

- creates Docker network **`proxynet`**;
- prepares `traefik/acme.json`, registry keys, configs;
- generates random passwords → **`.secrets`**;
- builds Traefik htpasswd (dashboard + Doku);
- generates JWT keys and **`auth_config.yml`**;
- initializes `$STACK_ROOT/nginx/public` from `nginx/public/` only when `ENABLE_NGINX=1` and the runtime folder is empty;
- writes **`$STACK_ROOT/.env.stack`** (chmod 600);
- runs **`docker compose --env-file .env.stack up -d`**;
- checks TLS certificates per enabled HTTPS host and prints clear `TLS OK` / `TLS WARN` lines.

Re-run without flags: does **not** remove volumes, overwrite existing secrets / `acme.json`, or replace files already present in `$STACK_ROOT/nginx/public`.

To regenerate secrets (changes passwords — update clients):

```bash
sudo bash ./setup-server-stack.sh --force-secrets
```

### Step 5. Read generated passwords

```bash
cat .secrets
```

Includes `TRAEFIK_DASHBOARD_PASSWORD`, `REGISTRY_PASSWORD`, `REGISTRY_PULL_PASSWORD`, DB passwords, etc. **Do not commit** this file. After **`deploy-from-windows.ps1`**, a local copy is saved as **`secrets/<timestamp>`**.

---

## 4. Before and after one command

| Before | After success |
|--------|---------------|
| No `proxynet` | Network created |
| No / empty `acme.json` | File created (chmod 600) |
| No secrets file | `.secrets` with passwords |
| Containers down | `docker compose up -d` running |
| Unknown TLS state | Per-host `TLS OK` / `TLS WARN` diagnostics printed |

```bash
docker compose -f docker-compose.yml --env-file .env.stack ps
```

---

## 5. Exposed ports

On the VPS host:

- **22** — SSH (your firewall);
- **80** — HTTP (redirect + ACME);
- **443** — HTTPS.

DB ports are **not** bound to `0.0.0.0` (see §7).

---

## 6. URLs after install

Replace `example.com` with your **`DOMAIN`**:

| Service | URL | Login |
|---------|-----|-------|
| Traefik | `https://traefik.example.com` | `admin` + `TRAEFIK_DASHBOARD_PASSWORD` |
| Registry | `https://registry.example.com` | push: `STACK_ADMIN_USER` / `REGISTRY_PASSWORD`; pull-only: `REGISTRY_PULL_USER` / `REGISTRY_PULL_PASSWORD` |
| Portainer | `https://portainer.example.com` | First visit — create admin in UI; secrets marker: `PORTAINER_ADMIN_PASSWORD=SET_ON_FIRST_LOGIN` |
| Semaphore | `https://semaphore.example.com` | `STACK_ADMIN_USER` + `SEMAPHORE_ADMIN_PASSWORD` |
| Doku | `https://doku.example.com` | `STACK_ADMIN_USER` + `DOKU_DASHBOARD_PASSWORD` |
| Duplicati | `https://duplicati.example.com` | Password: `DUPLICATI_WEBSERVICE_PASSWORD` from secrets; backup jobs configured in UI (see §8) |
| gocron | `https://gocron.example.com` | No built-in login — HTTPS edge only; jobs in UI or `config.yaml` (see §8) |
| Uptime Kuma | `https://kuma.example.com` | Create admin on first visit; secrets marker: `UPTIME_KUMA_ADMIN_PASSWORD=SET_ON_FIRST_LOGIN` |
| Beszel | `https://beszel.example.com` | Login `STACK_ADMIN_EMAIL` + `BESZEL_USER_PASSWORD` from secrets; this server is auto-registered as a monitored system (no manual "Add System") |
| Filebrowser | `https://filebrowser.example.com` | `STACK_ADMIN_USER` + `FILEBROWSER_PASSWORD`; rw host path from `FILEBROWSER_ROOT_PATH` (empty = `$STACK_ROOT/filebrowser/files`) |
| Deployer | `https://deployer.example.com` | `DEPLOYER_AUTH_MODE=dual` by default: UI uses `STACK_ADMIN_USER` / `DEPLOYER_ADMIN_PASSWORD`; API uses `DEPLOYER_API_KEY` |

**Filebrowser:** by default only `$STACK_ROOT/filebrowser/files` is exposed (not the whole server). Setting `FILEBROWSER_ROOT_PATH=/` mounts the entire host — avoid on production. See [SECURITY.md](SECURITY.md#web-panels-https-edge).

`registry-auth.example.com` is **Registry auth** (Docker token protocol, powered by `docker_auth`; not a human panel).

**Deployer auth modes:** `dual` = UI session and API key (default), `api` = deploy API requires `x-api-key`, `ui` = web session only and no API key is generated.

**Security:** only **Traefik** and **Doku** use Traefik Basic Auth. Other panels in the table rely on app login or first-visit setup — see [SECURITY.md](SECURITY.md#web-panels-https-edge).

---

## 7. Optional databases

In `.env`:

```env
ENABLE_MONGO=1
ENABLE_POSTGRES=1
ENABLE_MARIADB=1
ENABLE_MYSQL=1
ENABLE_MONGO_EXPRESS=1
ENABLE_PGADMIN=1
ENABLE_ADMINER=1
```

Rules:

- `ENABLE_MONGO_EXPRESS=1` requires **`ENABLE_MONGO=1`**;
- `ENABLE_PGADMIN=1` requires **`ENABLE_POSTGRES=1`** (Postgres pre-linked in pgAdmin);
- `ENABLE_ADMINER=1` requires at least one DB enabled.

Re-run `sudo bash ./setup-server-stack.sh` or:

```bash
export COMPOSE_PROFILES=mongo,postgres,mariadb,mysql,mongo-express,pgadmin,adminer
docker compose --env-file .env.stack -f docker-compose.yml up -d
```

URLs: `mongo-express`, `pgadmin`, `adminer` subdomains. Passwords in `.env` / `.secrets`.

**Remote app on another VPS:** prefer HTTPS API on this host; if direct DB access is required, restrict UFW to the app server IP only. For admins: use web UIs or SSH tunnel (`ssh -N -L 27018:127.0.0.1:27017 user@vps`).

---

## 8. Day-2 operations

### Update after `.env` changes

```bash
sudo bash ./setup-server-stack.sh
```

Or:

```bash
docker compose --env-file .env.stack -f docker-compose.yml up -d
```

### Stop stack

```bash
docker compose --env-file .env.stack -f docker-compose.yml down
```

(Data is safe: it lives in `${STACK_ROOT}/<service>` bind mounts, so `down` — even with `-v` — does not delete it.)

### Push an image to your registry

```bash
docker tag my-app:latest registry.example.com/my-app:latest
docker login registry.example.com
docker push registry.example.com/my-app:latest
```

### Seed images on install

```env
REGISTRY_SEED_IMAGES=myapp:latest,registry.remote.tld/acme/api:1.4;redis:7
```

Empty list skips the step. Retries: `REGISTRY_OPERATION_RETRIES` (default 3) with exponential backoff.

### Extra registries at install

```env
EXTRA_REGISTRY_COUNT=2
EXTRA_REGISTRY_1_HOST=registry.remote.tld
EXTRA_REGISTRY_1_USER=myuser
EXTRA_REGISTRY_1_PASSWORD=token1
```

Logins run at install; credentials go to `config/docker/config.json` (Watchtower) and Deployer as `REGISTRY_CREDENTIALS_JSON`.

### Deployer

Deployer is a **separate** open-source product ([github.com/commercedeployer/deployer](https://github.com/commercedeployer/deployer)). Its image is built by CI and published to **Docker Hub** and **GHCR** — the stack only **pulls** it, like Traefik or Portainer.

**Published images (public):**

| Registry | `DEPLOYER_IMAGE` | Verify before install |
|----------|------------------|------------------------|
| Docker Hub (recommended) | `commercedeployer/deployer:latest` | `docker pull commercedeployer/deployer:latest` |
| GHCR | `ghcr.io/commercedeployer/deployer:latest` | `docker pull ghcr.io/commercedeployer/deployer:latest` |

```env
ENABLE_DEPLOYER=1
DEPLOYER_IMAGE=commercedeployer/deployer:latest
```

Docker Hub: [hub.docker.com/r/commercedeployer/deployer](https://hub.docker.com/r/commercedeployer/deployer). GHCR uses the same org: `ghcr.io/commercedeployer/deployer`.

Replace `:latest` with a release tag (e.g. `:v1.2.0`) in production. For a **private** image, set `DEPLOYER_IMAGE_REGISTRY_HOST`, `DEPLOYER_IMAGE_REGISTRY_USER`, and `DEPLOYER_IMAGE_REGISTRY_PASSWORD` before install.

When the stack registry is enabled, Deployer uses `registry.${DOMAIN}` to deploy application images.

Pull policy inside Deployer (for app images): `DEPLOYER_DEFAULT_PULL_POLICY=always` | `ifNotPresent` with retries (`DEPLOYER_PULL_MAX_ATTEMPTS`).

**Provision tools** (inside the Deployer **container**, not on Ubuntu): `DEPLOYER_SOFTWARE` in `.env` — comma-separated keys, default `bash,curl`. `node` is always present. For Postgres tenant templates (`umami-pg`) add `psql`, e.g. `bash,curl,psql`. Full list in `.env.example` § Deployer.

**MCP / Cursor:** issue keys in Deployer UI (**MCP / AI**). `DEPLOYER_PUBLIC_BASE_URL` defaults to `https://deployer.${DOMAIN}` in compose (override in `.env` if needed). Key hashes use `DEPLOYER_SESSION_SECRET` — no separate MCP pepper or enable flag. Optional **`DEPLOYER_MCP_TOOLS_DENY`** — comma-separated MCP tool names to block on this host.

**Multi-node deployer pools** use `volume_policy: replicate` by default in Commerce: each node keeps local data under `DEPLOY_BASE_PATH`; Commerce orchestrates `POST /api/volumes/:name/sync` between deployer nodes (bytes never pass through Commerce).

### Duplicati (backups)

The stack starts the **Duplicati web UI** and stores its settings in `${STACK_ROOT}/duplicati`. It does **not** configure backup jobs for you:

- **Sources** — which files or volumes to back up
- **Destination** — S3, Backblaze, SFTP, another server, etc.
- **Schedule** — when jobs run

After install, open `https://duplicati.${DOMAIN}`, log in with `DUPLICATI_WEBSERVICE_PASSWORD` from secrets, then create a backup job in the UI.

By default Duplicati only sees its own `/config` inside the container. Since all stack data lives under `${STACK_ROOT}`, add a single **read-only** bind mount of `${STACK_ROOT}` to the `duplicati` service in `docker-compose.yml` (an example is commented there), then `docker compose ... up -d`. Paths must be readable by `DUP_PUID` / `DUP_PGID` (default `1000`).

### gocron (cron + backup utilities)

Optional: **`ENABLE_GOCRON=1`**. Web UI cron scheduler ([flohoss/gocron](https://github.com/flohoss/gocron)) for shell jobs — rsync, restic, rclone, etc.

The installer writes `${GOCRON_DATA_PATH}/config.yaml` (default `${STACK_ROOT}/gocron/config.yaml`):

- **`GOCRON_SOFTWARE`** — comma- or semicolon-separated tools (default `rsync`). Allowed: `apprise`, `borgbackup`, `docker`, `git`, `podman`, `rclone`, `rdiff-backup`, `restic`, `rsync`, `logrotate`, `sqlite3`, `kopia`. The container installs them on start. On re-run, only the `software` block is refreshed; existing `jobs:` are kept (delete `config.yaml` to start fresh).

Compose mounts `${GOCRON_DATA_PATH}:/app/config` and **`${STACK_ROOT}:/source/stack:ro`** — jobs can back up the whole stack, e.g. `rsync -a /source/stack/ user@backup:/backups/stack/`.

Open `https://gocron.${DOMAIN}` after install. **No application login** — protect via network/Traefik; see [SECURITY.md](SECURITY.md). Duplicati and gocron complement each other: Duplicati for click-through backups, gocron for YAML and custom commands.

### Validate compose config

Locally (after install) or in CI fixtures:

```bash
docker compose --env-file .env.stack -f docker-compose.yml config
```

Contributor check (no VPS): `bash tests/run-ci.sh` — uses `tests/fixtures/*.env.stack`.

---

## 9. Host hardening (from `.env`)

| Variable | Default | Effect |
|----------|---------|--------|
| `CREATE_ADMIN_USER` | `1` | Sudo user `STACK_ADMIN_USER` with docker group (`ADMIN_USERNAME` can override it) |
| `ADMIN_SUDO_NOPASSWD` | `1` | NOPASSWD sudo for admin user |
| `APPLY_SSH_HARDENING` | `1` | Key-only SSH, no root/password login |
| `UFW_ENABLE` | `1` | Open SSH, 80, 443 |
| `INSTALL_FAIL2BAN` | `1` | fail2ban on Debian/Ubuntu |
| `INSTALL_UNATTENDED_UPGRADES` | `1` | Security updates |
| `SSH_PUBLIC_KEY` | — | Key for admin + SSH hardening |

---

## 10. Troubleshooting

1. **No HTTPS padlock** — wait for DNS, check `ACME_EMAIL`, ports 80/443 reachable from the internet.
2. **502 / no response** — `docker compose ... ps`, `docker logs <container>`.
3. **Registry login fails** — check `STACK_ADMIN_USER` / `REGISTRY_PASSWORD` in `.env` and secrets; re-run `sudo bash ./setup-server-stack.sh`; verify `config/docker_auth/auth_config.yml` and `certs/` (generated by script). Client: `docker login registry.${DOMAIN}`.
4. **Forgot Traefik or Doku password** — `.secrets` or `--force-secrets` (regenerates all secrets).
5. **Let's Encrypt rate limit** — install can finish with `TLS WARN` and a browser warning for some hosts. The installer prints `TLS RATE LIMIT` and `retry after ... UTC` when Traefik exposes that value. After the cooldown, retry certificate issuance without rebuilding or stopping the stack:

```bash
cd /opt/setup-server-stack
docker compose --env-file .env.stack -f docker-compose.yml restart traefik
```

Already issued certificates stay in `${STACK_ROOT}/traefik/acme.json`; do not run `down -v` and do not delete volumes just to retry TLS.

---

## 11. Paths and volumes

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | Stack and Compose profiles |
| `.env` / `.env.stack` | Settings; `.env.stack` built by script (chmod 600) |
| `.secrets` | Auto-generated passwords (not in git) |
| `${STACK_ROOT}/traefik/acme.json` | Let's Encrypt certificates |
| `${STACK_ROOT}/certs/<host>/` | Custom TLS certificates and exported production Let's Encrypt certs (`privkey.pem` is secret) |
| `${STACK_ROOT}/certs/registry-token*.pem` | JWT signing for Registry + Registry auth |
| `${STACK_ROOT}/nginx/public/` | Static site files served by NGINX when `ENABLE_NGINX=1` |
| `${STACK_ROOT}/config/traefik/htpasswd*` | Basic Auth for Traefik / Doku |
| `${STACK_ROOT}/config/pgadmin/` | pgAdmin auto-connect (if enabled) |
| `${STACK_ROOT}/<service>/` | Per-service persistent data (bind mounts): `registry`, `portainer`, `semaphore`, `duplicati`, `gocron`, `kuma`, `pgadmin`, `postgres`, `mongo`, `mariadb`, `mysql` |

All persistent state lives under `${STACK_ROOT}` as bind mounts (no Docker named volumes), so a single copy of `${STACK_ROOT}` is a full backup of the stack. The installer creates each `${STACK_ROOT}/<service>` only for enabled services and sets ownership where needed (pgAdmin `5050:5050`, Semaphore `1001:0`). To relocate one service's data (e.g. a database onto a separate disk), set `<SERVICE>_DATA_PATH` in `.env` (see `.env.example` section `[M]`); a path outside `${STACK_ROOT}` still works and is left untouched by the Windows deploy (it only writes inside `${STACK_ROOT}`), but it is not included when you back up by copying `${STACK_ROOT}` — back such a path up separately.

**Watchtower** skips Traefik and databases. **Duplicati** — only the UI + its `${STACK_ROOT}/duplicati` data from compose; sources, destination, and schedule are set in the Duplicati UI (§8).

**Acceptance checklist:** DNS → HTTPS on panels → `docker login registry.${DOMAIN}` → DB ports not on `0.0.0.0` → re-run installer does not break `acme.json` without `--force-secrets`.
