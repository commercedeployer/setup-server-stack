#!/usr/bin/env bash
#
# setup-server-stack.sh — Setup Server Stack: Traefik, Registry + Registry auth, Portainer, Watchtower, Semaphore, Doku, Duplicati, Kuma, optional Deployer.
# Run: sudo bash setup-server-stack.sh  |  sudo bash setup-server-stack.sh --force-secrets
#        sudo bash setup-server-stack.sh --skip-ssh-hardening  |  --ssh-hardening-only
# Config: .env in setup-server-stack (copy from .env.example).
#
set -euo pipefail

VERSION="1.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)"
cd "$SCRIPT_DIR"
export VERSION SCRIPT_DIR

# shellcheck source=lib/setup-server-stack-lib.sh
source "$SCRIPT_DIR/lib/setup-server-stack-lib.sh"

main "$@"
