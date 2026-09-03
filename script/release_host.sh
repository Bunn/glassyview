#!/usr/bin/env bash
# Credential values must never be expanded under shell tracing.
set +x
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$SCRIPT_DIR/release_host.py" "$@"
