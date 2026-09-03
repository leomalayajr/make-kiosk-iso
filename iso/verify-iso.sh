#!/usr/bin/env bash
# Verify both images inside a finished Offline Kiosk installer ISO.
set -Eeuo pipefail

ISO_FILE=${1:-}
[ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ] || {
  echo "Usage: $0 <output-file.iso>" >&2
  exit 2
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ISO_DIR=$(cd "$(dirname "$ISO_FILE")" && pwd)
ISO_NAME=$(basename "$ISO_FILE")
BUILDER_IMAGE=kiosk-archiso-builder:latest

docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || {
  echo "ERROR: required verification image is missing: $BUILDER_IMAGE" >&2
  exit 1
}

docker run --rm --privileged \
  -v "$ISO_DIR:/iso:ro" \
  -v "$SCRIPT_DIR/verify-checks.sh:/verify-checks.sh:ro" \
  -v "$SCRIPT_DIR/build-inside.sh:/custom/build-inside.sh:ro" \
  --entrypoint /bin/bash \
  "$BUILDER_IMAGE" \
  /verify-checks.sh "/iso/$ISO_NAME"
