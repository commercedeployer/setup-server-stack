#!/usr/bin/env bash
# Unit tests for setup-server-stack-lib.sh validation helpers (no Docker, no root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/setup-server-stack-lib.sh"

# Tests assume a clean environment. A caller (e.g. run-ci.sh) may have sourced
# fixtures earlier, so clear stack vars that individual cases rely on being
# unset or self-controlled; otherwise inherited values would skew results.
unset TRAEFIK_CERT_MODE TRAEFIK_CERT_RESOLVER TRAEFIK_ACME_CA_SERVER \
  TRAEFIK_ACME_STORAGE_FILE TRAEFIK_ACME_EMAIL TRAEFIK_TLS_CHECK_WAIT_SECONDS \
  DEPLOYER_API_KEY DEPLOYER_AUTH_MODE 2>/dev/null || true

run_lib() {
  export VERSION=ci-test
  export SCRIPT_DIR="$ROOT"
  # shellcheck disable=SC1091
  source "$LIB"
  "$@"
}

TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  echo "  ok: $*"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $*" >&2
}

expect_fail() {
  local name="$1"
  shift
  if ("$@"); then
    fail "expected failure: $name"
  else
    pass "expected failure: $name"
  fi
}

expect_ok() {
  local name="$1"
  shift
  if ("$@"); then
    pass "expected success: $name"
  else
    fail "expected success: $name"
  fi
}

echo "==> validate-lib.sh"

expect_fail "tls: example.com domain" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=example.com ACME_EMAIL=ci@stack.test
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

expect_fail "tls: empty ACME_EMAIL" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL=
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

expect_ok "tls: valid domain and email" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL=ci@stack.test
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

auto_mode="$(bash -c '
  export STACK_ROOT=/tmp/setup-server-stack-ci
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  configure_traefik_cert_mode
  printf "%s|%s" "$TRAEFIK_CERT_MODE" "$TRAEFIK_CERT_RESOLVER"
')"
if [[ "$auto_mode" == "auto|letsencrypt" ]]; then
  pass "tls: auto mode defaults to custom certs plus Let's Encrypt"
else
  fail "tls: expected auto|letsencrypt got $auto_mode"
fi

# shellcheck disable=SC2016
expect_ok "env: registry token issuer defaults for short env" bash -c '
  tmp=/tmp/setup-server-stack-ci-short-env
  rm -rf "$tmp"
  mkdir -p "$tmp"
  : >"$tmp/.env"
  export ENV_FILE="$tmp/.env" STACK_ROOT="$tmp" DOMAIN=ci.stack.test ACME_EMAIL=ci@stack.test
  export ENABLE_TRAEFIK=1 ENABLE_REGISTRY=1 ENABLE_DOCKER_AUTH=1 REGISTRY_PASSWORD=test-registry-password
  export EXTRA_REGISTRY_COUNT=0 REGISTRY_OPERATION_RETRIES=3
  export REGISTRY_RETRY_BACKOFF_BASE_SEC=2 REGISTRY_RETRY_BACKOFF_MAX_SEC=10
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  unset REGISTRY_AUTH_TOKEN_ISSUER
  source "'"$LIB"'"
  validate_enable_flags
  write_env_for_compose
  grep -qx "REGISTRY_AUTH_TOKEN_ISSUER=setup-server-registry" "$tmp/.env.stack"
'

expect_ok "tls: provided does not require ACME_EMAIL" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL= TRAEFIK_CERT_MODE=provided
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

expect_ok "tls: selfsigned does not require ACME_EMAIL" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL= TRAEFIK_CERT_MODE=selfsigned
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

expect_fail "tls: invalid cert mode" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL=ci@stack.test TRAEFIK_CERT_MODE=invalid
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_tls_domain_config
'

staging_ca="$(bash -c '
  export TRAEFIK_CERT_MODE=staging STACK_ROOT=/tmp/setup-server-stack-ci
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  configure_traefik_cert_mode
  printf "%s" "$TRAEFIK_ACME_CA_SERVER"
')"
if [[ "$staging_ca" == "https://acme-staging-v02.api.letsencrypt.org/directory" ]]; then
  pass "tls: staging mode uses Let's Encrypt staging CA"
else
  fail "tls: expected staging CA got $staging_ca"
fi

staging_storage="$(bash -c '
  export TRAEFIK_CERT_MODE=staging STACK_ROOT=/tmp/setup-server-stack-ci
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  configure_traefik_cert_mode
  printf "%s" "$TRAEFIK_ACME_STORAGE_FILE"
