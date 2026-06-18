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
  export STACK_ROOT
  STACK_ROOT=$(cd "$SCRIPT_DIR" && cd "${STACK_ROOT:-.}" && pwd)
  export STACK_ROOT
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
    "$STACK_ROOT/filebrowser/database" "$STACK_ROOT/filebrowser/config"
  ensure_filebrowser_root_dir
  RUN mkdir -p "${DEPLOY_BASE_PATH:-/opt/deploy-data}"
  chmod 700 "$STACK_ROOT/certs" 2>/dev/null || true
}

resolve_filebrowser_root_path() {
  if [ -z "${FILEBROWSER_ROOT_PATH:-}" ]; then
    FILEBROWSER_ROOT_PATH="$STACK_ROOT/filebrowser/files"
  fi
  export FILEBROWSER_ROOT_PATH
}

ensure_filebrowser_root_dir() {
  [[ "${ENABLE_FILEBROWSER:-1}" == "1" ]] || return 0
  resolve_filebrowser_root_path
  RUN mkdir -p "$FILEBROWSER_ROOT_PATH"
  local puid="${FILEBROWSER_PUID:-1000}"
  local pgid="${FILEBROWSER_PGID:-1000}"
  RUN chown "$puid:$pgid" "$FILEBROWSER_ROOT_PATH" 2>/dev/null || true
}

warn_filebrowser_root_path() {
  [[ "${ENABLE_FILEBROWSER:-1}" == "1" ]] || return 0
  resolve_filebrowser_root_path
  if [ "$FILEBROWSER_ROOT_PATH" = "/" ]; then
    warn "FILEBROWSER_ROOT_PATH=/ exposes the entire host to Filebrowser (rw). Prefer empty (default: \$STACK_ROOT/filebrowser/files) or a dedicated directory."
  fi
}

