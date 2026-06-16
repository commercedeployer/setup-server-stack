# shellcheck shell=bash
# Sourced from setup-server-stack-lib.sh after RUN(), err(), step, info, warn are defined.
# Docker Engine installation on Debian/Ubuntu.

docker_daemon_ok() {
  command -v docker &>/dev/null || return 1
  docker info &>/dev/null || return 1
}

wait_for_docker_daemon() {
  local i
  for i in {1..60}; do
    docker_daemon_ok && return 0
    sleep 1
  done
  return 1
}

load_docker_kernel_modules() {
  RUN modprobe overlay 2>/dev/null || true
  RUN modprobe br_netfilter 2>/dev/null || true
}

docker_service_diagnostics() {
  echo "[ERR] --- systemctl status docker ---" >&2
  RUN systemctl status docker --no-pager -l 2>&1 | head -100 >&2 || true
  echo "[ERR] --- journalctl -u docker.service (last 60 lines) ---" >&2
  RUN journalctl -u docker.service -n 60 --no-pager 2>&1 | head -100 >&2 || true
}

docker_merge_daemon_json_iptables_off() {
  step "Workaround: /etc/docker/daemon.json — iptables: false"
  RUN mkdir -p /etc/docker
  if command -v python3 &>/dev/null; then
    python3 <<'PY' | RUN tee /etc/docker/daemon.json >/dev/null
import json
from pathlib import Path
p = Path("/etc/docker/daemon.json")
d = {}
if p.exists():
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        d = {}
d["iptables"] = False
print(json.dumps(d, indent=2))
PY
  else
    echo '{"iptables": false}' | RUN tee /etc/docker/daemon.json >/dev/null
  fi
  RUN chmod 644 /etc/docker/daemon.json
  info "Docker will not manage iptables — check UFW/firewall and port forwarding if needed."
}

start_docker_service() {
  step "Starting docker service (systemctl)"
  info "Waiting for docker info up to ~60s; on failure — iptables workaround."
  load_docker_kernel_modules
  RUN systemctl daemon-reload
  RUN systemctl enable docker 2>/dev/null || true
  RUN systemctl restart docker >/dev/null 2>&1 || true
  RUN systemctl start docker >/dev/null 2>&1 || true
  if wait_for_docker_daemon; then
    return 0
  fi

  if [ "${DOCKER_AUTO_IPTABLES_OFF:-1}" = "1" ]; then
    warn "Trying to disable Docker-managed iptables rules."
    docker_merge_daemon_json_iptables_off
    RUN systemctl daemon-reload
    RUN systemctl restart docker >/dev/null 2>&1 || true
    RUN systemctl start docker >/dev/null 2>&1 || true
    if wait_for_docker_daemon; then
      info "Docker started with iptables=false in /etc/docker/daemon.json."
      return 0
    fi
  fi

  warn "Restarting containerd and docker..."
  RUN systemctl enable containerd 2>/dev/null || true
  RUN systemctl restart containerd 2>/dev/null || true
  sleep 2
  RUN systemctl restart docker >/dev/null 2>&1 || true
  RUN systemctl start docker >/dev/null 2>&1 || true
  wait_for_docker_daemon
}

ensure_openssl() {
  command -v openssl &>/dev/null && return 0
  if command -v apt-get &>/dev/null; then
    step "Installing openssl (apt)"
    export DEBIAN_FRONTEND=noninteractive
    RUN apt-get update -qq
    RUN apt-get install -y -qq openssl ca-certificates
  fi
  command -v openssl &>/dev/null || err "openssl required (apt install openssl)."
}

install_docker_engine() {
  command -v apt-get &>/dev/null || err "Docker auto-install requires apt (Debian/Ubuntu)."
  if [ ! -f /etc/os-release ]; then
    err "Missing /etc/os-release — Docker auto-install is Ubuntu/Debian only."
  fi
  local _hs_script_version="${VERSION:-}"
  # shellcheck source=/dev/null
  . /etc/os-release
  local id="${ID,,}"
  local version_codename="${VERSION_CODENAME:-}"
  [ -n "${UBUNTU_CODENAME:-}" ] && [ -z "$version_codename" ] && version_codename="$UBUNTU_CODENAME"
  VERSION="${_hs_script_version}"
  export VERSION
  case "$id" in
    ubuntu|debian) ;;
    *) err "Docker auto-install: Ubuntu and Debian only (current ID=$ID)." ;;
  esac
  [ -n "$version_codename" ] || err "Could not determine VERSION_CODENAME for Docker repository."

  step "Installing Docker Engine and Compose plugin"
  export DEBIAN_FRONTEND=noninteractive
  RUN apt-get update -qq
  RUN apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null || true
  RUN apt-get install -y -qq ca-certificates curl gnupg
  RUN install -m 0755 -d /etc/apt/keyrings
  RUN curl -fsSL "https://download.docker.com/linux/${id}/gpg" -o /etc/apt/keyrings/docker.asc
  RUN chmod a+r /etc/apt/keyrings/docker.asc
  local arch
  arch="$(dpkg --print-architecture)"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${id} ${version_codename} stable" |
    RUN tee /etc/apt/sources.list.d/docker.list >/dev/null
  RUN apt-get update -qq
  RUN apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if start_docker_service; then
    info "Installed docker-ce and docker compose plugin."
  else
    warn "Packages installed but Docker daemon did not start."
    docker_service_diagnostics
    err "dockerd did not start after installation."
  fi
}

ensure_docker_ready() {
  if docker_daemon_ok; then
    info "Docker already responding (docker info)."
  else
    if command -v docker &>/dev/null; then
      start_docker_service || true
    fi
    if docker_daemon_ok; then
      info "Docker service started."
    elif [ "${INSTALL_DOCKER:-1}" = "1" ]; then
      install_docker_engine
    else
      echo "[ERR] docker info:" >&2
      docker info 2>&1 | head -20 >&2 || true
      err "Docker unavailable. Install Engine and Compose v2 manually or set INSTALL_DOCKER=1 in .env"
    fi
  fi

  command -v docker &>/dev/null || err "docker command not found after installation."
  docker compose version &>/dev/null || err "Docker Compose v2 required (docker compose). Package: docker-compose-plugin."

  if ! docker_daemon_ok; then
    if [ "$(id -u)" -ne 0 ] && sudo docker info &>/dev/null; then
      err "Docker requires sudo. Run: sudo bash $SCRIPT_DIR/setup-server-stack.sh"
    fi
    echo "[ERR] docker info:" >&2
    docker info 2>&1 | head -30 >&2 || true
    docker_service_diagnostics
    err "Docker daemon unavailable. See journalctl. DOCKER_AUTO_IPTABLES_OFF=1 often helps."
  fi
}