')"
if [[ "$staging_storage" == "/tmp/setup-server-stack-ci/traefik/acme-staging.json" ]]; then
  pass "tls: staging mode uses separate ACME storage"
else
  fail "tls: expected staging storage got $staging_storage"
fi

provided_storage="$(bash -c '
  export TRAEFIK_CERT_MODE=provided STACK_ROOT=/tmp/setup-server-stack-ci
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  configure_traefik_cert_mode
  printf "%s|%s" "$TRAEFIK_CERT_RESOLVER" "$TRAEFIK_ACME_STORAGE_FILE"
')"
if [[ "$provided_storage" == "|/tmp/setup-server-stack-ci/traefik/acme-provided.json" ]]; then
  pass "tls: provided mode disables ACME resolver"
else
  fail "tls: expected empty resolver with provided storage got $provided_storage"
fi

provided_pair="$(bash -c '
  rm -rf /tmp/setup-server-stack-ci-provided
  mkdir -p /tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test
  touch /tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test/fullchain.pem
  touch /tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test/privkey.pem
  export STACK_ROOT=/tmp/setup-server-stack-ci-provided
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  provided_cert_pair_for_host panel.ci.stack.test
')"
if [[ "$provided_pair" == "/tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test/fullchain.pem|/tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test/privkey.pem" ]]; then
  pass "tls: custom certificate pair can use fullchain/privkey layout"
else
  fail "tls: expected custom fullchain/privkey pair got $provided_pair"
fi

cert_container_path="$(bash -c '
  export STACK_ROOT=/tmp/setup-server-stack-ci-provided
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  provided_cert_container_path /tmp/setup-server-stack-ci-provided/certs/panel.ci.stack.test/fullchain.pem
')"
if [[ "$cert_container_path" == "/certs/panel.ci.stack.test/fullchain.pem" ]]; then
  pass "tls: certificate container path uses flat certs/<host> layout"
else
  fail "tls: expected /certs/panel.ci.stack.test/fullchain.pem got $cert_container_path"
fi

expect_ok "tls: production ACME export writes certs/<host> files" bash -c '
  set -euo pipefail
  command -v python3 >/dev/null 2>&1 || exit 0
  rm -rf /tmp/setup-server-stack-ci-acme
  mkdir -p /tmp/setup-server-stack-ci-acme/traefik
  cat > /tmp/setup-server-stack-ci-acme/traefik/acme.json <<JSON
{"letsencrypt":{"Certificates":[{"domain":{"main":"portainer.ci.stack.test","sans":[]},"certificate":"Q0VSVA==","key":"S0VZ"}]}}
JSON
  export ENABLE_TRAEFIK=1 ENABLE_PORTAINER=1 DOMAIN=ci.stack.test
  export ENABLE_REGISTRY=0 ENABLE_DOCKER_AUTH=0
  export ENABLE_ADMINER=0
  export TRAEFIK_CERT_MODE=auto
  export TRAEFIK_ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
  export TRAEFIK_ACME_STORAGE_FILE=/tmp/setup-server-stack-ci-acme/traefik/acme.json
  export STACK_ROOT=/tmp/setup-server-stack-ci-acme
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  export_production_acme_certificates >/dev/null
  [[ -f /tmp/setup-server-stack-ci-acme/certs/portainer.ci.stack.test/fullchain.pem ]]
  [[ -f /tmp/setup-server-stack-ci-acme/certs/portainer.ci.stack.test/privkey.pem ]]
'

expect_ok "urls: print_urls does not fail when registry disabled" bash -c '
  set -euo pipefail
  export DOMAIN=ci.stack.test ENABLE_REGISTRY=0 ENABLE_DOCKER_AUTH=0
  export ENABLE_TRAEFIK=1 ENABLE_PORTAINER=0 ENABLE_DOKU=0 ENABLE_SEMAPHORE=0
  export ENABLE_DUPLICATI=0 ENABLE_UPTIME_KUMA=0 ENABLE_FILEBROWSER=0 ENABLE_NGINX=0
  export ENABLE_DEPLOYER=0 ENABLE_MONGO_EXPRESS=0 ENABLE_PGADMIN=0 ENABLE_ADMINER=0
  export STACK_ROOT=/tmp/setup-server-stack-ci VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  print_urls >/dev/null
'

