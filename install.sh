#!/usr/bin/env bash
# Compatibility wrapper — forwards to setup-server-stack.sh
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-server-stack.sh" "$@"
