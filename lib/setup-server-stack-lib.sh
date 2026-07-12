# shellcheck shell=bash
# setup-server-stack library (sourced from setup-server-stack.sh; requires VERSION, SCRIPT_DIR).
# Do not run this file directly.
#
FORCE_SECRETS=0
SKIP_SSH_HARDENING=0
SSH_HARDENING_ONLY=0
ENV_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()  { echo -e "${CYAN}==>${NC} $*"; }

die() { echo "Error: $*" >&2; exit 1; }
err() { die "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command: $1"; }

RUN() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

retry_cmd() {
  local attempts="$1"
  shift
  local base_delay="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  local max_delay="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if (( i < attempts )); then
      local delay=$((base_delay * (2 ** (i - 1))))
      (( delay > max_delay )) && delay="$max_delay"
      warn "Retry ${i}/${attempts} failed: $* (next attempt in ${delay}s)"
      sleep "$delay"
    fi
  done
  return 1
}

retry_run() {
  local attempts="$1"
  shift
  retry_cmd "$attempts" RUN "$@"
}

docker_login_with_retry() {
  local host="$1" user="$2" pass="$3" attempts="$4"
  local base_delay="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  local max_delay="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if printf '%s' "$pass" | docker login "$host" -u "$user" --password-stdin; then
      return 0
    fi
    if (( i < attempts )); then
      local delay=$((base_delay * (2 ** (i - 1))))
      (( delay > max_delay )) && delay="$max_delay"
      warn "docker login ${host}: attempt ${i}/${attempts} failed, retrying in ${delay}s..."
      sleep "$delay"
    fi
  done
  return 1
}

normalize_registry_host() {
  local h="${1:-}"
  h="${h#http://}"
  h="${h#https://}"
  h="${h%/}"
  printf '%s' "$h"
}

collect_registry_watchtower_auth_entries() {
  local include_local="${1:-1}"
  local host user pass i

  if [[ "$include_local" == "1" ]] && registry_enabled; then
    host="registry.${DOMAIN}"
    if [ -n "${REGISTRY_PULL_USER:-}" ] && [ -n "${REGISTRY_PULL_PASSWORD:-}" ]; then
      user="${REGISTRY_PULL_USER}"
      pass="${REGISTRY_PULL_PASSWORD}"
    else
      user="${REGISTRY_USER:-}"
      pass="${REGISTRY_PASSWORD:-}"
    fi
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$pass" ] && printf '%s|%s|%s\n' "$host" "$user" "$pass"
  fi

  local count="${EXTRA_REGISTRY_COUNT:-0}"
  for ((i = 1; i <= count; i++)); do
    local host_var="EXTRA_REGISTRY_${i}_HOST"
    local user_var="EXTRA_REGISTRY_${i}_USER"
    local pass_var="EXTRA_REGISTRY_${i}_PASSWORD"
    host="$(normalize_registry_host "${!host_var:-}")"
    user="${!user_var:-}"
    pass="${!pass_var:-}"
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$pass" ] && printf '%s|%s|%s\n' "$host" "$user" "$pass"
  done
}

collect_registry_credentials_entries() {
  local include_local="${1:-1}"
  local host user pass i

  if [[ "$include_local" == "1" ]] && registry_enabled; then
    host="registry.${DOMAIN}"
    user="${REGISTRY_USER:-}"
    pass="${REGISTRY_PASSWORD:-}"
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$pass" ] && printf '%s|%s|%s\n' "$host" "$user" "$pass"
    if [ -n "${REGISTRY_PULL_USER:-}" ] && [ -n "${REGISTRY_PULL_PASSWORD:-}" ]; then
      printf '%s|%s|%s\n' "$host" "${REGISTRY_PULL_USER}" "${REGISTRY_PULL_PASSWORD}"
    fi
  fi

  local count="${EXTRA_REGISTRY_COUNT:-0}"
  for ((i = 1; i <= count; i++)); do
    local host_var="EXTRA_REGISTRY_${i}_HOST"
    local user_var="EXTRA_REGISTRY_${i}_USER"
    local pass_var="EXTRA_REGISTRY_${i}_PASSWORD"
    host="$(normalize_registry_host "${!host_var:-}")"
    user="${!user_var:-}"
    pass="${!pass_var:-}"
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$pass" ] && printf '%s|%s|%s\n' "$host" "$user" "$pass"
  done
}

# Back-compat alias for watchtower docker config (one auth per host → pull-only user when set).
collect_registry_auth_entries() {
  collect_registry_watchtower_auth_entries "$@"
}

build_registry_credentials_json() {
  if command -v python3 >/dev/null 2>&1; then
    collect_registry_credentials_entries 1 | python3 <<'PY'
import json
import sys

items = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split("|", 2)
    if len(parts) != 3:
        continue
    host, user, password = parts
    if host and user and password:
        items.append({"host": host, "user": user, "password": password})
print(json.dumps(items, ensure_ascii=False, separators=(",", ":")))
PY
    return 0
  fi

  # Fallback without python3: basic JSON escaping for quotes and slashes.
  local first=1 out="["
  while IFS='|' read -r host user pass; do
    [ -n "$host" ] || continue
    host=$(printf '%s' "$host" | sed 's/\\/\\\\/g; s/"/\\"/g')
    user=$(printf '%s' "$user" | sed 's/\\/\\\\/g; s/"/\\"/g')
    pass=$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')
    if (( first )); then
      first=0
    else
      out+=","
    fi
    out+="{\"host\":\"${host}\",\"user\":\"${user}\",\"password\":\"${pass}\"}"
  done < <(collect_registry_credentials_entries 1)
  out+="]"
  printf '%s' "$out"
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --force-secrets) FORCE_SECRETS=1 ;;
      --skip-ssh-hardening) SKIP_SSH_HARDENING=1 ;;
      --ssh-hardening-only) SSH_HARDENING_ONLY=1 ;;
      *)
        if [ -f "$arg" ]; then
          ENV_FILE="$arg"
        elif [[ "$arg" == -* ]]; then
          die "Unknown argument: $arg (allowed: --force-secrets, --skip-ssh-hardening, --ssh-hardening-only)"
        fi
        ;;
    esac
  done
}

# shellcheck source=docker-install.inc.sh
source "$SCRIPT_DIR/lib/docker-install.inc.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo &>/dev/null; then
    die "Root or sudo required."
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE — copy .env.example: cp .env.example .env and set DOMAIN and ACME_EMAIL"
  source_env_file_safely "$ENV_FILE"
  apply_stack_admin_defaults
  export STACK_ROOT
  STACK_ROOT=$(cd "$SCRIPT_DIR" && cd "${STACK_ROOT:-.}" && pwd)
  export STACK_ROOT
}

apply_stack_admin_defaults() {
  : "${STACK_ADMIN_USER:=admin}"
  : "${STACK_ADMIN_EMAIL:=${ACME_EMAIL:-admin@${DOMAIN:-example.com}}}"

  : "${REGISTRY_AUTH_TOKEN_ISSUER:=setup-server-registry}"
  : "${REGISTRY_USER:=$STACK_ADMIN_USER}"
  : "${SEMAPHORE_ADMIN:=$STACK_ADMIN_USER}"
  : "${SEMAPHORE_ADMIN_NAME:=$STACK_ADMIN_USER}"
  : "${SEMAPHORE_ADMIN_EMAIL:=$STACK_ADMIN_EMAIL}"
  : "${GITEA_ADMIN:=$STACK_ADMIN_USER}"
  : "${GITEA_ADMIN_EMAIL:=$STACK_ADMIN_EMAIL}"
  : "${GITEA_HOST:=gitea.${DOMAIN:-example.com}}"
  : "${GITEA_ROOT_URL:=https://${GITEA_HOST}/}"
  : "${GITEA_SSH_PORT:=2222}"
  : "${GITEA_RUNNER_INSTANCE_URL:=${GITEA_ROOT_URL%/}}"
  : "${GITEA_RUNNER_NAME:=stack-runner}"
  : "${DOKU_DASHBOARD_USER:=$STACK_ADMIN_USER}"
  : "${FILEBROWSER_USER:=$STACK_ADMIN_USER}"
  : "${BESZEL_USER_EMAIL:=$STACK_ADMIN_EMAIL}"
  : "${DEPLOYER_ADMIN_USER:=$STACK_ADMIN_USER}"
  : "${MONGO_ROOT_USER:=$STACK_ADMIN_USER}"
  : "${POSTGRES_USER:=$STACK_ADMIN_USER}"
  : "${POSTGRES_DB:=postgres}"
  # MariaDB/MySQL default to root-only; an app user/db is created only when the
  # operator sets *_USER together with *_DATABASE (see validate_enable_flags).
  : "${MONGO_EXPRESS_USER:=$STACK_ADMIN_USER}"
  : "${PGADMIN_EMAIL:=$STACK_ADMIN_EMAIL}"
  : "${ADMIN_USERNAME:=$STACK_ADMIN_USER}"
}

source_env_file_safely() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if command -v python3 &>/dev/null; then
    # Safe .env parsing: survives ! $ ` when invoked over ssh -t.
    set -a
    eval "$(ENV_FILE="$f" python3 <<'PY'
import os, re, shlex
path = os.environ["ENV_FILE"]
with open(path, "r", encoding="utf-8-sig") as f:
    for line in f:
        line = line.rstrip("\r\n")
        t = line.strip()
        if not t or t.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            continue
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        print(f"export {k}={shlex.quote(v)}")
PY
)"
    set +a
  else
    set +H 2>/dev/null || true
    set +o histexpand 2>/dev/null || true
    # shellcheck disable=SC1091
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
  fi
}

ensure_dirs() {
  mkdir -p "$STACK_ROOT/traefik" "$STACK_ROOT/certs" "$STACK_ROOT/config/traefik" \
    "$STACK_ROOT/config/docker_auth" "$STACK_ROOT/config/docker" \
    "$STACK_ROOT/config/pgadmin" \
    "$STACK_ROOT/filebrowser/database" "$STACK_ROOT/filebrowser/config" \
    "$STACK_ROOT/nginx/public"
  ensure_filebrowser_root_dir
  ensure_service_data_dirs
  RUN mkdir -p "${DEPLOY_BASE_PATH:-/opt/deploy-data}"
  if [[ "${ENABLE_DEPLOYER:-0}" == "1" ]]; then
    RUN mkdir -p "${DEPLOY_BASE_PATH:-/opt/deploy-data}/templates"
  fi
  chmod 700 "$STACK_ROOT/certs" 2>/dev/null || true
}

# Host path for a service's persistent data. Override with <SERVICE>_DATA_PATH
# (e.g. POSTGRES_DATA_PATH); default $STACK_ROOT/<service>.
svc_data_path() {
  local key="$1" var
  var="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')_DATA_PATH"
  printf '%s\n' "${!var:-$STACK_ROOT/$key}"
}

# Per-service persistent data as bind mounts (default $STACK_ROOT/<service>), so the
# whole stack (configs + state + databases) is backed up by copying one folder.
# Only directories for enabled services are created.
ensure_service_data_dirs() {
  local svc flag dir
  # Containers below fix data-dir ownership themselves (run as root or chown on start).
  for svc in \
    "registry:ENABLE_REGISTRY" \
    "portainer:ENABLE_PORTAINER" \
    "duplicati:ENABLE_DUPLICATI" \
    "gocron:ENABLE_GOCRON" \
    "kuma:ENABLE_UPTIME_KUMA" \
    "beszel:ENABLE_BESZEL" \
    "gitea:ENABLE_GITEA" \
    "mongo:ENABLE_MONGO" \
    "postgres:ENABLE_POSTGRES" \
    "mariadb:ENABLE_MARIADB" \
    "mysql:ENABLE_MYSQL"; do
    dir="${svc%%:*}"
    flag="${svc##*:}"
    [[ "${!flag:-0}" == "1" ]] && mkdir -p "$(svc_data_path "$dir")"
  done
  # These apps run as a fixed non-root uid and need matching ownership on bind mounts.
  if [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]]; then
    local sema_dir; sema_dir="$(svc_data_path semaphore)"
    mkdir -p "$sema_dir"
    chown -R 1001:0 "$sema_dir" 2>/dev/null || true
  fi
  if [[ "${ENABLE_GITEA:-0}" == "1" ]]; then
    local gitea_dir; gitea_dir="$(svc_data_path gitea)"
    mkdir -p "$gitea_dir"
    chown -R "${GITEA_PUID:-1000}:${GITEA_PGID:-1000}" "$gitea_dir" 2>/dev/null || true
  fi
  if [[ "${ENABLE_GITEA_RUNNER:-0}" == "1" ]]; then
    mkdir -p "$(gitea_runner_data_path)"
  fi
  if [[ "${ENABLE_PGADMIN:-0}" == "1" ]]; then
    local pgadmin_dir; pgadmin_dir="$(svc_data_path pgadmin)"
    mkdir -p "$pgadmin_dir"
    chown -R 5050:5050 "$pgadmin_dir" 2>/dev/null || true
  fi
  # Beszel agent: its data dir holds the fingerprint plus the KEY/TOKEN files the
  # installer writes. Pre-create empty secret files so the agent has them to read.
  if [[ "${ENABLE_BESZEL_AGENT:-0}" == "1" ]]; then
    local beszel_agent_dir; beszel_agent_dir="$(beszel_agent_data_path)"
    mkdir -p "$beszel_agent_dir"
    [[ -f "$beszel_agent_dir/agent.key" ]] || { : >"$beszel_agent_dir/agent.key"; chmod 600 "$beszel_agent_dir/agent.key"; }
    [[ -f "$beszel_agent_dir/agent.token" ]] || { : >"$beszel_agent_dir/agent.token"; chmod 600 "$beszel_agent_dir/agent.token"; }
  fi
}

# Host path for the Beszel agent data dir. svc_data_path cannot be used because
# the service name contains a hyphen (invalid in a shell variable name).
beszel_agent_data_path() {
  printf '%s\n' "${BESZEL_AGENT_DATA_PATH:-$STACK_ROOT/beszel-agent}"
}

gitea_runner_data_path() {
  printf '%s\n' "${GITEA_RUNNER_DATA_PATH:-$STACK_ROOT/gitea-runner}"
}

resolve_nginx_host() {
  if [[ -n "${NGINX_HOST:-}" ]]; then
    printf '%s\n' "$NGINX_HOST"
  else
    printf '%s\n' "${DOMAIN:-}"
  fi
}

resolve_nginx_public_path() {
  printf '%s/nginx/public\n' "$STACK_ROOT"
}

initialize_nginx_public_dir() {
  [[ "${ENABLE_NGINX:-0}" == "1" ]] || return 0

  local public_dir seed_dir
  public_dir="$(resolve_nginx_public_path)"
  seed_dir="$SCRIPT_DIR/nginx/public"

  mkdir -p "$public_dir"
  if find "$public_dir" -mindepth 1 -print -quit | grep -q .; then
    chmod -R u=rwX,go=rX "$public_dir"
    info "NGINX public dir already has files, keeping existing site: $public_dir"
    return 0
  fi

  if [[ -d "$seed_dir" && "$seed_dir" != "$public_dir" ]]; then
    cp -a "$seed_dir/." "$public_dir/"
    chmod -R u=rwX,go=rX "$public_dir"
    info "Initialized NGINX public dir with example files from nginx/public/: $public_dir"
  else
    cat >"$public_dir/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>setup-server-stack</title></head>
<body><h1>setup-server-stack static site is running</h1></body>
</html>
HTML
    chmod -R u=rwX,go=rX "$public_dir"
    warn "Missing seed nginx/public/index.html; wrote fallback NGINX index.html to $public_dir"
  fi
}

resolve_filebrowser_root_path() {
  if [ -z "${FILEBROWSER_ROOT_PATH:-}" ]; then
    # Default to /opt so both the stack (/opt/setup-server-stack) and Deployer
    # data (/opt/deploy-data) are visible under one root.
    FILEBROWSER_ROOT_PATH="/opt"
  fi
  export FILEBROWSER_ROOT_PATH
}

