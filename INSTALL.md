# Setup Server Stack — Installation

**Русский:** [INSTALL.ru.md](INSTALL.ru.md)

Guide for first-time install: prerequisites, passwords, post-install checks, and day-2 operations.

---

## 1. What this stack does

One Linux VPS runs Docker containers for:

| Purpose | Service |
|---------|---------|
| HTTPS and subdomains | **Traefik** |
| Docker image storage | **Registry** + **docker_auth** (`docker login`) |
| Docker UI | **Portainer** |
| Scheduled image updates | **Watchtower** |
| CI / tasks | **Semaphore** |
| Docker disk usage | **Doku** |
| Backups | **Duplicati** |
| Uptime monitoring | **Uptime Kuma** |
| File manager | **Filebrowser** |
| Optional deploy app | **Deployer** (pre-built image via `DEPLOYER_IMAGE`) |
| Optional DBs + web UIs | Mongo, Postgres, MariaDB, MySQL, mongo-express, pgAdmin, Adminer |

All services use `https://service.your-domain`. Set **`DOMAIN`** once in `.env`.

---

## 2. Before you install

### 2.1 Server

- **Linux** (Ubuntu/Debian) with **SSH** access.
- **Docker** and **Docker Compose v2** (`docker compose`). Set **`INSTALL_DOCKER=1`** in `.env` to install Docker from the official repo.
- With **`ENABLE_REGISTRY=1`** (default), the installer installs **`gettext-base`** on Debian/Ubuntu if `envsubst` is missing (registry `auth_config.yml` generation).
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
| `ACME_EMAIL` | `you@example.com` | Let's Encrypt |

Empty passwords are filled on first run into **`.setup-server-stack-secrets`**.

```env
DOMAIN=example.com
ACME_EMAIL=admin@example.com
STACK_ROOT=.
TZ=Europe/Helsinki
```

`STACK_ROOT=.` keeps data next to `docker-compose.yml`. Use an absolute path if you prefer.

### Step 4. Run the installer

```bash
chmod +x setup-server-stack.sh install.sh
sudo bash ./setup-server-stack.sh
```

On first run the script:

- creates Docker network **`proxynet`**;
- prepares `traefik/acme.json`, registry keys, configs;
- generates random passwords → **`.setup-server-stack-secrets`**;
- builds Traefik htpasswd (dashboard + Doku);
- generates JWT keys and **`auth_config.yml`**;
- writes **`$STACK_ROOT/.env.stack`** (chmod 600);
- runs **`docker compose --env-file .env.stack up -d`**.

Re-run without flags: does **not** remove volumes or overwrite existing secrets / `acme.json`.

To regenerate secrets (changes passwords — update clients):

```bash
sudo bash ./setup-server-stack.sh --force-secrets
```

### Step 5. Read generated passwords

```bash
cat .setup-server-stack-secrets
```

Includes `TRAEFIK_DASHBOARD_PASSWORD`, `REGISTRY_PASSWORD`, DB passwords, etc. **Do not commit** this file.

---

## 4. Before and after one command

| Before | After success |
|--------|---------------|
| No `proxynet` | Network created |
| No / empty `acme.json` | File created (chmod 600) |
| No secrets file | `.setup-server-stack-secrets` with passwords |
| Containers down | `docker compose up -d` running |

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
| Registry | `https://registry.example.com` | `docker login registry.example.com` |
| Portainer | `https://portainer.example.com` | First visit — create admin in UI |
| Semaphore | `https://semaphore.example.com` | `SEMAPHORE_ADMIN` + password from secrets |
| Doku | `https://doku.example.com` | `doku` + `DOKU_DASHBOARD_PASSWORD` |
| Duplicati | `https://duplicati.example.com` | Set password on first visit; backup jobs configured in UI (see §8) |
| Uptime Kuma | `https://kuma.example.com` | Create admin on first visit |
| Filebrowser | `https://filebrowser.example.com` | `admin`; initial password in `docker logs filebrowser`; rw host path from `FILEBROWSER_ROOT_PATH` (empty = `$STACK_ROOT/filebrowser/files`) |