touch_acme() {
  local f="$STACK_ROOT/traefik/acme.json"
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

ensure_htpasswd() {
  command -v htpasswd &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    step "Installing apache2-utils (htpasswd)"
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2-utils
  fi
  command -v htpasswd &>/dev/null || err "htpasswd required (apt install apache2-utils)."
}

ensure_envsubst() {
  command -v envsubst &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    step "Installing gettext-base (envsubst for registry auth config)"
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gettext-base
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
  if [[ -f "$f" ]] && [[ "$FORCE_SECRETS" -ne 1 ]]; then
    return 0
  fi
  local dp
  dp=$(rand_hex 16)
  mkdir -p "$STACK_ROOT/config/traefik"
  ensure_htpasswd
  htpasswd -nb doku "$dp" >"$f"
  chmod 600 "$f"
  grep -v '^DOKU_DASHBOARD_PASSWORD=' "$sec" >"${sec}.tmp" 2>/dev/null || true
  mv "${sec}.tmp" "$sec" 2>/dev/null || true
  echo "DOKU_DASHBOARD_PASSWORD=$dp" >>"$sec"
}

write_stack_secrets() {
  local sec="$SCRIPT_DIR/.setup-server-stack-secrets"
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

  local changed=0

  if [[ ! -f "$STACK_ROOT/config/traefik/htpasswd" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
    write_traefik_htpasswd "$sec"
    changed=1
  fi

  if [[ ! -f "$STACK_ROOT/config/traefik/htpasswd-doku" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
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

  if [[ "${ENABLE_DUPLICATI:-1}" == "1" ]]; then
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
    if [[ -z "${DEPLOYER_SESSION_SECRET:-}" ]] || [[ "$FORCE_SECRETS" -eq 1 ]]; then
      if ! grep -q '^DEPLOYER_SESSION_SECRET=' "$sec" 2>/dev/null || [[ "$FORCE_SECRETS" -eq 1 ]]; then
        local dss
        dss=$(rand_hex 32)
        grep -v '^DEPLOYER_SESSION_SECRET=' "$sec" >"${sec}.tmp" 2>/dev/null || true
        mv "${sec}.tmp" "$sec" 2>/dev/null || true
        echo "DEPLOYER_SESSION_SECRET=$dss" >>"$sec"
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
  source_env_file_safely "$SCRIPT_DIR/.setup-server-stack-secrets"
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
  local db_name="${POSTGRES_DB:-app}"
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
  : "${SEMAPHORE_ADMIN:=admin}"
  : "${SEMAPHORE_ADMIN_EMAIL:=admin@${DOMAIN:-example.com}}"
  : "${DOKU_IMAGE:=amerkurev/doku:latest}"
  : "${DUPLICATI_IMAGE:=linuxserver/duplicati:latest}"
  : "${UPTIME_KUMA_IMAGE:=louislam/uptime-kuma:1}"
  : "${FILEBROWSER_IMAGE:=filebrowser/filebrowser:v2-s6}"
  : "${MONGO_IMAGE:=mongo:7}"
  : "${POSTGRES_IMAGE:=postgres:16-alpine}"
  : "${MARIADB_IMAGE:=mariadb:11}"
  : "${MYSQL_IMAGE:=mysql:8}"
  : "${MONGO_EXPRESS_IMAGE:=mongo-express:latest}"
  : "${PGADMIN_IMAGE:=dpage/pgadmin4:latest}"
  : "${ADMINER_IMAGE:=adminer:latest}"
  : "${DEPLOYER_IMAGE_EFFECTIVE:=${DEPLOYER_IMAGE:-}}"
  : "${DEPLOYER_IMAGE:=}"
  : "${DEPLOYER_NODE_ENV:=production}"
  : "${DEPLOYER_ADMIN_USER:=admin}"
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
  local rp sp sk dsek mp pp mrp mdp myrp mydp mep pgp adminer_srv fbr dap dss dapi drp drcj rpp
  rp="$(quote_for_env_stack "${REGISTRY_PASSWORD:-}")"
  rpp="$(quote_for_env_stack "${REGISTRY_PULL_PASSWORD:-}")"
  sp="$(quote_for_env_stack "${SEMAPHORE_ADMIN_PASSWORD:-}")"
  sk="$(quote_for_env_stack "${SEMAPHORE_ACCESS_KEY_ENCRYPTION:-}")"
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
  dap="$(quote_for_env_stack "${DEPLOYER_ADMIN_PASSWORD:-}")"
  dss="$(quote_for_env_stack "${DEPLOYER_SESSION_SECRET:-}")"
  dapi="$(quote_for_env_stack "${DEPLOYER_API_KEY:-}")"
  drp="$(quote_for_env_stack "${DEPLOYER_REGISTRY_PASSWORD:-}")"
  drcj="$(quote_for_env_stack "${DEPLOYER_REGISTRY_CREDENTIALS_JSON:-[]}")"

  umask 077
  {
    echo "# Generated by setup-server-stack.sh — do not publish"
    echo "STACK_ROOT=$STACK_ROOT"
    echo "DOMAIN=$DOMAIN"
    echo "ACME_EMAIL=$ACME_EMAIL"
    echo "TZ=${TZ:-UTC}"
    echo "TRAEFIK_IMAGE=$TRAEFIK_IMAGE"
    echo "REGISTRY_IMAGE=$REGISTRY_IMAGE"
    echo "DOCKER_AUTH_IMAGE=$DOCKER_AUTH_IMAGE"
    echo "PORTAINER_IMAGE=$PORTAINER_IMAGE"
    echo "WATCHTOWER_IMAGE=$WATCHTOWER_IMAGE"
    echo "SEMAPHORE_IMAGE=$SEMAPHORE_IMAGE"
    echo "DOKU_IMAGE=$DOKU_IMAGE"
    echo "DUPLICATI_IMAGE=$DUPLICATI_IMAGE"
    echo "UPTIME_KUMA_IMAGE=$UPTIME_KUMA_IMAGE"
    echo "FILEBROWSER_IMAGE=$FILEBROWSER_IMAGE"
    echo "FILEBROWSER_ROOT_PATH=\"$fbr\""
    echo "FILEBROWSER_PUID=${FILEBROWSER_PUID:-1000}"
    echo "FILEBROWSER_PGID=${FILEBROWSER_PGID:-1000}"
    echo "MONGO_IMAGE=$MONGO_IMAGE"
    echo "POSTGRES_IMAGE=$POSTGRES_IMAGE"
    echo "MARIADB_IMAGE=$MARIADB_IMAGE"
    echo "MYSQL_IMAGE=$MYSQL_IMAGE"
    echo "MONGO_EXPRESS_IMAGE=$MONGO_EXPRESS_IMAGE"
    echo "PGADMIN_IMAGE=$PGADMIN_IMAGE"
    echo "ADMINER_IMAGE=$ADMINER_IMAGE"
    echo "ENABLE_TRAEFIK=${ENABLE_TRAEFIK:-1}"
    echo "ENABLE_PORTAINER=${ENABLE_PORTAINER:-1}"
    echo "ENABLE_DOKU=${ENABLE_DOKU:-1}"
    echo "ENABLE_WATCHTOWER=${ENABLE_WATCHTOWER:-1}"
    echo "ENABLE_SEMAPHORE=${ENABLE_SEMAPHORE:-1}"
    echo "ENABLE_DUPLICATI=${ENABLE_DUPLICATI:-1}"
    echo "ENABLE_UPTIME_KUMA=${ENABLE_UPTIME_KUMA:-1}"
    echo "ENABLE_FILEBROWSER=${ENABLE_FILEBROWSER:-1}"
    echo "ENABLE_REGISTRY=${ENABLE_REGISTRY:-1}"
    echo "ENABLE_DOCKER_AUTH=${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-1}}"
    echo "DEPLOYER_IMAGE_EFFECTIVE=$DEPLOYER_IMAGE_EFFECTIVE"
    echo "DEPLOYER_IMAGE=$DEPLOYER_IMAGE"
    echo "DEPLOYER_NODE_ENV=$DEPLOYER_NODE_ENV"
    echo "DEPLOYER_ADMIN_USER=$DEPLOYER_ADMIN_USER"
    echo "DEPLOYER_ADMIN_PASSWORD=\"$dap\""
    echo "DEPLOYER_SESSION_SECRET=\"$dss\""
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
    echo "DUPLICATI_SETTINGS_ENCRYPTION_KEY=\"$dsek\""
    echo "ENABLE_MONGO=${ENABLE_MONGO:-0}"
    echo "ENABLE_POSTGRES=${ENABLE_POSTGRES:-0}"
    echo "ENABLE_MARIADB=${ENABLE_MARIADB:-0}"
    echo "ENABLE_MYSQL=${ENABLE_MYSQL:-0}"
    echo "MONGO_ROOT_USER=${MONGO_ROOT_USER:-mongoadmin}"
    echo "MONGO_ROOT_PASSWORD=\"$mp\""
    echo "POSTGRES_USER=${POSTGRES_USER:-app}"
    echo "POSTGRES_PASSWORD=\"$pp\""
    echo "POSTGRES_DB=${POSTGRES_DB:-app}"
    echo "MARIADB_USER=${MARIADB_USER:-app}"
    echo "MARIADB_PASSWORD=\"$mdp\""
    echo "MARIADB_DATABASE=${MARIADB_DATABASE:-app}"
    echo "MARIADB_ROOT_PASSWORD=\"$mrp\""
    echo "MYSQL_USER=${MYSQL_USER:-app}"
    echo "MYSQL_PASSWORD=\"$mydp\""
    echo "MYSQL_DATABASE=${MYSQL_DATABASE:-app}"
    echo "MYSQL_ROOT_PASSWORD=\"$myrp\""
    echo "ENABLE_MONGO_EXPRESS=${ENABLE_MONGO_EXPRESS:-0}"
    echo "MONGO_EXPRESS_USER=${MONGO_EXPRESS_USER:-mexpress}"
    echo "MONGO_EXPRESS_PASSWORD=\"$mep\""
    echo "ENABLE_PGADMIN=${ENABLE_PGADMIN:-0}"
    echo "PGADMIN_EMAIL=${PGADMIN_EMAIL:-pgadmin@example.com}"
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
  [[ "${ENABLE_REGISTRY:-1}" == "1" ]]
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

  [[ "${ENABLE_TRAEFIK:-1}" == "1" ]] || die "REGISTRY_SEED_IMAGES requires ENABLE_TRAEFIK=1 (push via https://registry.${DOMAIN})."
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-1}}" == "1" ]] || die "REGISTRY_SEED_IMAGES requires ENABLE_DOCKER_AUTH=1."
  local registry_host="registry.${DOMAIN}"
  local retries="${REGISTRY_OPERATION_RETRIES:-3}"
  step "Registry: pushing seed images"
  retry_cmd "$retries" docker compose --env-file "$ENV_FILE" -f "$SCRIPT_DIR/docker-compose.yml" --profile traefik --profile registry --profile docker-auth up -d traefik registry docker-auth \
    || die "Failed to start traefik/registry/docker-auth."
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
  local deployer_image="${DEPLOYER_IMAGE:-}"
  [ -n "$deployer_image" ] || die "ENABLE_DEPLOYER=1 requires DEPLOYER_IMAGE (pre-built image from Docker Hub or GHCR). Build via https://github.com/commercedeployer/deployer CI, then set e.g. docker.io/commercedeployer/deployer:latest"

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

validate_tls_domain_config() {
  [[ "${ENABLE_TRAEFIK:-1}" == "1" ]] || return 0

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
  [[ "${ENABLE_TRAEFIK:-1}" == "1" ]] && return 0

  local need=()
  [[ "${ENABLE_PORTAINER:-1}" == "1" ]] && need+=(ENABLE_PORTAINER)
  [[ "${ENABLE_DOKU:-1}" == "1" ]] && need+=(ENABLE_DOKU)
  [[ "${ENABLE_SEMAPHORE:-1}" == "1" ]] && need+=(ENABLE_SEMAPHORE)
  [[ "${ENABLE_DUPLICATI:-1}" == "1" ]] && need+=(ENABLE_DUPLICATI)
  [[ "${ENABLE_UPTIME_KUMA:-1}" == "1" ]] && need+=(ENABLE_UPTIME_KUMA)
  [[ "${ENABLE_FILEBROWSER:-1}" == "1" ]] && need+=(ENABLE_FILEBROWSER)
  [[ "${ENABLE_REGISTRY:-1}" == "1" ]] && need+=(ENABLE_REGISTRY)
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-1}}" == "1" ]] && need+=(ENABLE_DOCKER_AUTH)
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && need+=(ENABLE_DEPLOYER)
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && need+=(ENABLE_MONGO_EXPRESS)
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && need+=(ENABLE_PGADMIN)
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && need+=(ENABLE_ADMINER)

  ((${#need[@]})) || return 0

  die "ENABLE_TRAEFIK=0 but HTTPS services are still enabled (${need[*]}). Set ENABLE_TRAEFIK=1 or turn those services off (Watchtower and DB engines without web UIs may stay on)."
}

validate_enable_flags() {
  ENABLE_TRAEFIK="${ENABLE_TRAEFIK:-1}"
  ENABLE_PORTAINER="${ENABLE_PORTAINER:-1}"
  ENABLE_DOKU="${ENABLE_DOKU:-1}"
  ENABLE_WATCHTOWER="${ENABLE_WATCHTOWER:-1}"
  ENABLE_SEMAPHORE="${ENABLE_SEMAPHORE:-1}"
  ENABLE_DUPLICATI="${ENABLE_DUPLICATI:-1}"
  ENABLE_UPTIME_KUMA="${ENABLE_UPTIME_KUMA:-1}"
  ENABLE_FILEBROWSER="${ENABLE_FILEBROWSER:-1}"
  ENABLE_REGISTRY="${ENABLE_REGISTRY:-1}"
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
    : "${REGISTRY_USER:=registryadmin}"
    : "${REGISTRY_PULL_USER:=registrypull}"
    [ -n "$REGISTRY_PULL_USER" ] || die "REGISTRY_PULL_USER is empty."
    [[ "$REGISTRY_PULL_USER" != "$REGISTRY_USER" ]] || die "REGISTRY_PULL_USER must differ from REGISTRY_USER ($REGISTRY_USER)."
  fi
  [[ "${ENABLE_MONGO_EXPRESS:-0}" != "1" ]] || [[ "${ENABLE_MONGO:-0}" == "1" ]] || die "ENABLE_MONGO_EXPRESS=1 requires ENABLE_MONGO=1"
  [[ "${ENABLE_PGADMIN:-0}" != "1" ]] || [[ "${ENABLE_POSTGRES:-0}" == "1" ]] || die "ENABLE_PGADMIN=1 requires ENABLE_POSTGRES=1"
  if [[ "${ENABLE_ADMINER:-0}" == "1" ]]; then
    [[ "${ENABLE_MONGO:-0}" == "1" ]] \
      || [[ "${ENABLE_POSTGRES:-0}" == "1" ]] \
      || [[ "${ENABLE_MARIADB:-0}" == "1" ]] \
      || [[ "${ENABLE_MYSQL:-0}" == "1" ]] \
      || die "ENABLE_ADMINER=1 requires ENABLE_MONGO=1 and/or ENABLE_POSTGRES=1 and/or ENABLE_MARIADB=1 and/or ENABLE_MYSQL=1"
  fi
  [[ "${ENABLE_DEPLOYER:-0}" != "1" ]] || [ -n "${DEPLOYER_IMAGE:-}" ] \
    || die "ENABLE_DEPLOYER=1 requires DEPLOYER_IMAGE (pre-built image URL, e.g. docker.io/commercedeployer/deployer:latest)."
  if [[ -n "${REGISTRY_SEED_IMAGES:-}" ]] && [[ "${ENABLE_REGISTRY:-1}" != "1" ]]; then
    warn "REGISTRY_SEED_IMAGES set but ENABLE_REGISTRY=0 — seed image push skipped."
  fi
  warn_filebrowser_root_path
  validate_traefik_required
  validate_tls_domain_config
}

compose_profiles() {
  local p=""
  [[ "${ENABLE_TRAEFIK:-1}" == "1" ]] && p="${p},traefik"
  [[ "${ENABLE_PORTAINER:-1}" == "1" ]] && p="${p},portainer"
  [[ "${ENABLE_DOKU:-1}" == "1" ]] && p="${p},doku"
  [[ "${ENABLE_WATCHTOWER:-1}" == "1" ]] && p="${p},watchtower"
  [[ "${ENABLE_SEMAPHORE:-1}" == "1" ]] && p="${p},semaphore"
  [[ "${ENABLE_DUPLICATI:-1}" == "1" ]] && p="${p},duplicati"
  [[ "${ENABLE_UPTIME_KUMA:-1}" == "1" ]] && p="${p},kuma"
  [[ "${ENABLE_FILEBROWSER:-1}" == "1" ]] && p="${p},filebrowser"
  [[ "${ENABLE_REGISTRY:-1}" == "1" ]] && p="${p},registry"
  [[ "${ENABLE_DOCKER_AUTH:-${ENABLE_REGISTRY:-1}}" == "1" ]] && p="${p},docker-auth"
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
  retry_run "$retries" apt-get update -o APT::Update::Error-Mode=any -qq
  retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
  RUN dpkg-reconfigure -f noninteractive -plow unattended-upgrades || true
  info "Unattended security upgrades enabled."
}

create_admin_user() {
  [[ "${CREATE_ADMIN_USER:-1}" == "1" ]] || return 0
  local admin_username="${ADMIN_USERNAME:-adminops}"
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
  local admin_username="${ADMIN_USERNAME:-adminops}"
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
  local admin_username="${ADMIN_USERNAME:-adminops}"
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
    retry_run "$retries" apt-get update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
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
    RUN ufw allow 443/tcp comment 'HTTPS' &&
    RUN ufw --force enable
}

setup_ufw() {
  local ufw_enable="${UFW_ENABLE:-1}"
  [[ "$ufw_enable" == "1" ]] || return 0
  local ssh_port="${SSH_PORT:-22}"
  if ! command -v ufw &>/dev/null; then
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" apt-get update -o APT::Update::Error-Mode=any -qq
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
  fi
  if ufw_apply_rules; then
    info "UFW: ports ${ssh_port}, 80, 443."
    return 0
  fi
  warn "UFW: iptables-restore failed, trying iptables-legacy..."
  RUN ufw disable 2>/dev/null || true
  if ! [ -x /usr/sbin/iptables-legacy ] && command -v apt-get &>/dev/null; then
    local retries="${REGISTRY_OPERATION_RETRIES:-3}"
    ensure_dns_ready
    retry_run "$retries" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables 2>/dev/null || true
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

print_urls() {
  local d="${DOMAIN}"
  echo ""
  echo "=== HTTPS URLs (after Let's Encrypt certificates are issued) ==="
  [[ "${ENABLE_TRAEFIK:-1}" == "1" ]] && echo "  Traefik:     https://traefik.${d}"
  if registry_enabled; then
    echo "  Registry:    https://registry.${d}"
    echo "  docker_auth: https://auth.${d}"
  fi
  [[ "${ENABLE_PORTAINER:-1}" == "1" ]] && echo "  Portainer:   https://portainer.${d}"
  [[ "${ENABLE_SEMAPHORE:-1}" == "1" ]] && echo "  Semaphore:   https://semaphore.${d}"
  [[ "${ENABLE_DOKU:-1}" == "1" ]] && echo "  Doku:        https://doku.${d}"
  [[ "${ENABLE_DUPLICATI:-1}" == "1" ]] && echo "  Duplicati:   https://duplicati.${d}"
  [[ "${ENABLE_UPTIME_KUMA:-1}" == "1" ]] && echo "  Kuma:        https://kuma.${d}"
  [[ "${ENABLE_FILEBROWSER:-1}" == "1" ]] && echo "  Filebrowser: https://filebrowser.${d}  (rw: ${FILEBROWSER_ROOT_PATH:-$STACK_ROOT/filebrowser/files}; login admin, password in docker logs filebrowser)"
  [[ "${ENABLE_DEPLOYER:-0}" == "1" ]] && echo "  Deployer:    https://deployer.${d}"
  [[ "${ENABLE_MONGO_EXPRESS:-0}" == "1" ]] && echo "  mongo-express: https://mongo-express.${d}"
  [[ "${ENABLE_PGADMIN:-0}" == "1" ]] && echo "  pgAdmin:       https://pgadmin.${d}  (Postgres server pre-registered; pgAdmin login — PGADMIN_EMAIL / PGADMIN_PASSWORD)"
  [[ "${ENABLE_ADMINER:-0}" == "1" ]] && echo "  Adminer:       https://adminer.${d}"
  echo ""
  echo "Volumes and config: STACK_ROOT=$STACK_ROOT"
  echo "Compose env: $STACK_ROOT/.env.stack (generated, chmod 600)."
  echo "Secrets: $SCRIPT_DIR/.setup-server-stack-secrets (do not commit)."
  echo "Traefik dashboard: user admin, password in TRAEFIK_DASHBOARD_PASSWORD in .setup-server-stack-secrets."
  echo "Doku: user doku, password in DOKU_DASHBOARD_PASSWORD in .setup-server-stack-secrets (Traefik Basic Auth)."
  registry_enabled && echo "docker login (push):  docker login registry.${d}  # user ${REGISTRY_USER}"
  registry_enabled && echo "docker login (pull):  docker login registry.${d}  # user ${REGISTRY_PULL_USER:-registrypull}"
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
    echo "--force-secrets: regenerating secrets in .setup-server-stack-secrets (acme.json untouched)."
  fi

  create_admin_user
  configure_admin_sudo_nopasswd
  setup_unattended
  setup_fail2ban
  setup_ufw

  ensure_dirs
  touch_acme
  ensure_network

  write_stack_secrets
  if registry_enabled; then
    gen_registry_certs
    render_auth_config
  fi
  login_additional_registries
  render_watchtower_docker_config
  render_pgadmin_config
  prepare_deployer_image
  push_registry_seed_images
  write_env_for_compose

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
  retry_cmd "$retries" docker compose "${compose_args[@]}" --env-file "$STACK_ROOT/.env.stack" \
    -f "$SCRIPT_DIR/docker-compose.yml" up -d || die "docker compose up failed after ${retries} attempts."

  print_urls
  if [[ "${SKIP_SSH_HARDENING:-0}" != "1" ]]; then
    apply_ssh_hardening
  else
    warn "SSH hardening skipped (--skip-ssh-hardening). Finish with: sudo bash ./setup-server-stack.sh --ssh-hardening-only"
  fi
}