ensure_filebrowser_root_dir() {
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] || return 0
  resolve_filebrowser_root_path
  # /, /opt and the deploy root are shared, root-owned trees: never mkdir/chown them.
  if [ "$FILEBROWSER_ROOT_PATH" = "/" ] || [ "$FILEBROWSER_ROOT_PATH" = "/opt" ] || [ "$FILEBROWSER_ROOT_PATH" = "$STACK_ROOT" ]; then
    return 0
  fi
  RUN mkdir -p "$FILEBROWSER_ROOT_PATH"
  local puid="${FILEBROWSER_PUID:-0}"
  local pgid="${FILEBROWSER_PGID:-0}"
  RUN chown "$puid:$pgid" "$FILEBROWSER_ROOT_PATH" 2>/dev/null || true
}

warn_filebrowser_root_path() {
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] || return 0
  resolve_filebrowser_root_path
  if [ "$FILEBROWSER_ROOT_PATH" = "/" ]; then
    warn "FILEBROWSER_ROOT_PATH=/ exposes the entire host to Filebrowser (rw, runs as root). Use the default /opt (stack + deploy-data), or set a non-root FILEBROWSER_PUID/PGID to limit access."
  fi
}

touch_acme() {
  local f="${TRAEFIK_ACME_STORAGE_FILE:-$STACK_ROOT/traefik/acme.json}"
  mkdir -p "$(dirname "$f")"
  if [[ ! -f "$f" ]]; then
    install -m 600 /dev/null "$f" 2>/dev/null || { touch "$f" && chmod 600 "$f"; }
  fi
}

ensure_network() {
  if ! docker network inspect proxynet >/dev/null 2>&1; then
    docker network create proxynet
  fi
}

rand_hex() { openssl rand -hex "${1:-32}"; }

rand_base64() { openssl rand -base64 "${1:-32}" | tr -d '\n'; }

semaphore_access_key_encryption_valid() {
  local key="${1:-}"
  local decoded_bytes

  [[ -n "$key" ]] || return 1
  decoded_bytes=$(printf '%s' "$key" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d '[:space:]') || return 1

  case "$decoded_bytes" in
    16|24|32) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_deployer_auth_mode() {
  local raw="${DEPLOYER_AUTH_MODE:-dual}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    dual|both|ui+api|ui_api|ui-api) echo "dual" ;;
    api|api-only|api_only) echo "api" ;;
    ui|session|ui-only|ui_only) echo "ui" ;;
    *) return 1 ;;
  esac
}

deployer_auth_mode_uses_api_key() {
  local mode
  mode="$(resolve_deployer_auth_mode)" || return 1
  [[ "$mode" == "dual" || "$mode" == "api" ]]
}

ensure_htpasswd() {
  command -v htpasswd &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    step "Installing apache2-utils (htpasswd)"
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get -o DPkg::Lock::Timeout=300 update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq apache2-utils
  fi
  command -v htpasswd &>/dev/null || err "htpasswd required (apt install apache2-utils)."
}

ensure_envsubst() {
  command -v envsubst &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    step "Installing gettext-base (envsubst for registry auth config)"
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get -o DPkg::Lock::Timeout=300 update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq gettext-base
  fi
  command -v envsubst &>/dev/null || err "envsubst required (apt install gettext-base)."
}

htpasswd_bcrypt() {
  local user="$1" pass="$2"
  ensure_htpasswd
  htpasswd -nbB "$user" "$pass"
}

write_traefik_htpasswd() {
  local sec="$1"
  local f="$STACK_ROOT/config/traefik/htpasswd"
  if [[ -f "$f" ]] && [[ "$FORCE_SECRETS" -ne 1 ]]; then
    return 0
  fi
  local tp
  tp=$(rand_hex 16)
  mkdir -p "$STACK_ROOT/config/traefik"
  ensure_htpasswd
  htpasswd -nb admin "$tp" >"$f"
  chmod 600 "$f"
  grep -v '^TRAEFIK_DASHBOARD_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
  mv "${sec}.tmp" "$sec" 2>/dev/null || true
  echo "TRAEFIK_DASHBOARD_PASSWORD=$tp" >>"$sec"
}