**Filebrowser:** by default only `$STACK_ROOT/filebrowser/files` is exposed (not the whole server). Setting `FILEBROWSER_ROOT_PATH=/` mounts the entire host — avoid on production. See [SECURITY.md](SECURITY.md#web-panels-https-edge).
| Deployer | `https://deployer.example.com` | `DEPLOYER_ADMIN_USER` / `DEPLOYER_ADMIN_PASSWORD` |

`auth.example.com` is **docker_auth** (Docker token protocol, not a human panel).

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

URLs: `mongo-express`, `pgadmin`, `adminer` subdomains. Passwords in `.env` / `.setup-server-stack-secrets`.

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

(Volumes remain unless `-v`.)

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

Deployer is a **separate** open-source product ([github.com/commerce-deployer/deployer](https://github.com/commerce-deployer/deployer)). Its image is built by CI and published to Docker Hub or GHCR — the stack only **pulls** it, like Traefik or Portainer.

```env
ENABLE_DEPLOYER=1
DEPLOYER_IMAGE=docker.io/commerce-deployer/deployer:latest
```

Replace the image tag when pinning a release (e.g. `:v1.2.0`). For a **private** image, set `DEPLOYER_IMAGE_REGISTRY_HOST`, `DEPLOYER_IMAGE_REGISTRY_USER`, and `DEPLOYER_IMAGE_REGISTRY_PASSWORD` before install.

When the stack registry is enabled, Deployer uses `registry.${DOMAIN}` to deploy application images.

Pull policy inside Deployer (for app images): `DEPLOYER_DEFAULT_PULL_POLICY=always` | `ifNotPresent` with retries (`DEPLOYER_PULL_MAX_ATTEMPTS`).

### Duplicati (backups)

The stack starts the **Duplicati web UI** and stores its settings in the Docker volume `duplicati_config`. It does **not** configure backup jobs for you:

- **Sources** — which files or volumes to back up
- **Destination** — S3, Backblaze, SFTP, another server, etc.
- **Schedule** — when jobs run

After install, open `https://duplicati.${DOMAIN}`, set a password, then create a backup job in the UI.

By default Duplicati only sees its own `/config` inside the container. To back up stack data (e.g. `${STACK_ROOT}`, Docker named volumes), add **read-only** bind mounts to the `duplicati` service in `docker-compose.yml` (examples are commented there), then `docker compose ... up -d`. Paths must be readable by `DUP_PUID` / `DUP_PGID` (default `1000`).

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
| `CREATE_ADMIN_USER` | `1` | Sudo user `ADMIN_USERNAME` with docker group |
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
3. **Registry login fails** — check `REGISTRY_USER` / `REGISTRY_PASSWORD` in `.env` and secrets; re-run `sudo bash ./setup-server-stack.sh`; verify `config/docker_auth/auth_config.yml` and `certs/` (generated by script). Client: `docker login registry.${DOMAIN}`.
4. **Forgot Traefik or Doku password** — `.setup-server-stack-secrets` or `--force-secrets` (regenerates all secrets).

---

## 11. Paths and volumes

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | Stack and Compose profiles |
| `.env` / `.env.stack` | Settings; `.env.stack` built by script (chmod 600) |
| `.setup-server-stack-secrets` | Auto-generated passwords (not in git) |
| `${STACK_ROOT}/traefik/acme.json` | Let's Encrypt certificates |
| `${STACK_ROOT}/certs/registry-token*.pem` | JWT signing for registry + docker_auth |
| `${STACK_ROOT}/config/traefik/htpasswd*` | Basic Auth for Traefik / Doku |
| `${STACK_ROOT}/config/pgadmin/` | pgAdmin auto-connect (if enabled) |

**Watchtower** skips Traefik and databases. **Duplicati** — only the UI + `duplicati_config` volume from compose; sources, destination, and schedule are set in the Duplicati UI (§8).

**Acceptance checklist:** DNS → HTTPS on panels → `docker login registry.${DOMAIN}` → DB ports not on `0.0.0.0` → re-run installer does not break `acme.json` without `--force-secrets`.
