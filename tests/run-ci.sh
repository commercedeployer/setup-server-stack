#!/usr/bin/env bash
# Local CI for setup-server-stack: shellcheck, compose config, validation unit tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { echo ""; echo "==> $*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

step "preflight"
require_cmd docker
docker compose version >/dev/null

docker_mount_root() {
  if ROOT_WIN="$(cd "$ROOT" && pwd -W 2>/dev/null)" && [[ -n "$ROOT_WIN" ]]; then
    printf '%s' "$ROOT_WIN"
  else
    printf '%s' "$ROOT"
  fi
}

shellcheck_run() {
  local -a sc_flags=(-x -e SC2034 -e SC2153 -e SC2259 -e SC1090 -e SC1091)
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${sc_flags[@]}" "$@"
    return
  fi
  echo "  shellcheck not in PATH — using koalaman/shellcheck Docker image"
  local mount_root
  mount_root="$(docker_mount_root)"
  MSYS_NO_PATHCONV=1 docker run --rm -v "${mount_root}:/mnt" -w /mnt koalaman/shellcheck:stable "${sc_flags[@]}" "$@"
}

step "shellcheck"
shellcheck_run \
  setup-server-stack.sh \
  install.sh \
  lib/setup-server-stack-lib.sh \
  lib/docker-install.inc.sh \
  tests/run-ci.sh \
  tests/validate-lib.sh

load_fixture() {
  local fixture="$1"
  set -a
  # shellcheck disable=SC1090
  source "$fixture"
  set +a
}

step "docker compose config"
FIXTURE_DIR="$ROOT/tests/fixtures"

for fixture in default lean db deployer; do
  f="$FIXTURE_DIR/${fixture}.env.stack"
  [[ -f "$f" ]] || { echo "Missing fixture: $f" >&2; exit 1; }
  load_fixture "$f"
  echo "  fixture: ${fixture}.env.stack (profiles: ${COMPOSE_PROFILES:-})"
  docker compose -f docker-compose.yml config --quiet
done

step "validate-lib.sh"
bash tests/validate-lib.sh

step "done"
echo "All local CI checks passed."