# shellcheck disable=SC2016
expect_fail "secrets: existing compose state requires .secrets" bash -c '
  set -euo pipefail
  tmp=/tmp/setup-server-stack-ci-existing-state
  rm -rf "$tmp"
  mkdir -p "$tmp/lib"
  touch "$tmp/lib/docker-install.inc.sh"
  export SCRIPT_DIR="$tmp" STACK_ROOT="$tmp" VERSION=ci-test
  docker() {
    if [[ "$1 $2" == "ps -aq" ]]; then
      printf "%s\n" "existing-container"
      return 0
    fi
    return 1
  }
  source "'"$LIB"'"
  guard_existing_stack_requires_secrets
'

# shellcheck disable=SC2016
expect_ok "secrets: deployer api key is generated and reused" bash -c '
  set -euo pipefail
  tmp=/tmp/setup-server-stack-ci-deployer-secrets
  rm -rf "$tmp"
  mkdir -p "$tmp/lib"
  touch "$tmp/lib/docker-install.inc.sh"
  cat >"$tmp/.env" <<ENV
ENABLE_DEPLOYER=1
DEPLOYER_IMAGE=commercedeployer/deployer:latest
ENV
  export SCRIPT_DIR="$tmp" STACK_ROOT="$tmp" VERSION=ci-test
  source "'"$LIB"'"
  export ENV_FILE="$tmp/.env"
  ensure_htpasswd() { :; }
  write_traefik_htpasswd() { :; }
  write_doku_htpasswd() { :; }
  write_stack_secrets >/dev/null
  grep -Eq "^DEPLOYER_API_KEY=[0-9a-f]{64}$" "$tmp/.secrets"
  first="$(grep "^DEPLOYER_API_KEY=" "$tmp/.secrets")"
  write_stack_secrets >/dev/null
  second="$(grep "^DEPLOYER_API_KEY=" "$tmp/.secrets")"
  [[ "$first" == "$second" ]]
'

# shellcheck disable=SC2016
expect_ok "secrets: deployer ui mode skips api key" bash -c '
  set -euo pipefail
  tmp=/tmp/setup-server-stack-ci-deployer-ui-secrets
  rm -rf "$tmp"
  mkdir -p "$tmp/lib"
  touch "$tmp/lib/docker-install.inc.sh"
  cat >"$tmp/.env" <<ENV
ENABLE_DEPLOYER=1
DEPLOYER_IMAGE=commercedeployer/deployer:latest
DEPLOYER_AUTH_MODE=ui
ENV
  cat >"$tmp/.secrets" <<SECRETS
DEPLOYER_API_KEY=old-generated-key
SECRETS
  export SCRIPT_DIR="$tmp" STACK_ROOT="$tmp" VERSION=ci-test
  source "'"$LIB"'"
  export ENV_FILE="$tmp/.env"
  ensure_htpasswd() { :; }
  write_traefik_htpasswd() { :; }
  write_doku_htpasswd() { :; }
  write_stack_secrets >/dev/null
  [[ -z "${DEPLOYER_API_KEY:-}" ]]
  ! grep -q "^DEPLOYER_API_KEY=" "$tmp/.secrets"
'

expect_ok "nginx: seed initializes empty runtime public dir" bash -c '
  rm -rf /tmp/setup-server-stack-ci-nginx
  mkdir -p /tmp/setup-server-stack-ci-nginx/script/public
  mkdir -p /tmp/setup-server-stack-ci-nginx/script/lib
  touch /tmp/setup-server-stack-ci-nginx/script/lib/docker-install.inc.sh
  printf "seed page" > /tmp/setup-server-stack-ci-nginx/script/public/index.html
  export ENABLE_NGINX=1 STACK_ROOT=/tmp/setup-server-stack-ci-nginx/runtime
  export VERSION=ci-test SCRIPT_DIR=/tmp/setup-server-stack-ci-nginx/script
  source "'"$LIB"'"
  initialize_nginx_public_dir >/dev/null
  grep -q "seed page" /tmp/setup-server-stack-ci-nginx/runtime/nginx/public/index.html
'

expect_ok "nginx: seed keeps existing runtime site" bash -c '
  rm -rf /tmp/setup-server-stack-ci-nginx-existing
  mkdir -p /tmp/setup-server-stack-ci-nginx-existing/script/public
  mkdir -p /tmp/setup-server-stack-ci-nginx-existing/script/lib
  touch /tmp/setup-server-stack-ci-nginx-existing/script/lib/docker-install.inc.sh
  mkdir -p /tmp/setup-server-stack-ci-nginx-existing/runtime/nginx/public
  printf "seed page" > /tmp/setup-server-stack-ci-nginx-existing/script/public/index.html
  printf "user site" > /tmp/setup-server-stack-ci-nginx-existing/runtime/nginx/public/index.html
  export ENABLE_NGINX=1 STACK_ROOT=/tmp/setup-server-stack-ci-nginx-existing/runtime
  export VERSION=ci-test SCRIPT_DIR=/tmp/setup-server-stack-ci-nginx-existing/script
  source "'"$LIB"'"
  initialize_nginx_public_dir >/dev/null
  grep -q "user site" /tmp/setup-server-stack-ci-nginx-existing/runtime/nginx/public/index.html
