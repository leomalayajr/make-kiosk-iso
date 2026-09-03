#!/usr/bin/env bash
# Compatibility entry point. The public builder lives at the repository root.
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/../make-kiosk-iso.sh" "$@"