write_doku_htpasswd() {
  local sec="$1"
  local f="$STACK_ROOT/config/traefik/htpasswd-doku"
  local du="${DOKU_DASHBOARD_USER:-${STACK_ADMIN_USER:-doku}}"
  local dp="${DOKU_DASHBOARD_PASSWORD:-}"
  if [[ -f "$f" ]] && [[ "$FORCE_SECRETS" -ne 1 ]] && grep -q "^${du}:" "$f" 2>/dev/null; then
    return 0
  fi
  if [[ -z "$dp" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
    dp=$(rand_hex 16)
  fi
  mkdir -p "$STACK_ROOT/config/traefik"
  ensure_htpasswd
  htpasswd -nb "$du" "$dp" >"$f"
  chmod 600 "$f"
  grep -v '^DOKU_DASHBOARD_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
  mv "${sec}.tmp" "$sec" 2>/dev/null || true
  echo "DOKU_DASHBOARD_PASSWORD=$dp" >>"$sec"
}

compose_project_name() {
  basename "$SCRIPT_DIR"
}

existing_compose_state_detected() {
  command -v docker >/dev/null 2>&1 || return 1

  local project
  project="$(compose_project_name)"

  docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null | grep -q . && return 0
  docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null | grep -q . && return 0

  return 1
}

guard_existing_stack_requires_secrets() {
  [[ "$FORCE_SECRETS" -eq 1 ]] && return 0
  [[ -f "$SCRIPT_DIR/.secrets" ]] && return 0
  existing_compose_state_detected || return 0

  die "Existing Docker Compose state was detected for project $(compose_project_name), but $SCRIPT_DIR/.secrets is missing. Refusing to generate new secrets over an existing stack. Restore .secrets from your local secrets/<timestamp> backup, or fully reset the stack data before reinstalling."
}

write_stack_secrets() {
  local sec="$SCRIPT_DIR/.secrets"
  if [[ "$FORCE_SECRETS" -eq 1 ]] && [[ -f "$sec" ]]; then
    rm -f "$sec"
  fi
  if [[ ! -f "$sec" ]]; then
    umask 077
    : >"$sec"
    chmod 600 "$sec"
  fi

  source_env_file_safely "$ENV_FILE"
  source_env_file_safely "$sec"
  apply_stack_admin_defaults

  local changed=0

  if [[ "${ENABLE_PORTAINER:-0}" == "1" ]]; then
    if ! grep -q '^PORTAINER_ADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      grep -v '^PORTAINER_ADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
      mv "${sec}.tmp" "$sec" 2>/dev/null || true
      echo "PORTAINER_ADMIN_PASSWORD=SET_ON_FIRST_LOGIN" >>"$sec"
      changed=1
    fi
  fi

  if [[ "${ENABLE_UPTIME_KUMA:-0}" == "1" ]]; then
    if ! grep -q '^UPTIME_KUMA_ADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      grep -v '^UPTIME_KUMA_ADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
      mv "${sec}.tmp" "$sec" 2>/dev/null || true
      echo "UPTIME_KUMA_ADMIN_PASSWORD=SET_ON_FIRST_LOGIN" >>"$sec"
      changed=1
    fi
  fi

  if [[ ! -f "$STACK_ROOT/config/traefik/htpasswd" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
    write_traefik_htpasswd "$sec"
    changed=1
  fi

  if [[ "${ENABLE_DOKU:-0}" == "1" ]]; then
    write_doku_htpasswd "$sec"
    changed=1
  fi

  if [[ -z "${REGISTRY_PASSWORD:-}" ]]; then
    if ! grep -q '^REGISTRY_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      local rp
      rp=$(rand_hex 24)
      grep -v '^REGISTRY_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
      mv "${sec}.tmp" "$sec" 2>/dev/null || true
      echo "REGISTRY_PASSWORD=$rp" >>"$sec"
      changed=1
    fi
  fi

  if registry_enabled; then
    : "${REGISTRY_PULL_USER:=registrypull}"
    if [[ -z "${REGISTRY_PULL_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^REGISTRY_PULL_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local rpp
        rpp=$(rand_hex 24)
        grep -v '^REGISTRY_PULL_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "REGISTRY_PULL_PASSWORD=$rpp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]]; then
    local force_semaphore_key=0

    if [[ -n "${SEMAPHORE_ACCESS_KEY_ENCRYPTION:-}" ]] \
      && ! semaphore_access_key_encryption_valid "$SEMAPHORE_ACCESS_KEY_ENCRYPTION"; then
      if grep -Eq '^SEMAPHORE_ACCESS_KEY_ENCRYPTION=.+$' "$ENV_FILE" 2>/dev/null; then
        err "SEMAPHORE_ACCESS_KEY_ENCRYPTION must be base64 and decode to 16, 24, or 32 bytes. Leave it empty to generate a valid key."
      fi
      force_semaphore_key=1
    fi

    if [[ -z "${SEMAPHORE_ACCESS_KEY_ENCRYPTION:-}" ]] \
      || [[ "$FORCE_SECRETS" -eq 1 ]] \
      || [[ "$force_semaphore_key" -eq 1 ]]; then
      if ! grep -q '^SEMAPHORE_ACCESS_KEY_ENCRYPTION=' "$sec" 2>/dev/null \
        || [[ "$FORCE_SECRETS" -eq 1 ]] \
        || [[ "$force_semaphore_key" -eq 1 ]]; then
        local sk
        sk=$(rand_base64 32)
        grep -v '^SEMAPHORE_ACCESS_KEY_ENCRYPTION=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "SEMAPHORE_ACCESS_KEY_ENCRYPTION=$sk" >>"$sec"
        changed=1
      fi
    fi

    if [[ -z "${SEMAPHORE_ADMIN_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^SEMAPHORE_ADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local sp
        sp=$(rand_hex 16)
        grep -v '^SEMAPHORE_ADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "SEMAPHORE_ADMIN_PASSWORD=$sp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_DUPLICATI:-0}" == "1" ]]; then
    if [[ -z "${DUPLICATI_WEBSERVICE_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^DUPLICATI_WEBSERVICE_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local dwp
        dwp=$(rand_hex 16)
        grep -v '^DUPLICATI_WEBSERVICE_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "DUPLICATI_WEBSERVICE_PASSWORD=$dwp" >>"$sec"
        changed=1
      fi
    fi

    if [[ -z "${DUPLICATI_SETTINGS_ENCRYPTION_KEY:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^DUPLICATI_SETTINGS_ENCRYPTION_KEY=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local dsek
        dsek=$(rand_hex 32)
        grep -v '^DUPLICATI_SETTINGS_ENCRYPTION_KEY=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "DUPLICATI_SETTINGS_ENCRYPTION_KEY=$dsek" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]]; then
    : "${FILEBROWSER_USER:=${STACK_ADMIN_USER:-admin}}"
    if [[ -z "${FILEBROWSER_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^FILEBROWSER_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local fbp
        fbp=$(rand_hex 16)
        grep -v '^FILEBROWSER_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "FILEBROWSER_PASSWORD=$fbp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_BESZEL:-0}" == "1" ]]; then
    if [[ -z "${BESZEL_USER_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^BESZEL_USER_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local bzp
        bzp=$(rand_hex 16)
        grep -v '^BESZEL_USER_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "BESZEL_USER_PASSWORD=$bzp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_GITEA:-0}" == "1" ]]; then
    if [[ -z "${GITEA_ADMIN_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^GITEA_ADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local gp
        gp=$(rand_hex 16)
        grep -v '^GITEA_ADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "GITEA_ADMIN_PASSWORD=$gp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_MONGO:-0}" == "1" ]]; then
    if [[ -z "${MONGO_ROOT_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^MONGO_ROOT_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local mp
        mp=$(rand_hex 24)
        grep -v '^MONGO_ROOT_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "MONGO_ROOT_PASSWORD=$mp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_POSTGRES:-0}" == "1" ]]; then
    if [[ -z "${POSTGRES_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^POSTGRES_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local pp
        pp=$(rand_hex 24)
        grep -v '^POSTGRES_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "POSTGRES_PASSWORD=$pp" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_MARIADB:-0}" == "1" ]]; then
    if [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^MARIADB_ROOT_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local mrp
        mrp=$(rand_hex 24)
        grep -v '^MARIADB_ROOT_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "MARIADB_ROOT_PASSWORD=$mrp" >>"$sec"
        changed=1
      fi
    fi
    if [[ -n "${MARIADB_USER:-}" ]]; then
      if [[ -z "${MARIADB_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        if ! grep -q '^MARIADB_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
          local mdp
          mdp=$(rand_hex 24)
          grep -v '^MARIADB_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
          mv "${sec}.tmp" "$sec" 2>/dev/null || true
          echo "MARIADB_PASSWORD=$mdp" >>"$sec"
          changed=1
        fi
      fi
    fi
  fi

  if [[ "${ENABLE_MYSQL:-0}" == "1" ]]; then
    if [[ -z "${MYSQL_ROOT_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^MYSQL_ROOT_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local myrp
        myrp=$(rand_hex 24)
        grep -v '^MYSQL_ROOT_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "MYSQL_ROOT_PASSWORD=$myrp" >>"$sec"
        changed=1
      fi
    fi
    if [[ -n "${MYSQL_USER:-}" ]]; then
      if [[ -z "${MYSQL_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        if ! grep -q '^MYSQL_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
          local mydp
          mydp=$(rand_hex 24)
          grep -v '^MYSQL_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
          mv "${sec}.tmp" "$sec" 2>/dev/null || true
          echo "MYSQL_PASSWORD=$mydp" >>"$sec"
          changed=1
        fi
      fi
    fi
  fi

  if [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]]; then
    if [[ -z "${MONGO_EXPRESS_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^MONGO_EXPRESS_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local mep
        mep=$(rand_hex 16)
        grep -v '^MONGO_EXPRESS_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "MONGO_EXPRESS_PASSWORD=$mep" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_PGADMIN:-0}" == "1" ]]; then
    if [[ -z "${PGADMIN_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^PGADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local pg
        pg=$(rand_hex 16)
        grep -v '^PGADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "PGADMIN_PASSWORD=$pg" >>"$sec"
        changed=1
      fi
    fi
  fi

  if [[ "${ENABLE_DEPLOYER:-0}" == "1" ]]; then
    if [[ -z "${DEPLOYER_ADMIN_PASSWORD:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^DEPLOYER_ADMIN_PASSWORD=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local dap
        dap=$(rand_hex 16)
        grep -v '^DEPLOYER_ADMIN_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "DEPLOYER_ADMIN_PASSWORD=$dap" >>"$sec"
        changed=1
      fi
    fi
    if [[ -z "${DEPLOYER_SECRET:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^DEPLOYER_SECRET=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local dss
        dss=$(rand_hex 32)
        grep -v '^DEPLOYER_SECRET=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "DEPLOYER_SECRET=$dss" >>"$sec"
        changed=1
      fi
    fi
    if deployer_auth_mode_uses_api_key; then
      if [[ -z "${DEPLOYER_API_KEY:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        if ! grep -q '^DEPLOYER_API_KEY=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
          local dapi
          dapi=$(rand_hex 32)
          grep -v '^DEPLOYER_API_KEY=' "$sec" >"${sec}.tmp" 2>/dev/null || true
          mv "${sec}.tmp" "$sec" 2>/dev/null || true
          echo "DEPLOYER_API_KEY=$dapi" >>"$sec"
          changed=1
        fi
      fi
    else
      DEPLOYER_API_KEY=""
      if grep -q '^DEPLOYER_API_KEY=' "$sec" 2>/dev/null; then
        grep -v '^DEPLOYER_API_KEY=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        changed=1
      fi
    fi
  fi

  if [[ "$changed" -eq 1 ]]; then
    echo "Updated $sec (mode 600). See passwords inside the file."
  fi
  return 0
}

merge_secrets_for_compose() {
  source_env_file_safely "$ENV_FILE"
  source_env_file_safely "$SCRIPT_DIR/.secrets"
  apply_stack_admin_defaults
  export STACK_ROOT
  STACK_ROOT=$(cd "$SCRIPT_DIR" && cd "${STACK_ROOT:-.}" && pwd)
  export STACK_ROOT
}

quote_for_env_stack() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

escape_pgpass_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/:/\\:/g'
}

render_pgadmin_config() {
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] || return 0
  [[ "${ENABLE_POSTGRES:-0}" == "1" ]] || return 0

  merge_secrets_for_compose

  local dir="$STACK_ROOT/config/pgadmin"
  local servers="$dir/servers.json"
  local pgpass="$dir/pgpass"
  local db_host="${PGADMIN_POSTGRES_HOST:-postgres}"
  local db_port="${PGADMIN_POSTGRES_PORT:-5432}"
  local db_user="${POSTGRES_USER:-app}"
  # Superuser connects to the default postgres maintenance DB (see POSTGRES_DB).
  local db_name="${POSTGRES_DB:-postgres}"
  local db_pass="${POSTGRES_PASSWORD:-}"
  local esc_pass

  [ -n "$db_pass" ] || die "ENABLE_PGADMIN=1 and ENABLE_POSTGRES=1: set POSTGRES_PASSWORD (or leave empty for auto-generation)."

  mkdir -p "$dir"
  chmod 700 "$dir"
  esc_pass="$(escape_pgpass_value "$db_pass")"

  umask 077
  printf '%s:%s:%s:%s:%s\n' "$db_host" "$db_port" "$db_name" "$db_user" "$esc_pass" >"$pgpass"
  chmod 600 "$pgpass"

  cat >"$servers" <<EOF
{
  "Servers": {
    "1": {
      "Name": "Postgres",
      "Group": "Servers",
      "Host": "${db_host}",
      "Port": ${db_port},
      "MaintenanceDB": "${db_name}",
      "Username": "${db_user}",
      "PassFile": "/pgpass",
      "SSLMode": "prefer"
    }
  }
}
EOF
  chmod 600 "$servers"
  info "pgAdmin: $servers and $pgpass — auto-linked to Postgres (${db_host}:${db_port})."
}

gocron_software_catalog() {
  printf '%s\n' \
    apprise borgbackup docker git podman rclone rdiff-backup restic rsync logrotate sqlite3 kopia
}

parse_gocron_software_list() {
  local raw token
  raw="${GOCRON_SOFTWARE:-rsync}"
  raw="$(printf '%s' "$raw" | tr ',;' ' \n' | tr '[:upper:]' '[:lower:]')"
  for token in $raw; do
    token="${token//\'/}"
    token="${token//\"/}"
    [ -n "$token" ] || continue
    printf '%s\n' "$token"
  done | awk '!seen[$0]++'
}

validate_gocron_software() {
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] || return 0
  local name invalid=() catalog
  mapfile -t catalog < <(gocron_software_catalog)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local ok=0 item
    for item in "${catalog[@]}"; do
      [[ "$item" == "$name" ]] && ok=1 && break
    done
    (( ok )) || invalid+=("$name")
  done < <(parse_gocron_software_list)
  ((${#invalid[@]})) || return 0
  die "GOCRON_SOFTWARE contains unknown tool(s): ${invalid[*]}. Allowed: $(gocron_software_catalog | tr '\n' ' ' | sed 's/ $//')."
}

deployer_software_catalog() {
  printf '%s\n' \
    bash psql postgres mysql mariadb mongosh mongo curl jq python3 python openssl rsync \
    openssh openssh-client ssh bind dig nslookup zip
}

parse_deployer_software_list() {
  local raw token
  raw="${DEPLOYER_SOFTWARE:-bash,curl,psql}"
  raw="$(printf '%s' "$raw" | tr ',;' ' \n' | tr '[:upper:]' '[:lower:]')"
  for token in $raw; do
    token="${token//\'/}"
    token="${token//\"/}"
    [ -n "$token" ] || continue
    printf '%s\n' "$token"
  done | awk '!seen[$0]++'
}

validate_deployer_software() {
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] || return 0
  local name invalid=() catalog
  mapfile -t catalog < <(deployer_software_catalog)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local ok=0 item
    for item in "${catalog[@]}"; do
      [[ "$item" == "$name" ]] && ok=1 && break
    done
    (( ok )) || invalid+=("$name")
  done < <(parse_deployer_software_list)
  ((${#invalid[@]})) || return 0
  die "DEPLOYER_SOFTWARE contains unknown tool(s): ${invalid[*]}. Allowed: $(deployer_software_catalog | tr '\n' ' ' | sed 's/ $//'). node is always in the image."
}

build_gocron_software_yaml() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf "  - name: '%s'\n" "$name"
  done < <(parse_gocron_software_list)
}

build_gocron_allowed_commands_yaml() {
  cat <<'EOF'
    echo:
      allow_all_args: true
    date:
      allow_all_args: true
    test:
      allow_all_args: true
    true:
      allow_all_args: true
    false:
      allow_all_args: true
    sleep:
      allow_all_args: true
EOF
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf "    %s:\n      allow_all_args: true\n" "$name"
  done < <(parse_gocron_software_list)
}

render_gocron_config() {
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] || return 0
  merge_secrets_for_compose
  validate_gocron_software

  local dir config_file tz software_yaml allowed_yaml header
  dir="$(svc_data_path gocron)"
  config_file="$dir/config.yaml"
  tz="${TZ:-UTC}"
  software_yaml="$(build_gocron_software_yaml)"
  allowed_yaml="$(build_gocron_allowed_commands_yaml)"

  mkdir -p "$dir"
  chmod 700 "$dir"

  header=$(mktemp)
  umask 077
  cat >"$header" <<EOF
# Generated by setup-server-stack.sh — software from GOCRON_SOFTWARE in .env; edit jobs: in UI or here.
time_zone: '${tz}'
log_level: 'info'
delete_runs_after_days: 7
db:
  location: '.'
  name: 'db.sqlite'
software:
${software_yaml}
terminal:
  allow_all_commands: false
  allowed_commands:
${allowed_yaml}
server:
  address: '0.0.0.0'
  port: 8156
job_defaults:
  cron: '0 3 * * 0'
EOF

  if [[ -f "$config_file" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      GOCRON_CONFIG="$config_file" GOCRON_HEADER="$header" python3 <<'PY'
import os
import pathlib
import re

config = pathlib.Path(os.environ["GOCRON_CONFIG"])
header = pathlib.Path(os.environ["GOCRON_HEADER"]).read_text(encoding="utf-8")
old = config.read_text(encoding="utf-8")
match = re.search(r"^jobs:\s*\n", old, re.MULTILINE)
jobs = old[match.start():] if match else "jobs: []\n"
if not jobs.endswith("\n"):
    jobs += "\n"
config.write_text(header + jobs, encoding="utf-8")
PY
      rm -f "$header"
      chmod 600 "$config_file"
      info "gocron: updated software in $config_file (jobs preserved)."
      return 0
    fi
    rm -f "$header"
    warn "gocron: keeping existing $config_file (install python3 to refresh software list from .env)."
    return 0
  fi

  cat >>"$header" <<'EOF'
jobs: []
EOF
  mv "$header" "$config_file"
  chmod 600 "$config_file"
  info "gocron: wrote $config_file (software: ${GOCRON_SOFTWARE:-rsync})."
}

filebrowser_compose_cli() {
  docker compose --env-file "$STACK_ROOT/.env.stack" \
    -f "$SCRIPT_DIR/docker-compose.yml" run --rm --no-deps \
    --entrypoint filebrowser filebrowser "$@"
}

configure_filebrowser_credentials() {
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] || return 0
  merge_secrets_for_compose

  local user="${FILEBROWSER_USER:-${STACK_ADMIN_USER:-admin}}"
  local pass="${FILEBROWSER_PASSWORD:-}"
  [[ -n "$pass" ]] || die "FILEBROWSER_PASSWORD is empty after secrets generation."

  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  local base_delay="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  local max_delay="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"
  local i delay last_error=""
  step "Filebrowser: configuring admin credentials"

  for ((i = 1; i <= retries; i++)); do
    if ! docker inspect -f '{{.State.Running}}' filebrowser 2>/dev/null | grep -q '^true$'; then
      last_error="container is not running yet"
      delay=$((base_delay * (2 ** (i - 1))))
      (( delay > max_delay )) && delay="$max_delay"
      sleep "$delay"
      continue
    fi

    if docker exec filebrowser test -f /database/filebrowser.db >/dev/null 2>&1; then
      break
    fi

    last_error="database is not initialized yet"
    delay=$((base_delay * (2 ** (i - 1))))
    (( delay > max_delay )) && delay="$max_delay"
    sleep "$delay"
  done

  if ! docker exec filebrowser test -f /database/filebrowser.db >/dev/null 2>&1; then
    warn "Filebrowser database was not initialized after ${retries} attempts; stopping Filebrowser to avoid exposing an unsecured panel."
    [ -n "$last_error" ] && warn "Filebrowser last state: $last_error"
    docker logs --tail 30 filebrowser 2>&1 | sed 's/^/  filebrowser log: /' || true
    docker stop filebrowser >/dev/null 2>&1 || true
    warn "Re-run setup-server-stack.sh after Filebrowser is healthy, or disable it with ENABLE_FILEBROWSER=0."
    return 0
  fi

  docker stop filebrowser >/dev/null 2>&1 || true

  for ((i = 1; i <= retries; i++)); do
    if filebrowser_compose_cli -d /database/filebrowser.db users update "$user" --password "$pass" --perm.admin=true >/dev/null 2>&1; then
      info "Filebrowser credentials configured for user ${user}."
      docker compose --env-file "$STACK_ROOT/.env.stack" -f "$SCRIPT_DIR/docker-compose.yml" up -d filebrowser >/dev/null
      return 0
    fi
    last_error=$(filebrowser_compose_cli -d /database/filebrowser.db users update "$user" --password "$pass" --perm.admin=true 2>&1 >/dev/null || true)

    if filebrowser_compose_cli -d /database/filebrowser.db users update admin --username "$user" --password "$pass" --perm.admin=true >/dev/null 2>&1; then
      info "Filebrowser credentials configured for user ${user}."
      docker compose --env-file "$STACK_ROOT/.env.stack" -f "$SCRIPT_DIR/docker-compose.yml" up -d filebrowser >/dev/null
      return 0
    fi
    last_error=$(filebrowser_compose_cli -d /database/filebrowser.db users update admin --username "$user" --password "$pass" --perm.admin=true 2>&1 >/dev/null || true)

    if filebrowser_compose_cli -d /database/filebrowser.db users add "$user" "$pass" --perm.admin=true >/dev/null 2>&1; then
      info "Filebrowser credentials configured for user ${user}."
      docker compose --env-file "$STACK_ROOT/.env.stack" -f "$SCRIPT_DIR/docker-compose.yml" up -d filebrowser >/dev/null
      return 0
    fi
    last_error=$(filebrowser_compose_cli -d /database/filebrowser.db users add "$user" "$pass" --perm.admin=true 2>&1 >/dev/null || true)

    delay=$((base_delay * (2 ** (i - 1))))
    (( delay > max_delay )) && delay="$max_delay"
    sleep "$delay"
  done

  warn "Filebrowser credentials were not configured after ${retries} attempts; stopping Filebrowser to avoid exposing an unsecured panel."
  [ -n "$last_error" ] && warn "Filebrowser last CLI error: $last_error"
  docker logs --tail 30 filebrowser 2>&1 | sed 's/^/  filebrowser log: /' || true
  warn "Re-run setup-server-stack.sh after Filebrowser is healthy, or disable it with ENABLE_FILEBROWSER=0."
  return 0
}

# Extract a top-level string field from a JSON object read on stdin.
# Uses python3 when available, with a naive sed fallback for simple objects.
beszel_json_field() {
  local field="$1"
  if command -v python3 >/dev/null 2>&1; then
    BESZEL_JSON_FIELD="$field" python3 -c '
import sys, json, os
field = os.environ["BESZEL_JSON_FIELD"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
value = data.get(field)
if value is None:
    sys.exit(1)
print(value)
' 2>/dev/null
  else
    sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

# Auto-register this server in Beszel: read the hub public key and a universal
# token from the hub API, write them as agent KEY/TOKEN files, then (re)start the
# agent so it self-registers over WebSocket. Non-fatal: on any failure the stack
# stays up and the operator can add the system manually in the hub UI.
configure_beszel() {
  [[ "${ENABLE_BESZEL:-0}" == "1" ]] || return 0
  [[ "${ENABLE_BESZEL_AGENT:-0}" == "1" ]] || return 0
  merge_secrets_for_compose

  local port="${BESZEL_HUB_LOCAL_PORT:-8090}"
  local base="http://127.0.0.1:${port}"
  local email="${BESZEL_USER_EMAIL:-${STACK_ADMIN_EMAIL}}"
  local pass="${BESZEL_USER_PASSWORD:-}"
  local agent_dir keyfile tokenfile
  agent_dir="$(beszel_agent_data_path)"
  keyfile="$agent_dir/agent.key"
  tokenfile="$agent_dir/agent.token"
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  local base_delay="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  local max_delay="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"

  if [ -z "$pass" ]; then
    warn "Beszel: BESZEL_USER_PASSWORD is empty; skipping auto-registration."
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "Beszel: curl not found; skipping auto-registration. Add the system manually in the hub UI."
    return 0
  fi

  step "Beszel: auto-registering this server"

  local i delay ready=0
  for ((i = 1; i <= 20; i++)); do
    if curl -fsS -m 5 "$base/api/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 3
  done
  if [[ "$ready" -ne 1 ]]; then
    warn "Beszel: hub API not ready on ${base}; skipping auto-registration. Add the system manually later."
    return 0
  fi

  # PocketBase superuser (admin panel at /_/) — idempotent, best effort.
  docker exec beszel /beszel superuser upsert "$email" "$pass" >/dev/null 2>&1 || true

  # Authenticate as the dashboard user (created on first run via USER_EMAIL/USER_PASSWORD).
  local auth_resp auth_token=""
  for ((i = 1; i <= retries; i++)); do
    auth_resp=$(curl -fsS -m 10 -X POST "$base/api/collections/users/auth-with-password" \
      -H 'Content-Type: application/json' \
      -d "{\"identity\":\"${email}\",\"password\":\"${pass}\"}" 2>/dev/null || true)
    auth_token=$(printf '%s' "$auth_resp" | beszel_json_field token || true)
    [ -n "$auth_token" ] && break
    # If the hub has no users yet, create the first one, then retry auth.
    curl -fsS -m 10 -X POST "$base/api/beszel/create-user" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"${email}\",\"password\":\"${pass}\"}" >/dev/null 2>&1 || true
    delay=$((base_delay * (2 ** (i - 1))))
    (( delay > max_delay )) && delay="$max_delay"
    sleep "$delay"
  done
  if [ -z "$auth_token" ]; then
    warn "Beszel: could not authenticate to the hub API; skipping auto-registration. Log in at https://beszel.${DOMAIN} and add the system manually."
    return 0
  fi

  local key token
  key=$(curl -fsS -m 10 "$base/api/beszel/getkey" -H "Authorization: ${auth_token}" 2>/dev/null | beszel_json_field key || true)
  token=$(curl -fsS -m 10 "$base/api/beszel/universal-token?enable=1" -H "Authorization: ${auth_token}" 2>/dev/null | beszel_json_field token || true)

  if [ -z "$key" ] || [ -z "$token" ]; then
    warn "Beszel: failed to read hub key/token from the API; skipping auto-registration."
    return 0
  fi

  umask 077
  mkdir -p "$agent_dir"
  printf '%s\n' "$key" >"$keyfile"
  chmod 600 "$keyfile"
  printf '%s' "$token" >"$tokenfile"
  chmod 600 "$tokenfile"

  if ! docker restart beszel-agent >/dev/null 2>&1; then
    docker compose --env-file "$STACK_ROOT/.env.stack" -f "$SCRIPT_DIR/docker-compose.yml" up -d beszel-agent >/dev/null 2>&1 || true
  fi
  info "Beszel: local agent configured; this server should appear in the dashboard within a minute."
}

# Auto-provision Gitea admin and (optionally) register the local Actions runner.
# Non-fatal: on failure the stack stays up; finish setup in the Gitea web UI.
configure_gitea() {
  [[ "${ENABLE_GITEA:-0}" == "1" ]] || return 0
  merge_secrets_for_compose

  local user="${GITEA_ADMIN:-${STACK_ADMIN_USER:-admin}}"
  local email="${GITEA_ADMIN_EMAIL:-${STACK_ADMIN_EMAIL}}"
  local pass="${GITEA_ADMIN_PASSWORD:-}"
  local instance="${GITEA_RUNNER_INSTANCE_URL:-https://gitea.${DOMAIN}}"
  local runner_name="${GITEA_RUNNER_NAME:-stack-runner}"
  local runner_dir token retries base_delay max_delay i delay

  if [ -z "$pass" ]; then
    warn "Gitea: GITEA_ADMIN_PASSWORD is empty; skipping auto-provisioning."
    return 0
  fi

  step "Gitea: provisioning admin and Actions runner"
  retries="${REGISTRY_OPERATION_RETRIES:-3}"
  base_delay="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  max_delay="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"

  for ((i = 1; i <= 20; i++)); do
    if docker inspect -f '{{.State.Running}}' gitea 2>/dev/null | grep -q '^true$'; then
      if docker exec gitea test -f /data/gitea/conf/app.ini >/dev/null 2>&1; then
        break
      fi
    fi
    sleep 3
  done
  if ! docker exec gitea test -f /data/gitea/conf/app.ini >/dev/null 2>&1; then
    warn "Gitea: app.ini not ready; skipping auto-provisioning. Open https://gitea.${DOMAIN} and finish the install wizard."
    return 0
  fi

  docker exec -u git gitea gitea migrate >/dev/null 2>&1 || true

  if ! docker exec -u git gitea gitea admin user list 2>/dev/null | grep -qF "$user"; then
    if ! docker exec -u git gitea gitea admin user create \
      --admin \
      --username "$user" \
      --password "$pass" \
      --email "$email" \
      --must-change-password=false >/dev/null 2>&1; then
      warn "Gitea: could not create admin user ${user}. Finish setup at https://gitea.${DOMAIN}."
      return 0
    fi
    info "Gitea: admin user ${user} created."
  else
    docker exec -u git gitea gitea admin user change-password \
      --username "$user" \
      --password "$pass" >/dev/null 2>&1 || true
    info "Gitea: admin user ${user} already exists."
  fi

  [[ "${ENABLE_GITEA_RUNNER:-0}" == "1" ]] || return 0

  runner_dir="$(gitea_runner_data_path)"
  if [[ -f "$runner_dir/.runner" ]]; then
    info "Gitea Actions runner already registered (${runner_name})."
    return 0
  fi

  token="${GITEA_RUNNER_REGISTRATION_TOKEN:-}"
  if [ -z "$token" ]; then
    for ((i = 1; i <= retries; i++)); do
      token=$(docker exec -u git gitea gitea actions generate-runner-token 2>/dev/null | tr -d '\r\n' || true)
      [ -n "$token" ] && break
      delay=$((base_delay * (2 ** (i - 1))))
      (( delay > max_delay )) && delay="$max_delay"
      sleep "$delay"
    done
  fi
  if [ -z "$token" ]; then
    warn "Gitea: could not obtain an Actions runner registration token. Register manually: Site Administration → Actions → Runners."
    return 0
  fi

  if ! docker inspect -f '{{.State.Running}}' gitea-runner 2>/dev/null | grep -q '^true$'; then
    GITEA_RUNNER_REGISTRATION_TOKEN="$token" \
      docker compose --env-file "$STACK_ROOT/.env.stack" -f "$SCRIPT_DIR/docker-compose.yml" up -d gitea-runner >/dev/null 2>&1 || true
    sleep 5
  fi

  for ((i = 1; i <= retries; i++)); do
    if docker exec gitea-runner act_runner register \
      --no-interactive \
      --instance "$instance" \
      --token "$token" \
      --name "$runner_name" >/dev/null 2>&1; then
      docker restart gitea-runner >/dev/null 2>&1 || true
      info "Gitea Actions runner registered as ${runner_name}."
      return 0
    fi
    delay=$((base_delay * (2 ** (i - 1))))
    (( delay > max_delay )) && delay="$max_delay"
    sleep "$delay"
  done

  warn "Gitea: runner registration failed. Set GITEA_RUNNER_REGISTRATION_TOKEN in .env (from Gitea UI) and re-run setup-server-stack.sh."
}

resolve_adminer_default_server() {
  if [[ -n "${ADMINER_DEFAULT_SERVER:-}" ]]; then
    echo "$ADMINER_DEFAULT_SERVER"
    return
  fi
  if [[ "${ENABLE_POSTGRES:-0}" == "1" ]]; then
    echo postgres
    return
  fi
  if [[ "${ENABLE_MARIADB:-0}" == "1" ]]; then
    echo mariadb
    return
  fi
  if [[ "${ENABLE_MYSQL:-0}" == "1" ]]; then
    echo mysql
    return
  fi
  echo postgres
}

write_env_for_compose() {
  merge_secrets_for_compose
  : "${TRAEFIK_IMAGE:=traefik:v3.6}"
  : "${REGISTRY_IMAGE:=registry:2}"
  : "${DOCKER_AUTH_IMAGE:=cesanta/docker_auth:1}"
  : "${PORTAINER_IMAGE:=portainer/portainer-ce:latest}"
  : "${WATCHTOWER_IMAGE:=nickfedor/watchtower:latest}"
  : "${SEMAPHORE_IMAGE:=semaphoreui/semaphore:latest}"
  : "${GITEA_IMAGE:=gitea/gitea:1.23}"
  : "${GITEA_RUNNER_IMAGE:=gitea/act_runner:0.2.11}"
  : "${GITEA_PUID:=1000}"
  : "${GITEA_PGID:=1000}"
  : "${GITEA_DB_TYPE:=sqlite3}"
  : "${GITEA_HOST:=gitea.${DOMAIN}}"
  : "${GITEA_ROOT_URL:=https://gitea.${DOMAIN}/}"
  : "${GITEA_SSH_PORT:=2222}"
  : "${GITEA_RUNNER_INSTANCE_URL:=https://gitea.${DOMAIN}}"
  : "${GITEA_RUNNER_NAME:=stack-runner}"
  : "${DOKU_IMAGE:=amerkurev/doku:latest}"
  : "${DUPLICATI_IMAGE:=linuxserver/duplicati:latest}"
  : "${GOCRON_IMAGE:=ghcr.io/flohoss/gocron:latest}"
  : "${UPTIME_KUMA_IMAGE:=louislam/uptime-kuma:1}"
  : "${BESZEL_IMAGE:=henrygd/beszel:latest}"
  : "${BESZEL_AGENT_IMAGE:=henrygd/beszel-agent:latest}"
  : "${BESZEL_HUB_LOCAL_PORT:=8090}"
  : "${BESZEL_APP_URL:=https://beszel.${DOMAIN}}"
  : "${BESZEL_HUB_URL:=http://localhost:${BESZEL_HUB_LOCAL_PORT}}"
  : "${BESZEL_AGENT_DISABLE_SSH:=true}"
  : "${FILEBROWSER_IMAGE:=filebrowser/filebrowser:v2-s6}"
  : "${NGINX_IMAGE:=nginx:1.27-alpine}"
  : "${NGINX_HOST:=${DOMAIN:-}}"
  : "${MONGO_IMAGE:=mongo:7}"
  : "${POSTGRES_IMAGE:=postgres:16-alpine}"
  : "${MARIADB_IMAGE:=mariadb:11}"
  : "${MYSQL_IMAGE:=mysql:8}"
  : "${MONGO_EXPRESS_IMAGE:=mongo-express:latest}"
  : "${PGADMIN_IMAGE:=dpage/pgadmin4:latest}"
  : "${ADMINER_IMAGE:=adminer:latest}"
  : "${DEPLOYER_IMAGE:=ghcr.io/commercedeployer/deployer:latest}"
  : "${DEPLOYER_IMAGE_EFFECTIVE:=${DEPLOYER_IMAGE}}"
  : "${DEPLOYER_NODE_ENV:=production}"
  : "${DEPLOYER_AUTH_MODE:=dual}"
  : "${DEPLOY_BASE_PATH:=/opt/deploy-data}"
  : "${DEPLOYER_DEFAULT_PULL_POLICY:=always}"
  : "${DEPLOYER_PULL_MAX_ATTEMPTS:=3}"
  : "${DEPLOYER_CONTAINER_LIMIT:=0}"
  : "${DEPLOYER_MANAGED_LABEL:=managed-by}"
  : "${DEPLOYER_MANAGED_LABEL_VALUE:=deployer}"
  : "${DEPLOYER_REGISTRY_HOST:=}"
  : "${DEPLOYER_REGISTRY_USER:=}"
  : "${DEPLOYER_REGISTRY_PASSWORD:=}"
  : "${REGISTRY_PULL_USER:=registrypull}"
  if [[ -z "${DEPLOYER_REGISTRY_USER}" ]] && registry_enabled; then
    DEPLOYER_REGISTRY_USER="${REGISTRY_USER}"
  fi
  if [[ -z "${DEPLOYER_REGISTRY_PASSWORD}" ]] && registry_enabled; then
    DEPLOYER_REGISTRY_PASSWORD="${REGISTRY_PASSWORD}"
  fi
  : "${DEPLOYER_REGISTRY_CREDENTIALS_JSON:=}"
  if [[ -z "${DEPLOYER_REGISTRY_CREDENTIALS_JSON}" ]]; then
    DEPLOYER_REGISTRY_CREDENTIALS_JSON="$(build_registry_credentials_json)"
  fi

  export COMPOSE_PROFILES
  COMPOSE_PROFILES=$(compose_profiles)
  export COMPOSE_PROFILES

  local env_out="$STACK_ROOT/.env.stack"
  local rp sp sk dwp dsek mp pp mrp mdp myrp mydp mep pgp adminer_srv fbr fbp nginx_host deployer_auth_mode dap dss dapi drp drcj rpp bzp bzapp bzsys gap grt gitea_root_url gitea_runner_url
  rp="$(quote_for_env_stack "${REGISTRY_PASSWORD:-}")"
  rpp="$(quote_for_env_stack "${REGISTRY_PULL_PASSWORD:-}")"
  sp="$(quote_for_env_stack "${SEMAPHORE_ADMIN_PASSWORD:-}")"
  sk="$(quote_for_env_stack "${SEMAPHORE_ACCESS_KEY_ENCRYPTION:-}")"
  dwp="$(quote_for_env_stack "${DUPLICATI_WEBSERVICE_PASSWORD:-}")"
  dsek="$(quote_for_env_stack "${DUPLICATI_SETTINGS_ENCRYPTION_KEY:-}")"
  mp="$(quote_for_env_stack "${MONGO_ROOT_PASSWORD:-}")"
  pp="$(quote_for_env_stack "${POSTGRES_PASSWORD:-}")"
  mrp="$(quote_for_env_stack "${MARIADB_ROOT_PASSWORD:-}")"
  mdp="$(quote_for_env_stack "${MARIADB_PASSWORD:-}")"
  myrp="$(quote_for_env_stack "${MYSQL_ROOT_PASSWORD:-}")"
  mydp="$(quote_for_env_stack "${MYSQL_PASSWORD:-}")"
  mep="$(quote_for_env_stack "${MONGO_EXPRESS_PASSWORD:-}")"
  pgp="$(quote_for_env_stack "${PGADMIN_PASSWORD:-}")"
  adminer_srv="$(resolve_adminer_default_server)"
  resolve_filebrowser_root_path
  fbr="$(quote_for_env_stack "${FILEBROWSER_ROOT_PATH}")"
  fbp="$(quote_for_env_stack "${FILEBROWSER_PASSWORD:-}")"
  nginx_host="$(quote_for_env_stack "$(resolve_nginx_host)")"
  bzp="$(quote_for_env_stack "${BESZEL_USER_PASSWORD:-}")"
  bzapp="$(quote_for_env_stack "${BESZEL_APP_URL}")"
  bzsys="$(quote_for_env_stack "${BESZEL_SYSTEM_NAME:-}")"
  gap="$(quote_for_env_stack "${GITEA_ADMIN_PASSWORD:-}")"
  grt="$(quote_for_env_stack "${GITEA_RUNNER_REGISTRATION_TOKEN:-}")"
  gitea_root_url="$(quote_for_env_stack "${GITEA_ROOT_URL}")"
  gitea_runner_url="$(quote_for_env_stack "${GITEA_RUNNER_INSTANCE_URL}")"
  deployer_auth_mode="$(resolve_deployer_auth_mode)"
  dap="$(quote_for_env_stack "${DEPLOYER_ADMIN_PASSWORD:-}")"
  dss="$(quote_for_env_stack "${DEPLOYER_SECRET:-}")"
  dapi="$(quote_for_env_stack "${DEPLOYER_API_KEY:-}")"
  drp="$(quote_for_env_stack "${DEPLOYER_REGISTRY_PASSWORD:-}")"
  drcj="$(quote_for_env_stack "${DEPLOYER_REGISTRY_CREDENTIALS_JSON:-[]}")"
  local p_registry p_portainer p_semaphore p_duplicati p_gocron p_kuma p_pgadmin p_postgres p_mongo p_mariadb p_mysql
  p_registry="$(quote_for_env_stack "$(svc_data_path registry)")"
  p_portainer="$(quote_for_env_stack "$(svc_data_path portainer)")"
  p_semaphore="$(quote_for_env_stack "$(svc_data_path semaphore)")"
  p_duplicati="$(quote_for_env_stack "$(svc_data_path duplicati)")"
  p_gocron="$(quote_for_env_stack "$(svc_data_path gocron)")"
  p_kuma="$(quote_for_env_stack "$(svc_data_path kuma)")"
  local p_beszel p_beszel_agent p_gitea p_gitea_runner
  p_beszel="$(quote_for_env_stack "$(svc_data_path beszel)")"
  p_beszel_agent="$(quote_for_env_stack "$(beszel_agent_data_path)")"
  p_gitea="$(quote_for_env_stack "$(svc_data_path gitea)")"
  p_gitea_runner="$(quote_for_env_stack "$(gitea_runner_data_path)")"
  p_pgadmin="$(quote_for_env_stack "$(svc_data_path pgadmin)")"
  p_postgres="$(quote_for_env_stack "$(svc_data_path postgres)")"
  p_mongo="$(quote_for_env_stack "$(svc_data_path mongo)")"
  p_mariadb="$(quote_for_env_stack "$(svc_data_path mariadb)")"
  p_mysql="$(quote_for_env_stack "$(svc_data_path mysql)")"

  umask 077
  {
    echo "# Generated by setup-server-stack.sh — do not publish"
    echo "STACK_ROOT=$STACK_ROOT"
    echo "REGISTRY_DATA_PATH=$p_registry"
    echo "PORTAINER_DATA_PATH=$p_portainer"
    echo "SEMAPHORE_DATA_PATH=$p_semaphore"
    echo "DUPLICATI_DATA_PATH=$p_duplicati"
    echo "GOCRON_DATA_PATH=$p_gocron"
    echo "KUMA_DATA_PATH=$p_kuma"
    echo "BESZEL_DATA_PATH=$p_beszel"
    echo "BESZEL_AGENT_DATA_PATH=$p_beszel_agent"
    echo "GITEA_DATA_PATH=$p_gitea"
    echo "GITEA_RUNNER_DATA_PATH=$p_gitea_runner"
    echo "PGADMIN_DATA_PATH=$p_pgadmin"
    echo "POSTGRES_DATA_PATH=$p_postgres"
    echo "MONGO_DATA_PATH=$p_mongo"
    echo "MARIADB_DATA_PATH=$p_mariadb"
    echo "MYSQL_DATA_PATH=$p_mysql"
    echo "DOMAIN=$DOMAIN"
    echo "ACME_EMAIL=$ACME_EMAIL"
    echo "STACK_ADMIN_USER=$STACK_ADMIN_USER"
    echo "STACK_ADMIN_EMAIL=$STACK_ADMIN_EMAIL"
    echo "TZ=${TZ:-UTC}"
    echo "TRAEFIK_CERT_MODE=$TRAEFIK_CERT_MODE"
    echo "TRAEFIK_CERT_RESOLVER=$TRAEFIK_CERT_RESOLVER"
    echo "TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL"
    echo "TRAEFIK_ACME_CA_SERVER=$TRAEFIK_ACME_CA_SERVER"
    echo "TRAEFIK_ACME_STORAGE_FILE=$TRAEFIK_ACME_STORAGE_FILE"
    echo "TRAEFIK_TLS_CHECK_WAIT_SECONDS=$TRAEFIK_TLS_CHECK_WAIT_SECONDS"
    echo "TRAEFIK_IMAGE=$TRAEFIK_IMAGE"
    echo "REGISTRY_IMAGE=$REGISTRY_IMAGE"
    echo "DOCKER_AUTH_IMAGE=$DOCKER_AUTH_IMAGE"
    echo "PORTAINER_IMAGE=$PORTAINER_IMAGE"
    echo "WATCHTOWER_IMAGE=$WATCHTOWER_IMAGE"
    echo "SEMAPHORE_IMAGE=$SEMAPHORE_IMAGE"
    echo "GITEA_IMAGE=$GITEA_IMAGE"
    echo "GITEA_RUNNER_IMAGE=$GITEA_RUNNER_IMAGE"
    echo "DOKU_IMAGE=$DOKU_IMAGE"
    echo "DUPLICATI_IMAGE=$DUPLICATI_IMAGE"
    echo "GOCRON_IMAGE=$GOCRON_IMAGE"
    echo "UPTIME_KUMA_IMAGE=$UPTIME_KUMA_IMAGE"
    echo "BESZEL_IMAGE=$BESZEL_IMAGE"
    echo "BESZEL_AGENT_IMAGE=$BESZEL_AGENT_IMAGE"
    echo "FILEBROWSER_IMAGE=$FILEBROWSER_IMAGE"
    echo "NGINX_IMAGE=$NGINX_IMAGE"
    echo "NGINX_HOST=\"$nginx_host\""
    echo "FILEBROWSER_ROOT_PATH=\"$fbr\""
    echo "FILEBROWSER_USER=${FILEBROWSER_USER:-${STACK_ADMIN_USER:-admin}}"
    echo "FILEBROWSER_PASSWORD=\"$fbp\""
    echo "FILEBROWSER_PUID=${FILEBROWSER_PUID:-0}"
    echo "FILEBROWSER_PGID=${FILEBROWSER_PGID:-0}"
    echo "MONGO_IMAGE=$MONGO_IMAGE"
    echo "POSTGRES_IMAGE=$POSTGRES_IMAGE"
    echo "MARIADB_IMAGE=$MARIADB_IMAGE"
    echo "MYSQL_IMAGE=$MYSQL_IMAGE"
    echo "MONGO_EXPRESS_IMAGE=$MONGO_EXPRESS_IMAGE"
    echo "PGADMIN_IMAGE=$PGADMIN_IMAGE"
    echo "ADMINER_IMAGE=$ADMINER_IMAGE"
    echo "ENABLE_TRAEFIK=${ENABLE_TRAEFIK:-0}"
    echo "ENABLE_PORTAINER=${ENABLE_PORTAINER:-0}"
    echo "ENABLE_DOKU=${ENABLE_DOKU:-0}"
    echo "ENABLE_WATCHTOWER=${ENABLE_WATCHTOWER:-0}"
    echo "ENABLE_SEMAPHORE=${ENABLE_SEMAPHORE:-0}"
    echo "ENABLE_GITEA=${ENABLE_GITEA:-0}"
    echo "ENABLE_GITEA_RUNNER=${ENABLE_GITEA_RUNNER:-0}"
    echo "GITEA_HOST=${GITEA_HOST:-gitea.${DOMAIN}}"
    echo "GITEA_ROOT_URL=$gitea_root_url"
    echo "GITEA_SSH_PORT=${GITEA_SSH_PORT:-2222}"
    echo "GITEA_PUID=${GITEA_PUID:-1000}"
    echo "GITEA_PGID=${GITEA_PGID:-1000}"
    echo "GITEA_DB_TYPE=${GITEA_DB_TYPE:-sqlite3}"
    echo "GITEA_ADMIN=${GITEA_ADMIN:-${STACK_ADMIN_USER:-admin}}"
    echo "GITEA_ADMIN_EMAIL=${GITEA_ADMIN_EMAIL:-${STACK_ADMIN_EMAIL}}"
    echo "GITEA_ADMIN_PASSWORD=\"$gap\""
    echo "GITEA_RUNNER_INSTANCE_URL=$gitea_runner_url"
    echo "GITEA_RUNNER_NAME=${GITEA_RUNNER_NAME:-stack-runner}"
    echo "GITEA_RUNNER_REGISTRATION_TOKEN=\"$grt\""
    echo "ENABLE_DUPLICATI=${ENABLE_DUPLICATI:-0}"
    echo "ENABLE_GOCRON=${ENABLE_GOCRON:-0}"
    echo "GOCRON_SOFTWARE=${GOCRON_SOFTWARE:-rsync}"
    echo "ENABLE_UPTIME_KUMA=${ENABLE_UPTIME_KUMA:-0}"
    echo "ENABLE_BESZEL=${ENABLE_BESZEL:-0}"
    echo "ENABLE_BESZEL_AGENT=${ENABLE_BESZEL_AGENT:-0}"
    echo "BESZEL_HUB_LOCAL_PORT=${BESZEL_HUB_LOCAL_PORT:-8090}"
    echo "BESZEL_APP_URL=\"$bzapp\""
    echo "BESZEL_HUB_URL=${BESZEL_HUB_URL}"
    echo "BESZEL_AGENT_DISABLE_SSH=${BESZEL_AGENT_DISABLE_SSH:-true}"
    echo "BESZEL_USER_EMAIL=${BESZEL_USER_EMAIL:-${STACK_ADMIN_EMAIL}}"
    echo "BESZEL_USER_PASSWORD=\"$bzp\""
    echo "BESZEL_SYSTEM_NAME=\"$bzsys\""
    echo "ENABLE_FILEBROWSER=${ENABLE_FILEBROWSER:-0}"
    echo "ENABLE_NGINX=${ENABLE_NGINX:-0}"
    echo "ENABLE_REGISTRY=${ENABLE_REGISTRY:-0}"
    echo "ENABLE_DOCKER_AUTH=${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-0}}"
    echo "DEPLOYER_IMAGE_EFFECTIVE=$DEPLOYER_IMAGE_EFFECTIVE"
    echo "DEPLOYER_IMAGE=$DEPLOYER_IMAGE"
    echo "DEPLOYER_NODE_ENV=$DEPLOYER_NODE_ENV"
    echo "DEPLOYER_AUTH_MODE=$deployer_auth_mode"
    echo "DEPLOYER_ADMIN_USER=$DEPLOYER_ADMIN_USER"
    echo "DEPLOYER_ADMIN_PASSWORD=\"$dap\""
    echo "DEPLOYER_SECRET=\"$dss\""
    echo "DEPLOY_BASE_PATH=$DEPLOY_BASE_PATH"
    echo "DEPLOYER_DEFAULT_PULL_POLICY=$DEPLOYER_DEFAULT_PULL_POLICY"
    echo "DEPLOYER_PULL_MAX_ATTEMPTS=$DEPLOYER_PULL_MAX_ATTEMPTS"
    echo "DEPLOYER_CONTAINER_LIMIT=$DEPLOYER_CONTAINER_LIMIT"
    echo "DEPLOYER_MANAGED_LABEL=$DEPLOYER_MANAGED_LABEL"
    echo "DEPLOYER_MANAGED_LABEL_VALUE=$DEPLOYER_MANAGED_LABEL_VALUE"
    echo "DEPLOYER_REGISTRY_HOST=$DEPLOYER_REGISTRY_HOST"
    echo "DEPLOYER_REGISTRY_USER=${DEPLOYER_REGISTRY_USER:-}"
    echo "DEPLOYER_REGISTRY_PASSWORD=\"$drp\""
    echo "DEPLOYER_REGISTRY_CREDENTIALS_JSON=\"$drcj\""
    echo "DEPLOYER_API_KEY=\"$dapi\""
    echo "DEPLOYER_SOFTWARE=${DEPLOYER_SOFTWARE:-bash,curl,psql}"
    echo "REGISTRY_AUTH_TOKEN_ISSUER=${REGISTRY_AUTH_TOKEN_ISSUER}"
    echo "REGISTRY_USER=${REGISTRY_USER}"
    echo "REGISTRY_PASSWORD=\"$rp\""
    echo "REGISTRY_PULL_USER=${REGISTRY_PULL_USER:-registrypull}"
    echo "REGISTRY_PULL_PASSWORD=\"$rpp\""
    echo "WATCHTOWER_SCHEDULE=${WATCHTOWER_SCHEDULE:-0 0 4 * * *}"
    echo "SEMAPHORE_ADMIN=${SEMAPHORE_ADMIN}"
    echo "SEMAPHORE_ADMIN_PASSWORD=\"$sp\""
    echo "SEMAPHORE_ADMIN_NAME=${SEMAPHORE_ADMIN_NAME:-Admin}"
    echo "SEMAPHORE_ADMIN_EMAIL=${SEMAPHORE_ADMIN_EMAIL}"
    echo "SEMAPHORE_ACCESS_KEY_ENCRYPTION=\"$sk\""
    echo "DUP_PUID=${DUP_PUID:-1000}"
    echo "DUP_PGID=${DUP_PGID:-1000}"
    echo "DUPLICATI_WEBSERVICE_PASSWORD=\"$dwp\""
    echo "DUPLICATI_SETTINGS_ENCRYPTION_KEY=\"$dsek\""
    echo "ENABLE_MONGO=${ENABLE_MONGO:-0}"
    echo "ENABLE_POSTGRES=${ENABLE_POSTGRES:-0}"
    echo "ENABLE_MARIADB=${ENABLE_MARIADB:-0}"
    echo "ENABLE_MYSQL=${ENABLE_MYSQL:-0}"
    echo "MONGO_ROOT_USER=${MONGO_ROOT_USER:-${STACK_ADMIN_USER:-mongoadmin}}"
    echo "MONGO_ROOT_PASSWORD=\"$mp\""
    echo "POSTGRES_USER=${POSTGRES_USER:-${STACK_ADMIN_USER:-app}}"
    echo "POSTGRES_PASSWORD=\"$pp\""
    echo "POSTGRES_DB=${POSTGRES_DB:-postgres}"
    echo "MARIADB_USER=${MARIADB_USER:-}"
    echo "MARIADB_PASSWORD=\"$mdp\""
    echo "MARIADB_DATABASE=${MARIADB_DATABASE:-}"
    echo "MARIADB_ROOT_PASSWORD=\"$mrp\""
    echo "MYSQL_USER=${MYSQL_USER:-}"
    echo "MYSQL_PASSWORD=\"$mydp\""
    echo "MYSQL_DATABASE=${MYSQL_DATABASE:-}"
    echo "MYSQL_ROOT_PASSWORD=\"$myrp\""
    echo "ENABLE_MONGO_EXPRESS=${ENABLE_MONGO_EXPRESS:-0}"
    echo "MONGO_EXPRESS_USER=${MONGO_EXPRESS_USER:-${STACK_ADMIN_USER:-mexpress}}"
    echo "MONGO_EXPRESS_PASSWORD=\"$mep\""
    echo "ENABLE_PGADMIN=${ENABLE_PGADMIN:-0}"
    echo "PGADMIN_EMAIL=${PGADMIN_EMAIL:-${STACK_ADMIN_EMAIL:-pgadmin@example.com}}"
    echo "PGADMIN_PASSWORD=\"$pgp\""
    echo "ENABLE_ADMINER=${ENABLE_ADMINER:-0}"
    echo "ADMINER_DEFAULT_SERVER=$adminer_srv"
    echo "COMPOSE_PROFILES=$COMPOSE_PROFILES"
  } >"$env_out"
  chmod 600 "$env_out"
  info "Wrote $env_out"
}

gen_registry_certs() {
  local k="$STACK_ROOT/certs/registry-token-key.pem" c="$STACK_ROOT/certs/registry-token.pem"
  if [[ ! -f "$k" ]] || [[ ! -f "$c" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -keyout "$k" -out "$c" -subj "/CN=setup-server-registry-token"
    chmod 600 "$k"
    chmod 644 "$c"
    echo "Created JWT key pair for registry/docker_auth: $c"
  fi
}

render_auth_config() {
  need_cmd docker
  merge_secrets_for_compose
  ensure_envsubst
  : "${REGISTRY_PULL_USER:=registrypull}"
  local line bcrypt pull_bcrypt
  line=$(htpasswd_bcrypt "${REGISTRY_USER}" "${REGISTRY_PASSWORD}")
  bcrypt="${line#*:}"
  line=$(htpasswd_bcrypt "${REGISTRY_PULL_USER}" "${REGISTRY_PULL_PASSWORD}")
  pull_bcrypt="${line#*:}"
  export REGISTRY_AUTH_TOKEN_ISSUER
  export REGISTRY_USER
  export REGISTRY_USER_PASSWORD_BCRYPT="$bcrypt"
  export REGISTRY_PULL_USER
  export REGISTRY_PULL_PASSWORD_BCRYPT="$pull_bcrypt"
  # shellcheck disable=SC2016
  envsubst '$REGISTRY_AUTH_TOKEN_ISSUER $REGISTRY_USER $REGISTRY_USER_PASSWORD_BCRYPT $REGISTRY_PULL_USER $REGISTRY_PULL_PASSWORD_BCRYPT' \
    <"$SCRIPT_DIR/config/docker_auth/auth_config.yml.example" \
    >"$STACK_ROOT/config/docker_auth/auth_config.yml"
}

render_watchtower_docker_config() {
  merge_secrets_for_compose
  local auth_b64 first=1
  install -d -m 700 "$STACK_ROOT/config/docker"
  umask 077
  {
    echo "{"
    echo "  \"auths\": {"
    while IFS='|' read -r host user pass; do
      [ -n "$host" ] || continue
      auth_b64=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
      if (( first )); then
        first=0
      else
        echo ","
      fi
      printf '    "%s": {\n' "$host"
      printf '      "auth": "%s"\n' "$auth_b64"
      printf '    }'
    done < <(collect_registry_auth_entries 1)
    if (( first )); then
      echo -n ""
    fi
    echo ""
    echo "  }"
    echo "}"
  } >"$STACK_ROOT/config/docker/config.json"
  chmod 600 "$STACK_ROOT/config/docker/config.json"
}

login_additional_registries() {
  local count="${EXTRA_REGISTRY_COUNT:-0}"
  (( count > 0 )) || return 0
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  local i host user pass
  step "Docker login: extra registries (${count})"
  for ((i = 1; i <= count; i++)); do
    local host_var="EXTRA_REGISTRY_${i}_HOST"
    local user_var="EXTRA_REGISTRY_${i}_USER"
    local pass_var="EXTRA_REGISTRY_${i}_PASSWORD"
    host="$(normalize_registry_host "${!host_var:-}")"
    user="${!user_var:-}"
    pass="${!pass_var:-}"
    [ -n "$host" ] || continue
    docker_login_with_retry "$host" "$user" "$pass" "$retries" || die "docker login failed for extra registry ${host}"
  done
}

registry_enabled() {
  [[ "${ENABLE_REGISTRY:-0}" == "1" ]]
}

registry_target_repo_from_source() {
  local src="$1"
  local without_tag="${src%:*}"
  if [[ "$without_tag" == *"/"* ]]; then
    local first_part="${without_tag%%/*}"
    case "$first_part" in
      *.*|*:*|localhost)
        echo "${src#*/}"
        return 0
        ;;
    esac
  fi
  echo "$src"
}

push_registry_seed_images() {
  registry_enabled || return 0
  local raw="${REGISTRY_SEED_IMAGES:-}"
  [ -n "$raw" ] || return 0

  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] || die "REGISTRY_SEED_IMAGES requires ENABLE_TRAEFIK=1 (push via https://registry.${DOMAIN})."
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-0}}" == "1" ]] || die "REGISTRY_SEED_IMAGES requires ENABLE_DOCKER_AUTH=1."
  local registry_host="registry.${DOMAIN}"
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  step "Registry: pushing seed images"
  retry_cmd "$retries" docker compose --env-file "$ENV_FILE" -f "$SCRIPT_DIR/docker-compose.yml" --profile traefik --profile registry --profile registry-auth up -d traefik registry registry-auth \
    || die "Failed to start traefik/registry/registry-auth."
  docker_login_with_retry "$registry_host" "$REGISTRY_USER" "$REGISTRY_PASSWORD" "$retries" \
    || die "docker login failed for ${registry_host}."

  local normalized
  normalized=$(printf '%s' "$raw" | tr ',;' '\n')
  while IFS= read -r src; do
    src=$(printf '%s' "$src" | xargs)
    [ -n "$src" ] || continue
    if ! docker image inspect "$src" >/dev/null 2>&1; then
      warn "Skipping $src: local image not found."
      continue
    fi
    local repo target
    repo=$(registry_target_repo_from_source "$src")
    target="${registry_host}/${repo}"
    info "Push: $src -> $target"
    docker tag "$src" "$target"
    retry_cmd "$retries" docker push "$target" || die "Failed to push image: $target"
  done <<< "$normalized"
}

prepare_deployer_image() {
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] || return 0
  local deployer_image="${DEPLOYER_IMAGE:-ghcr.io/commercedeployer/deployer:latest}"

  step "Deployer: pull image $deployer_image"
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  local pull_host="${DEPLOYER_IMAGE_REGISTRY_HOST:-}"
  if [[ -z "$pull_host" && "$deployer_image" == */* ]]; then
    pull_host="${deployer_image%%/*}"
    case "$pull_host" in
      *.*|*:*|localhost) ;;
      *) pull_host="" ;;
    esac
  fi
  local pull_user="${DEPLOYER_IMAGE_REGISTRY_USER:-}"
  local pull_pass="${DEPLOYER_IMAGE_REGISTRY_PASSWORD:-}"
  if [ -n "$pull_host" ] && [ -n "$pull_user" ] && [ -n "$pull_pass" ]; then
    step "Deployer: docker login $pull_host (private image)"
    docker_login_with_retry "$pull_host" "$pull_user" "$pull_pass" "$retries" \
      || die "docker login failed for Deployer image registry: $pull_host"
  fi
  retry_cmd "$retries" docker pull "$deployer_image" || die "Failed to pull Deployer image: $deployer_image"

  DEPLOYER_IMAGE_EFFECTIVE="$deployer_image"
  if registry_enabled; then
    DEPLOYER_REGISTRY_HOST="registry.${DOMAIN}"
  fi
  export DEPLOYER_IMAGE_EFFECTIVE DEPLOYER_REGISTRY_HOST
}

pre_pull_compose_images() {
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  local profile_args=("$@")
  local image
  local images=()

  step "Docker images: pre-pull compose images"
  if ! mapfile -t images < <(
    docker compose "${profile_args[@]}" --env-file "$STACK_ROOT/.env.stack" \
      -f "$SCRIPT_DIR/docker-compose.yml" config --images |
      sed '/^[[:space:]]*$/d' |
      sort -u
  ); then
    die "Failed to resolve compose image list."
  fi

  for image in "${images[@]}"; do
    [ -n "$image" ] || continue
    info "Pull image: $image"
    retry_cmd "$retries" docker pull "$image" || die "Failed to pull image after ${retries} attempts: $image"
  done
}

provided_cert_pair_for_host() {
  local host="$1"
  local dir="$STACK_ROOT/certs"
  local cert key

  cert="$dir/${host}/fullchain.pem"; key="$dir/${host}/privkey.pem"
  [[ -f "$cert" && -f "$key" ]] && { printf '%s|%s\n' "$cert" "$key"; return 0; }

  return 1
}

provided_cert_container_path() {
  local path="$1"
  local dir="$STACK_ROOT/certs"
  local rel

  case "$path" in
    "$dir"/*)
      rel="${path#"$dir"/}"
      printf '/certs/%s\n' "$rel"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

render_traefik_provided_certs_config() {
  local out="$STACK_ROOT/config/traefik/provided-certificates.yml"
  local mode="${TRAEFIK_CERT_MODE:-auto}"
  local service host pair cert key ccert ckey
  local written=0
  local seen="|"
  local body

  mkdir -p "$STACK_ROOT/config/traefik" "$STACK_ROOT/certs"
  body=$(mktemp)

  if [[ "$mode" == "auto" || "$mode" == "provided" ]]; then
    while IFS='|' read -r service host; do
      [ -n "$service" ] || continue
      if pair=$(provided_cert_pair_for_host "$host"); then
        cert="${pair%%|*}"
        key="${pair#*|}"
        if [[ "$seen" == *"|$cert|$key|"* ]]; then
          continue
        fi
        seen="${seen}${cert}|${key}|"
        ccert=$(provided_cert_container_path "$cert")
        ckey=$(provided_cert_container_path "$key")
        {
          echo "    - certFile: \"$ccert\""
          echo "      keyFile: \"$ckey\""
        } >>"$body"
        written=1
      fi
    done < <(https_service_hosts)
  fi

  {
    echo "# Generated by setup-server-stack.sh - custom TLS certificates for Traefik."
    echo "tls:"
    if [[ "$written" == "1" ]]; then
      echo "  certificates:"
      cat "$body"
    else
      echo "  certificates: []"
    fi
  } >"$out"
  rm -f "$body"
  chmod 600 "$out"

  if [[ "$mode" == "auto" || "$mode" == "provided" ]]; then
    info "Traefik custom certificates: $out ($STACK_ROOT/certs/<host>)."
  fi
}

configure_traefik_cert_mode() {
  local mode="${TRAEFIK_CERT_MODE:-auto}"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  local default_storage

  case "$mode" in
    auto)
      TRAEFIK_CERT_MODE="auto"
      TRAEFIK_CERT_RESOLVER="letsencrypt"
      TRAEFIK_ACME_EMAIL="${ACME_EMAIL:-}"
      : "${TRAEFIK_ACME_CA_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
      default_storage="$STACK_ROOT/traefik/acme.json"
      ;;
    provided)
      TRAEFIK_CERT_MODE="provided"
      TRAEFIK_CERT_RESOLVER=""
      TRAEFIK_ACME_EMAIL="${ACME_EMAIL:-provided@example.invalid}"
      : "${TRAEFIK_ACME_CA_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
      default_storage="$STACK_ROOT/traefik/acme-provided.json"
      ;;
    letsencrypt)
      TRAEFIK_CERT_MODE="letsencrypt"
      TRAEFIK_CERT_RESOLVER="letsencrypt"
      TRAEFIK_ACME_EMAIL="${ACME_EMAIL:-}"
      : "${TRAEFIK_ACME_CA_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
      default_storage="$STACK_ROOT/traefik/acme.json"
      ;;
    staging)
      TRAEFIK_CERT_MODE="staging"
      TRAEFIK_CERT_RESOLVER="letsencrypt"
      TRAEFIK_ACME_EMAIL="${ACME_EMAIL:-}"
      : "${TRAEFIK_ACME_CA_SERVER:=https://acme-staging-v02.api.letsencrypt.org/directory}"
      default_storage="$STACK_ROOT/traefik/acme-staging.json"
      ;;
    selfsigned)
      TRAEFIK_CERT_MODE="selfsigned"
      TRAEFIK_CERT_RESOLVER=""
      TRAEFIK_ACME_EMAIL="${ACME_EMAIL:-selfsigned@example.invalid}"
      : "${TRAEFIK_ACME_CA_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
      default_storage="$STACK_ROOT/traefik/acme-selfsigned.json"
      ;;
    *)
      die "TRAEFIK_CERT_MODE must be one of: auto, provided, letsencrypt, staging, selfsigned."
      ;;
  esac

  : "${TRAEFIK_ACME_STORAGE_FILE:=$default_storage}"
  mkdir -p "$STACK_ROOT/certs"
  TRAEFIK_TLS_CHECK_WAIT_SECONDS="${TRAEFIK_TLS_CHECK_WAIT_SECONDS:-20}"
  [[ "$TRAEFIK_TLS_CHECK_WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "TRAEFIK_TLS_CHECK_WAIT_SECONDS must be a number >= 0"

  export TRAEFIK_CERT_MODE TRAEFIK_CERT_RESOLVER TRAEFIK_ACME_EMAIL TRAEFIK_ACME_CA_SERVER TRAEFIK_ACME_STORAGE_FILE TRAEFIK_TLS_CHECK_WAIT_SECONDS
}

validate_tls_domain_config() {
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] || return 0
  configure_traefik_cert_mode

  local domain="${DOMAIN:-}"
  local email="${ACME_EMAIL:-}"
  local domain_lc email_lc

  domain_lc=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  email_lc=$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')

  [ -n "$domain" ] || die "DOMAIN is empty — set your real domain in .env (see .env.example)."

  case "$domain_lc" in
    example.com | localhost | local | test | changeme)
      die "DOMAIN is still a placeholder ($domain) — set your real domain in .env before install."
      ;;
  esac

  if [[ ! "$domain_lc" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "DOMAIN looks invalid ($domain) — expected an FQDN like stack.company.com."
  fi

  if [[ "$TRAEFIK_CERT_MODE" == "selfsigned" || "$TRAEFIK_CERT_MODE" == "provided" ]]; then
    return 0
  fi

  [ -n "$email" ] || die "ACME_EMAIL is empty — set a real email for Let's Encrypt in .env."

  case "$email_lc" in
    you@example.com | admin@example.com | test@example.com | noreply@example.com)
      die "ACME_EMAIL is still a placeholder ($email) — set a real email in .env before install."
      ;;
  esac

  if [[ ! "$email_lc" =~ ^[a-z0-9._%+-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "ACME_EMAIL looks invalid ($email) — expected an address like admin@company.com."
  fi
}

validate_traefik_required() {
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] && return 0

  local need=()
  [[ "${ENABLE_PORTAINER:-0}" == "1" ]] && need+=(ENABLE_PORTAINER)
  [[ "${ENABLE_DOKU:-0}" == "1" ]] && need+=(ENABLE_DOKU)
  [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]] && need+=(ENABLE_SEMAPHORE)
  [[ "${ENABLE_GITEA:-0}" == "1" ]] && need+=(ENABLE_GITEA)
  [[ "${ENABLE_DUPLICATI:-0}" == "1" ]] && need+=(ENABLE_DUPLICATI)
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] && need+=(ENABLE_GOCRON)
  [[ "${ENABLE_UPTIME_KUMA:-0}" == "1" ]] && need+=(ENABLE_UPTIME_KUMA)
  [[ "${ENABLE_BESZEL:-0}" == "1" ]] && need+=(ENABLE_BESZEL)
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] && need+=(ENABLE_FILEBROWSER)
  [[ "${ENABLE_NGINX:-0}" == "1" ]] && need+=(ENABLE_NGINX)
  [[ "${ENABLE_REGISTRY:-0}" == "1" ]] && need+=(ENABLE_REGISTRY)
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-0}}" == "1" ]] && need+=(ENABLE_DOCKER_AUTH)
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && need+=(ENABLE_DEPLOYER)
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && need+=(ENABLE_MONGO_EXPRESS)
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && need+=(ENABLE_PGADMIN)
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && need+=(ENABLE_ADMINER)

  ((${#need[@]})) || return 0

  die "ENABLE_TRAEFIK=0 but HTTPS services are still enabled (${need[*]}). Set ENABLE_TRAEFIK=1 or turn those services off (Watchtower and DB engines without web UIs may stay on)."
}

validate_enable_flags() {
  ENABLE_TRAEFIK="${ENABLE_TRAEFIK:-0}"
  ENABLE_PORTAINER="${ENABLE_PORTAINER:-0}"
  ENABLE_DOKU="${ENABLE_DOKU:-0}"
  ENABLE_WATCHTOWER="${ENABLE_WATCHTOWER:-0}"
  ENABLE_SEMAPHORE="${ENABLE_SEMAPHORE:-0}"
  ENABLE_GITEA="${ENABLE_GITEA:-0}"
  ENABLE_GITEA_RUNNER="${ENABLE_GITEA_RUNNER:-${ENABLE_GITEA}}"
  ENABLE_DUPLICATI="${ENABLE_DUPLICATI:-0}"
  ENABLE_GOCRON="${ENABLE_GOCRON:-0}"
  ENABLE_UPTIME_KUMA="${ENABLE_UPTIME_KUMA:-0}"
  ENABLE_BESZEL="${ENABLE_BESZEL:-0}"
  ENABLE_BESZEL_AGENT="${ENABLE_BESZEL_AGENT:-${ENABLE_BESZEL}}"
  ENABLE_FILEBROWSER="${ENABLE_FILEBROWSER:-0}"
  ENABLE_NGINX="${ENABLE_NGINX:-0}"
  ENABLE_REGISTRY="${ENABLE_REGISTRY:-0}"
  ENABLE_DOCKER_AUTH="${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY}}"
  ENABLE_DEPLOYER="${ENABLE_DEPLOYER:-0}"
  ENABLE_MONGO="${ENABLE_MONGO:-0}"
  ENABLE_POSTGRES="${ENABLE_POSTGRES:-0}"
  ENABLE_MARIADB="${ENABLE_MARIADB:-0}"
  ENABLE_MYSQL="${ENABLE_MYSQL:-0}"
  ENABLE_MONGO_EXPRESS="${ENABLE_MONGO_EXPRESS:-0}"
  ENABLE_PGADMIN="${ENABLE_PGADMIN:-0}"
  ENABLE_ADMINER="${ENABLE_ADMINER:-0}"
  EXTRA_REGISTRY_COUNT="${EXTRA_REGISTRY_COUNT:-0}"
  REGISTRY_OPERATION_RETRIES="${REGISTRY_OPERATION_RETRIES:-3}"
  REGISTRY_RETRY_BACKOFF_BASE_SEC="${REGISTRY_RETRY_BACKOFF_BASE_SEC:-2}"
  REGISTRY_RETRY_BACKOFF_MAX_SEC="${REGISTRY_RETRY_BACKOFF_MAX_SEC:-10}"
  configure_traefik_cert_mode
  [[ "$EXTRA_REGISTRY_COUNT" =~ ^[0-9]+$ ]] || die "EXTRA_REGISTRY_COUNT must be a number >= 0"
  (( EXTRA_REGISTRY_COUNT >= 0 )) || die "EXTRA_REGISTRY_COUNT must be >= 0"
  [[ "$REGISTRY_OPERATION_RETRIES" =~ ^[0-9]+$ ]] || die "REGISTRY_OPERATION_RETRIES must be a number >= 1"
  (( REGISTRY_OPERATION_RETRIES >= 1 )) || die "REGISTRY_OPERATION_RETRIES must be >= 1"
  [[ "$REGISTRY_RETRY_BACKOFF_BASE_SEC" =~ ^[0-9]+$ ]] || die "REGISTRY_RETRY_BACKOFF_BASE_SEC must be a number >= 1"
  (( REGISTRY_RETRY_BACKOFF_BASE_SEC >= 1 )) || die "REGISTRY_RETRY_BACKOFF_BASE_SEC must be >= 1"
  [[ "$REGISTRY_RETRY_BACKOFF_MAX_SEC" =~ ^[0-9]+$ ]] || die "REGISTRY_RETRY_BACKOFF_MAX_SEC must be a number >= 1"
  (( REGISTRY_RETRY_BACKOFF_MAX_SEC >= 1 )) || die "REGISTRY_RETRY_BACKOFF_MAX_SEC must be >= 1"
  (( REGISTRY_RETRY_BACKOFF_MAX_SEC >= REGISTRY_RETRY_BACKOFF_BASE_SEC )) || die "REGISTRY_RETRY_BACKOFF_MAX_SEC must be >= REGISTRY_RETRY_BACKOFF_BASE_SEC"
  local i host user pass
  for ((i = 1; i <= EXTRA_REGISTRY_COUNT; i++)); do
    local host_var="EXTRA_REGISTRY_${i}_HOST"
    local user_var="EXTRA_REGISTRY_${i}_USER"
    local pass_var="EXTRA_REGISTRY_${i}_PASSWORD"
    host="$(normalize_registry_host "${!host_var:-}")"
    user="${!user_var:-}"
    pass="${!pass_var:-}"
    [ -n "$host" ] || die "EXTRA_REGISTRY_${i}_HOST is empty."
    [ -n "$user" ] || die "EXTRA_REGISTRY_${i}_USER is empty."
    [ -n "$pass" ] || die "EXTRA_REGISTRY_${i}_PASSWORD is empty."
  done
  [[ "${ENABLE_DOCKER_AUTH:-0}" != "1" ]] || [[ "${ENABLE_REGISTRY:-0}" == "1" ]] || die "ENABLE_DOCKER_AUTH=1 requires ENABLE_REGISTRY=1"
  [[ "${ENABLE_REGISTRY:-0}" != "1" ]] || [[ "${ENABLE_DOCKER_AUTH:-0}" == "1" ]] || die "ENABLE_REGISTRY=1 requires ENABLE_DOCKER_AUTH=1 (registry token auth)."
  if [[ "${ENABLE_REGISTRY:-0}" == "1" ]]; then
    : "${REGISTRY_PULL_USER:=registrypull}"
    [ -n "$REGISTRY_PULL_USER" ] || die "REGISTRY_PULL_USER is empty."
    [[ "$REGISTRY_PULL_USER" != "$REGISTRY_USER" ]] || die "REGISTRY_PULL_USER must differ from REGISTRY_USER ($REGISTRY_USER)."
  fi
  [[ "${ENABLE_BESZEL_AGENT:-0}" != "1" ]] || [[ "${ENABLE_BESZEL:-0}" == "1" ]] || die "ENABLE_BESZEL_AGENT=1 requires ENABLE_BESZEL=1 (the local agent self-registers with the local hub)."
  [[ "${ENABLE_GITEA_RUNNER:-0}" != "1" ]] || [[ "${ENABLE_GITEA:-0}" == "1" ]] || die "ENABLE_GITEA_RUNNER=1 requires ENABLE_GITEA=1 (the local runner registers with the local Gitea hub)."
  [[ "${ENABLE_MONGO_EXPRESS:-0}" != "1" ]] || [[ "${ENABLE_MONGO:-0}" == "1" ]] || die "ENABLE_MONGO_EXPRESS=1 requires ENABLE_MONGO=1"
  [[ "${ENABLE_PGADMIN:-0}" != "1" ]] || [[ "${ENABLE_POSTGRES:-0}" == "1" ]] || die "ENABLE_PGADMIN=1 requires ENABLE_POSTGRES=1"
  # MariaDB/MySQL create an app user only with a database to grant on; a user
  # without a database would have no privileges, so require them together.
  [[ -z "${MARIADB_USER:-}" ]] || [[ -n "${MARIADB_DATABASE:-}" ]] || die "MARIADB_USER set without MARIADB_DATABASE — set MARIADB_DATABASE too, or leave both empty for root-only."
  [[ -z "${MYSQL_USER:-}" ]] || [[ -n "${MYSQL_DATABASE:-}" ]] || die "MYSQL_USER set without MYSQL_DATABASE — set MYSQL_DATABASE too, or leave both empty for root-only."
  if [[ "${ENABLE_ADMINER:-0}" == "1" ]]; then
    [[ "${ENABLE_MONGO:-0}" == "1" ]] \
      || [[ "${ENABLE_POSTGRES:-0}" == "1" ]] \
      || [[ "${ENABLE_MARIADB:-0}" == "1" ]] \
      || [[ "${ENABLE_MYSQL:-0}" == "1" ]] \
      || die "ENABLE_ADMINER=1 requires ENABLE_MONGO=1 and/or ENABLE_POSTGRES=1 and/or ENABLE_MARIADB=1 and/or ENABLE_MYSQL=1"
  fi
  if [[ "${ENABLE_NGINX:-0}" == "1" ]]; then
    local nginx_host
    nginx_host="$(resolve_nginx_host)"
    [[ "$nginx_host" != http://* && "$nginx_host" != https://* ]] || die "NGINX_HOST must be a host only, without http:// or https://"
    [[ "$nginx_host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
      || die "NGINX_HOST looks invalid ($nginx_host) — expected an FQDN like company.com or www.company.com."
  fi
  if [[ "${ENABLE_DEPLOYER:-0}" == "1" ]]; then
    resolve_deployer_auth_mode >/dev/null \
      || die "DEPLOYER_AUTH_MODE must be one of: dual, api, ui."
  fi
  if [[ -n "${REGISTRY_SEED_IMAGES:-}" ]] && [[ "${ENABLE_REGISTRY:-0}" != "1" ]]; then
    warn "REGISTRY_SEED_IMAGES set but ENABLE_REGISTRY=0 — seed image push skipped."
  fi
  warn_filebrowser_root_path
  validate_gocron_software
  validate_deployer_software
  validate_traefik_required
  validate_tls_domain_config
}

compose_profiles() {
  local p=""
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] && p="${p},traefik"
  [[ "${ENABLE_PORTAINER:-0}" == "1" ]] && p="${p},portainer"
  [[ "${ENABLE_DOKU:-0}" == "1" ]] && p="${p},doku"
  [[ "${ENABLE_WATCHTOWER:-0}" == "1" ]] && p="${p},watchtower"
  [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]] && p="${p},semaphore"
  [[ "${ENABLE_GITEA:-0}" == "1" ]] && p="${p},gitea"
  [[ "${ENABLE_GITEA_RUNNER:-0}" == "1" ]] && p="${p},gitea-runner"
  [[ "${ENABLE_DUPLICATI:-0}" == "1" ]] && p="${p},duplicati"
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] && p="${p},gocron"
  [[ "${ENABLE_UPTIME_KUMA:-0}" == "1" ]] && p="${p},kuma"
  [[ "${ENABLE_BESZEL:-0}" == "1" ]] && p="${p},beszel"
  [[ "${ENABLE_BESZEL_AGENT:-0}" == "1" ]] && p="${p},beszel-agent"
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] && p="${p},filebrowser"
  [[ "${ENABLE_NGINX:-0}" == "1" ]] && p="${p},nginx"
  [[ "${ENABLE_REGISTRY:-0}" == "1" ]] && p="${p},registry"
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-0}}" == "1" ]] && p="${p},registry-auth"
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && p="${p},deployer"
  [[ "${ENABLE_MONGO:-0}" == "1" ]] && p="${p},mongo"
  [[ "${ENABLE_POSTGRES:-0}" == "1" ]] && p="${p},postgres"
  [[ "${ENABLE_MARIADB:-0}" == "1" ]] && p="${p},mariadb"
  [[ "${ENABLE_MYSQL:-0}" == "1" ]] && p="${p},mysql"
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && p="${p},mongo-express"
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && p="${p},pgadmin"
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && p="${p},adminer"
  echo "${p#,}"
}

setup_unattended() {
  [[ "${INSTALL_UNATTENDED_UPGRADES:-1}" == "1" ]] || return 0
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not found — skipping unattended-upgrades."
    return 0
  fi
  step "unattended-upgrades"
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  ensure_dns_ready
  retry_run "$retries" apt-get -o DPkg::Lock::Timeout=300 update -o APT::Update::Error-Mode=any -qq
  retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq unattended-upgrades
  RUN dpkg-reconfigure -f noninteractive -plow unattended-upgrades || true
  info "Unattended security upgrades enabled."
}

create_admin_user() {
  [[ "${CREATE_ADMIN_USER:-1}" == "1" ]] || return 0
  local admin_username="${ADMIN_USERNAME:-${STACK_ADMIN_USER:-adminops}}"
  [ -n "$admin_username" ] || err "ADMIN_USERNAME is empty."
  [ "$admin_username" != "root" ] || return 0
  step "Admin user: $admin_username"
  if id "$admin_username" &>/dev/null; then
    info "User $admin_username already exists."
  else
    RUN useradd -m -s /bin/bash -G sudo "$admin_username"
    info "Created user $admin_username (sudo group)."
  fi
  RUN usermod -aG docker "$admin_username" 2>/dev/null || true
  if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    RUN mkdir -p "/home/$admin_username/.ssh"
    echo "$SSH_PUBLIC_KEY" | RUN tee "/home/$admin_username/.ssh/authorized_keys" >/dev/null
    RUN chmod 700 "/home/$admin_username/.ssh"
    RUN chmod 600 "/home/$admin_username/.ssh/authorized_keys"
    RUN chown -R "$admin_username:$admin_username" "/home/$admin_username/.ssh"
    info "SSH key written for $admin_username."
  else
    warn "SSH_PUBLIC_KEY empty — key not added."
  fi
}

configure_admin_sudo_nopasswd() {
  [[ "${ADMIN_SUDO_NOPASSWD:-1}" == "1" ]] || return 0
  local admin_username="${ADMIN_USERNAME:-${STACK_ADMIN_USER:-adminops}}"
  [ -n "$admin_username" ] || return 0
  [ "$admin_username" != "root" ] || return 0
  id "$admin_username" &>/dev/null || return 0
  step "sudo: NOPASSWD for $admin_username"
  local f="/etc/sudoers.d/99-setup-server-stack-admin"
  umask 077
  {
    echo "# Generated by setup-server-stack.sh"
    echo "Defaults:${admin_username} !requiretty"
    echo "${admin_username} ALL=(ALL) NOPASSWD: ALL"
  } | RUN tee "$f" >/dev/null
  RUN chmod 440 "$f"
  if command -v visudo &>/dev/null; then
    RUN visudo -c -f "$f" || err "Invalid sudoers: $f"
  fi
}

apply_ssh_hardening() {
  [[ "${APPLY_SSH_HARDENING:-1}" == "1" ]] || return 0
  if [ -z "${SSH_PUBLIC_KEY:-}" ]; then
    warn "APPLY_SSH_HARDENING=1 skipped: no SSH_PUBLIC_KEY."
    return 0
  fi
  local admin_username="${ADMIN_USERNAME:-${STACK_ADMIN_USER:-adminops}}"
  local sshd_dropin="/etc/ssh/sshd_config.d/01-setup-server-stack.conf"
  step "SSH: hardening"
  RUN mkdir -p /etc/ssh/sshd_config.d
  RUN rm -f /etc/ssh/sshd_config.d/60-setup-server-stack.conf
  cat <<EOF | RUN tee "$sshd_dropin" >/dev/null
# Generated by setup-server-stack.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 6
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
  if [ -n "$admin_username" ] && [ "$admin_username" != "root" ] && id "$admin_username" &>/dev/null; then
    echo "AllowUsers $admin_username" | RUN tee -a "$sshd_dropin" >/dev/null
  fi
  if RUN sshd -t 2>/dev/null; then
    RUN systemctl reload ssh 2>/dev/null || RUN systemctl reload sshd
    info "sshd reloaded."
  else
    err "Invalid sshd configuration."
  fi
}

setup_fail2ban() {
  [[ "${INSTALL_FAIL2BAN:-1}" == "1" ]] || return 0
  local ssh_port="${SSH_PORT:-22}"
  if command -v apt-get >/dev/null 2>&1; then
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get -o DPkg::Lock::Timeout=300 update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq fail2ban
    cat <<EOF | RUN tee /etc/fail2ban/jail.d/setup-server-stack.local >/dev/null
[sshd]
enabled = true
port = ${ssh_port}
logpath = %(sshd_log)s
maxretry = 7
findtime = 10m
bantime = 1h
EOF
    RUN systemctl enable fail2ban >/dev/null 2>&1 || true
    RUN systemctl restart fail2ban >/dev/null 2>&1 || true
    info "fail2ban: enabled (sshd, port ${ssh_port})."
  else
    warn "apt-get not found — install fail2ban manually."
  fi
}

ufw_apply_rules() {
  local ssh_port="${SSH_PORT:-22}"
  RUN ufw default deny incoming &&
    RUN ufw default allow outgoing &&
    RUN ufw allow "${ssh_port}/tcp" comment 'SSH' &&
    RUN ufw allow 80/tcp comment 'HTTP' &&
    RUN ufw allow 443/tcp comment 'HTTPS'
  if [[ "${ENABLE_GITEA:-0}" == "1" ]]; then
    RUN ufw allow "${GITEA_SSH_PORT:-2222}/tcp" comment 'Gitea SSH'
  fi
  RUN ufw --force enable
}

setup_ufw() {
  local ufw_enable="${UFW_ENABLE:-1}"
  [[ "$ufw_enable" == "1" ]] || return 0
  local ssh_port="${SSH_PORT:-22}"
  if ! command -v ufw &>/dev/null; then
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get -o DPkg::Lock::Timeout=300 update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq ufw
  fi
  if ufw_apply_rules; then
    if [[ "${ENABLE_GITEA:-0}" == "1" ]]; then
      info "UFW: ports ${ssh_port}, 80, 443, ${GITEA_SSH_PORT:-2222} (Gitea SSH)."
    else
      info "UFW: ports ${ssh_port}, 80, 443."
    fi
    return 0
  fi
  warn "UFW: iptables-restore failed, trying iptables-legacy..."
  RUN ufw disable 2>/dev/null || true
  if ! [ -x /usr/sbin/iptables-legacy ] && command -v apt-get &>/dev/null; then
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq iptables 2>/dev/null || true
  fi
  if command -v update-alternatives &>/dev/null; then
    if [ -x /usr/sbin/iptables-legacy ]; then
      RUN update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
    fi
    if [ -x /usr/sbin/ip6tables-legacy ]; then
      RUN update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
    fi
  fi
  if ufw_apply_rules; then
    info "UFW: enabled after switching to iptables-legacy."
    return 0
  fi
  warn "UFW not enabled — open ${ssh_port}, 80 and 443 in the hosting panel."
}

https_service_hosts() {
  local d="${DOMAIN}"
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] && echo "Traefik dashboard|traefik.${d}"
  if registry_enabled; then
    echo "Registry|registry.${d}"
    echo "Registry auth|registry-auth.${d}"
  fi
  [[ "${ENABLE_PORTAINER:-0}" == "1" ]] && echo "Portainer|portainer.${d}"
  [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]] && echo "Semaphore|semaphore.${d}"
  [[ "${ENABLE_GITEA:-0}" == "1" ]] && echo "Gitea|${GITEA_HOST:-gitea.${d}}"
  [[ "${ENABLE_DOKU:-0}" == "1" ]] && echo "Doku|doku.${d}"
  [[ "${ENABLE_DUPLICATI:-0}" == "1" ]] && echo "Duplicati|duplicati.${d}"
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] && echo "gocron|gocron.${d}"
  [[ "${ENABLE_UPTIME_KUMA:-0}" == "1" ]] && echo "Uptime Kuma|kuma.${d}"
  [[ "${ENABLE_BESZEL:-0}" == "1" ]] && echo "Beszel|beszel.${d}"
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] && echo "Filebrowser|filebrowser.${d}"
  [[ "${ENABLE_NGINX:-0}" == "1" ]] && echo "NGINX static site|$(resolve_nginx_host)"
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && echo "Deployer|deployer.${d}"
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && echo "mongo-express|mongo-express.${d}"
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && echo "pgAdmin|pgadmin.${d}"
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && echo "Adminer|adminer.${d}"
  return 0
}

acme_has_certificate_for_host() {
  local host="$1"
  local acme_file="${TRAEFIK_ACME_STORAGE_FILE:-$STACK_ROOT/traefik/acme.json}"
  [[ -s "$acme_file" ]] || return 1
  grep -F "\"$host\"" "$acme_file" >/dev/null 2>&1
}

wait_acme_certificate_for_host() {
  local host="$1"
  local wait_seconds="${TRAEFIK_TLS_CHECK_WAIT_SECONDS:-20}"
  local waited=0

  acme_has_certificate_for_host "$host" && return 0
  (( wait_seconds == 0 )) && return 1

  while (( waited < wait_seconds )); do
    sleep 2
    waited=$((waited + 2))
    acme_has_certificate_for_host "$host" && return 0
  done

  return 1
}

print_recent_traefik_acme_logs() {
  local host="$1"
  local lines retry_after

  lines=$(docker logs --since 15m traefik 2>&1 \
    | grep -F "$host" \
    | tail -n 10 || true)

  if [ -z "$lines" ]; then
    lines=$(docker logs --since 15m traefik 2>&1 \
      | grep -Ei "(acme|letsencrypt|certificate|challenge|rate|limit|error)" \
      | tail -n 5 || true)
  fi

  if [ -n "$lines" ]; then
    if printf '%s\n' "$lines" | grep -qi 'rateLimited'; then
      retry_after=$(printf '%s\n' "$lines" \
        | sed -nE 's/.*retry after ([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}( UTC|Z)).*/\1/p' \
        | tail -n 1)
      if [ -n "$retry_after" ]; then
        warn "TLS RATE LIMIT: ${host} is blocked by Let's Encrypt until about ${retry_after}."
      else
        warn "TLS RATE LIMIT: ${host} is currently blocked by Let's Encrypt."
      fi
      echo "    After that time, retry with: docker compose --env-file .env.stack -f docker-compose.yml restart traefik"
    fi
    echo "    Recent Traefik ACME logs:"
    printf '%s\n' "$lines" | sed 's/^/      /'
  else
    echo "    Recent Traefik ACME logs: no matching lines in the last 15 minutes."
  fi
}

export_production_acme_certificates() {
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] || return 0
  [[ "${TRAEFIK_CERT_MODE:-auto}" == "auto" || "${TRAEFIK_CERT_MODE:-auto}" == "letsencrypt" ]] || return 0
  [[ "${TRAEFIK_ACME_CA_SERVER:-}" == "https://acme-v02.api.letsencrypt.org/directory" ]] || return 0

  local acme_file="${TRAEFIK_ACME_STORAGE_FILE:-$STACK_ROOT/traefik/acme.json}"
  local certs_dir="$STACK_ROOT/certs"
  [[ -s "$acme_file" ]] || return 0

  if ! command -v python3 >/dev/null 2>&1; then
    warn "Cannot export Let's Encrypt certificates to $certs_dir: python3 is not installed."
    return 0
  fi

  local hosts_file output status host message
  hosts_file=$(mktemp)
  https_service_hosts | awk -F'|' 'NF >= 2 && $2 != "" { print $2 }' | sort -u >"$hosts_file"

  output=$(ACME_FILE="$acme_file" CERTS_DIR="$certs_dir" HOSTS_FILE="$hosts_file" python3 <<'PY'
import base64
import json
import os
import pathlib
import sys

acme_file = pathlib.Path(os.environ["ACME_FILE"])
certs_dir = pathlib.Path(os.environ["CERTS_DIR"])
hosts_file = pathlib.Path(os.environ["HOSTS_FILE"])
hosts = [line.strip() for line in hosts_file.read_text(encoding="utf-8").splitlines() if line.strip()]

try:
    data = json.loads(acme_file.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"WARN|-|cannot parse {acme_file}: {exc}")
    sys.exit(0)

certs_by_host = {}
for resolver in data.values():
    items = resolver.get("Certificates", []) if isinstance(resolver, dict) else []
    for item in items:
        domain = item.get("domain") or {}
        names = [domain.get("main"), *(domain.get("sans") or [])]
        for name in names:
            if name:
                certs_by_host[name] = item

for host in hosts:
    item = certs_by_host.get(host)
    if not item:
        continue
    target_dir = certs_dir / host
    cert_file = target_dir / "fullchain.pem"
    key_file = target_dir / "privkey.pem"
    if cert_file.exists() or key_file.exists():
        print(f"SKIP|{host}|existing files kept")
        continue
    try:
        cert = base64.b64decode(item["certificate"])
        key = base64.b64decode(item["key"])
        target_dir.mkdir(parents=True, exist_ok=True)
        cert_file.write_bytes(cert)
        key_file.write_bytes(key)
        os.chmod(target_dir, 0o700)
        os.chmod(cert_file, 0o644)
        os.chmod(key_file, 0o600)
        print(f"EXPORT|{host}|{cert_file}")
    except Exception as exc:
        print(f"WARN|{host}|{exc}")
PY
)
  rm -f "$hosts_file"

  while IFS='|' read -r status host message; do
    [ -n "$status" ] || continue
    case "$status" in
      EXPORT) info "TLS export: saved production Let's Encrypt certificate for $host to $message." ;;
      SKIP) info "TLS export: $host skipped, $message." ;;
      WARN) warn "TLS export: $host: $message" ;;
    esac
  done <<<"$output"
}

diagnose_traefik_tls() {
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] || return 0

  local mode="${TRAEFIK_CERT_MODE:-letsencrypt}"
  local acme_file="${TRAEFIK_ACME_STORAGE_FILE:-$STACK_ROOT/traefik/acme.json}"
  local service host missing=0

  step "Traefik TLS: certificate diagnostics"

  case "$mode" in
    auto)
      ;;
    provided)
      warn "TRAEFIK_CERT_MODE=provided: Let's Encrypt is disabled. Only custom certificates from $STACK_ROOT/certs/<host> will be used."
      ;;
    selfsigned)
      warn "TRAEFIK_CERT_MODE=selfsigned: Let's Encrypt is disabled. HTTPS is available, but browsers will show an untrusted certificate warning."
      while IFS='|' read -r service host; do
        [ -n "$service" ] || continue
        warn "TLS TEST: ${service}: https://${host} uses Traefik test/self-signed TLS. Browser warning is expected."
      done < <(https_service_hosts)
      return 0
      ;;
    staging)
      warn "TRAEFIK_CERT_MODE=staging: Let's Encrypt staging certificates are intentionally untrusted by browsers."
      ;;
    letsencrypt)
      ;;
    *)
      warn "Unknown TRAEFIK_CERT_MODE=${mode}; TLS diagnostics will still check $acme_file."
      ;;
  esac

  while IFS='|' read -r service host; do
    [ -n "$service" ] || continue
    echo "  TLS check: ${service} -> https://${host}"

    if [[ "$mode" == "auto" || "$mode" == "provided" ]] && provided_cert_pair_for_host "$host" >/dev/null 2>&1; then
      info "TLS OK: ${service}: custom certificate is configured for ${host}."
    elif wait_acme_certificate_for_host "$host"; then
      if [[ "$mode" == "staging" ]]; then
        warn "TLS TEST: ${service}: ACME staging certificate is present for ${host}; browser warning is expected."
      else
        info "TLS OK: ${service}: Let's Encrypt certificate is present for ${host}."
      fi
    else
      missing=$((missing + 1))
      if [[ "$mode" == "provided" ]]; then
        warn "TLS WARN: ${service}: no custom certificate for ${host}. Browser warning is expected."
        echo "    Add $STACK_ROOT/certs/${host}/fullchain.pem and $STACK_ROOT/certs/${host}/privkey.pem."
      else
        warn "TLS WARN: ${service}: no ACME certificate for ${host} in ${acme_file}. Browser warning is expected."
        echo "    Check DNS A/AAAA records, open ports 80/443, Let's Encrypt rate limits, and Traefik logs."
        print_recent_traefik_acme_logs "$host"
      fi
    fi
  done < <(https_service_hosts)

  if (( missing > 0 )); then
    warn "TLS summary: ${missing} HTTPS host(s) have no ACME certificate yet. The stack may be running, but browsers can warn until certificates are issued."
  fi
}

diagnose_compose_failure() {
  local profile_args=("$@")
  local unhealthy

  warn "Docker Compose did not finish successfully. Current service state:"
  docker compose "${profile_args[@]}" --env-file "$STACK_ROOT/.env.stack" \
    -f "$SCRIPT_DIR/docker-compose.yml" ps || true

  if ! mapfile -t unhealthy < <(
    docker ps -a --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null | sort -u
  ); then
    return 0
  fi

  ((${#unhealthy[@]})) || return 0

  warn "Unhealthy containers detected: ${unhealthy[*]}"
  local c
  for c in "${unhealthy[@]}"; do
    echo ""
    warn "Diagnostics for ${c}:"
    docker inspect -f '  status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || true
    docker inspect -f '{{range .State.Health.Log}}  healthcheck: exit={{.ExitCode}} output={{printf "%q" .Output}}{{"\n"}}{{end}}' "$c" 2>/dev/null | tail -n 5 || true
    docker logs --tail 40 "$c" 2>&1 | sed "s/^/  ${c} log: /" || true
  done
}

print_urls() {
  local d="${DOMAIN}"
  echo ""
  echo "=== HTTPS URLs (TRAEFIK_CERT_MODE=${TRAEFIK_CERT_MODE:-letsencrypt}) ==="
  [[ "${ENABLE_TRAEFIK:-0}" == "1" ]] && echo "  Traefik:     https://traefik.${d}"
  if registry_enabled; then
    echo "  Registry:      https://registry.${d}"
    echo "  Registry auth: https://registry-auth.${d}"
  fi
  [[ "${ENABLE_PORTAINER:-0}" == "1" ]] && echo "  Portainer:   https://portainer.${d}"
  [[ "${ENABLE_SEMAPHORE:-0}" == "1" ]] && echo "  Semaphore:   https://semaphore.${d}"
  if [[ "${ENABLE_GITEA:-0}" == "1" ]]; then
    echo "  Gitea:       https://${GITEA_HOST:-gitea.${d}}  (login ${GITEA_ADMIN:-${STACK_ADMIN_USER:-admin}}, password in GITEA_ADMIN_PASSWORD in .secrets)"
    echo "                 git+ssh: ssh://${GITEA_HOST:-gitea.${d}}:${GITEA_SSH_PORT:-2222}/<owner>/<repo>.git"
    [[ "${ENABLE_GITEA_RUNNER:-0}" == "1" ]] && echo "                 Actions runner: ${GITEA_RUNNER_NAME:-stack-runner} (auto-registered when possible)"
  fi
  [[ "${ENABLE_DOKU:-0}" == "1" ]] && echo "  Doku:        https://doku.${d}"
  [[ "${ENABLE_DUPLICATI:-0}" == "1" ]] && echo "  Duplicati:   https://duplicati.${d}"
  [[ "${ENABLE_GOCRON:-0}" == "1" ]] && echo "  gocron:      https://gocron.${d}  (no built-in login — HTTPS edge only; jobs in UI or config.yaml)"
  [[ "${ENABLE_UPTIME_KUMA:-0}" == "1" ]] && echo "  Kuma:        https://kuma.${d}"
  [[ "${ENABLE_BESZEL:-0}" == "1" ]] && echo "  Beszel:      https://beszel.${d}  (login ${BESZEL_USER_EMAIL:-${STACK_ADMIN_EMAIL}}, password in BESZEL_USER_PASSWORD in .secrets)"
  [[ "${ENABLE_BESZEL_AGENT:-0}" == "1" ]] && echo "                 this server is auto-registered in Beszel as a monitored system."
  [[ "${ENABLE_FILEBROWSER:-0}" == "1" ]] && echo "  Filebrowser: https://filebrowser.${d}  (rw: ${FILEBROWSER_ROOT_PATH:-/opt}; login ${FILEBROWSER_USER:-${STACK_ADMIN_USER:-admin}}, password in FILEBROWSER_PASSWORD)"
  [[ "${ENABLE_NGINX:-0}" == "1" ]] && echo "  NGINX site:  https://$(resolve_nginx_host)  (files: $(resolve_nginx_public_path))"
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && echo "  Deployer:    https://deployer.${d}"
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && echo "  mongo-express: https://mongo-express.${d}"
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && echo "  pgAdmin:       https://pgadmin.${d}  (Postgres server pre-registered; pgAdmin login — PGADMIN_EMAIL / PGADMIN_PASSWORD)"
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && echo "  Adminer:       https://adminer.${d}"
  echo ""
  echo "Volumes and config: STACK_ROOT=$STACK_ROOT"
  echo "Compose env: $STACK_ROOT/.env.stack (generated, chmod 600)."
  echo "Secrets: $SCRIPT_DIR/.secrets (do not commit)."
  echo "Traefik dashboard: user admin, password in TRAEFIK_DASHBOARD_PASSWORD in .secrets."
  echo "Doku: user ${DOKU_DASHBOARD_USER:-${STACK_ADMIN_USER:-doku}}, password in DOKU_DASHBOARD_PASSWORD in .secrets (Traefik Basic Auth)."
  echo "Filebrowser: user ${FILEBROWSER_USER:-${STACK_ADMIN_USER:-admin}}, password in FILEBROWSER_PASSWORD in .secrets."
  registry_enabled && echo "docker login (push):  docker login registry.${d}  # user ${REGISTRY_USER}"
  registry_enabled && echo "docker login (pull):  docker login registry.${d}  # user ${REGISTRY_PULL_USER:-registrypull}"
  return 0
}

main() {
  parse_args "$@"
  export ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
  require_root

  if [[ "${SSH_HARDENING_ONLY:-0}" == "1" ]]; then
    [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE"
    load_env
    apply_ssh_hardening
    info "SSH hardening applied."
    return 0
  fi

  [[ -f "$SCRIPT_DIR/.env.example" ]] || die "Missing .env.example"
  [[ -f "$ENV_FILE" ]] || cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"

  step "setup-server-stack v${VERSION:-?}"
  ensure_openssl
  load_env
  ensure_docker_ready
  validate_enable_flags

  if [[ "$FORCE_SECRETS" -eq 1 ]]; then
    echo "--force-secrets: regenerating secrets in .secrets (acme.json untouched)."
  fi

  create_admin_user
  configure_admin_sudo_nopasswd
  setup_unattended
  setup_fail2ban
  setup_ufw

  ensure_dirs
  touch_acme
  ensure_network

  guard_existing_stack_requires_secrets
  write_stack_secrets
  if registry_enabled; then
    gen_registry_certs
    render_auth_config
  fi
  login_additional_registries
  render_watchtower_docker_config
  render_pgadmin_config
  render_gocron_config
  prepare_deployer_image
  push_registry_seed_images
  initialize_nginx_public_dir
  write_env_for_compose
  render_traefik_provided_certs_config

  local compose_args=()
  local _p
  if [ -n "${COMPOSE_PROFILES:-}" ]; then
    IFS=',' read -r -a _profiles <<< "${COMPOSE_PROFILES}"
    for _p in "${_profiles[@]}"; do
      [ -n "$_p" ] && compose_args+=(--profile "$_p")
    done
  fi
  pre_pull_compose_images "${compose_args[@]}"

  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  step "Docker Compose: up"
  if ! retry_cmd "$retries" docker compose "${compose_args[@]}" --env-file "$STACK_ROOT/.env.stack" \
    -f "$SCRIPT_DIR/docker-compose.yml" up -d; then
    diagnose_compose_failure "${compose_args[@]}"
    die "docker compose up failed after ${retries} attempts."
  fi

  configure_filebrowser_credentials
  configure_beszel
  configure_gitea
  diagnose_traefik_tls
  export_production_acme_certificates
  print_urls
  if [[ "${SKIP_SSH_HARDENING:-0}" != "1" ]]; then
    apply_ssh_hardening
  else
    warn "SSH hardening skipped (--skip-ssh-hardening). Finish with: sudo bash ./setup-server-stack.sh --ssh-hardening-only"
  fi
}