'

expect_fail "traefik: TRAEFIK=0 with Portainer" bash -c '
  export ENABLE_TRAEFIK=0 ENABLE_PORTAINER=1 ENABLE_WATCHTOWER=0
  export ENABLE_DOKU=0 ENABLE_SEMAPHORE=0 ENABLE_DUPLICATI=0 ENABLE_UPTIME_KUMA=0
  export ENABLE_FILEBROWSER=0 ENABLE_NGINX=0 ENABLE_REGISTRY=0 ENABLE_DOCKER_AUTH=0 ENABLE_DEPLOYER=0
  export ENABLE_MONGO_EXPRESS=0 ENABLE_PGADMIN=0 ENABLE_ADMINER=0
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_traefik_required
'

expect_fail "traefik: TRAEFIK=0 with NGINX" bash -c '
  export ENABLE_TRAEFIK=0 ENABLE_PORTAINER=0 ENABLE_WATCHTOWER=0
  export ENABLE_DOKU=0 ENABLE_SEMAPHORE=0 ENABLE_DUPLICATI=0 ENABLE_UPTIME_KUMA=0
  export ENABLE_FILEBROWSER=0 ENABLE_NGINX=1 ENABLE_REGISTRY=0 ENABLE_DOCKER_AUTH=0 ENABLE_DEPLOYER=0
  export ENABLE_MONGO_EXPRESS=0 ENABLE_PGADMIN=0 ENABLE_ADMINER=0
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_traefik_required
'

expect_ok "traefik: TRAEFIK=0 with Watchtower only" bash -c '
  export ENABLE_TRAEFIK=0 ENABLE_PORTAINER=0 ENABLE_WATCHTOWER=1
  export ENABLE_DOKU=0 ENABLE_SEMAPHORE=0 ENABLE_DUPLICATI=0 ENABLE_UPTIME_KUMA=0
  export ENABLE_FILEBROWSER=0 ENABLE_NGINX=0 ENABLE_REGISTRY=0 ENABLE_DOCKER_AUTH=0 ENABLE_DEPLOYER=0
  export ENABLE_MONGO_EXPRESS=0 ENABLE_PGADMIN=0 ENABLE_ADMINER=0
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_traefik_required
'

expect_fail "enable: pgAdmin without Postgres" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL=ci@stack.test
  export ENABLE_PGADMIN=1 ENABLE_POSTGRES=0
  export EXTRA_REGISTRY_COUNT=0 REGISTRY_OPERATION_RETRIES=3
  export REGISTRY_RETRY_BACKOFF_BASE_SEC=2 REGISTRY_RETRY_BACKOFF_MAX_SEC=10
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_enable_flags
'

expect_ok "enable: pgAdmin with Postgres" bash -c '
  export ENABLE_TRAEFIK=1 DOMAIN=ci.stack.test ACME_EMAIL=ci@stack.test
  export ENABLE_PGADMIN=1 ENABLE_POSTGRES=1
  export EXTRA_REGISTRY_COUNT=0 REGISTRY_OPERATION_RETRIES=3
  export REGISTRY_RETRY_BACKOFF_BASE_SEC=2 REGISTRY_RETRY_BACKOFF_MAX_SEC=10
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  validate_enable_flags
'

fb_path="$(bash -c '
  export STACK_ROOT=/tmp/setup-server-stack-ci FILEBROWSER_ROOT_PATH=
  export VERSION=ci-test SCRIPT_DIR="'"$ROOT"'"
  source "'"$LIB"'"
  resolve_filebrowser_root_path
  printf "%s" "$FILEBROWSER_ROOT_PATH"
')"
if [[ "$fb_path" == "/tmp/setup-server-stack-ci/filebrowser/files" ]]; then
  pass "filebrowser: empty path defaults to STACK_ROOT/filebrowser/files"
else
  fail "filebrowser: expected /tmp/setup-server-stack-ci/filebrowser/files got $fb_path"
fi

echo ""
echo "validate-lib: $TESTS_RUN tests, $TESTS_FAILED failed"
if (( TESTS_FAILED > 0 )); then
  exit 1
fi
