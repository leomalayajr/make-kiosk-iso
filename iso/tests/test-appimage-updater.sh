#!/usr/bin/env bash
# Verify the unattended AppImage update contract without modifying or starting
# the production application.
QUICK_ONLY=1

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
ISO_DIR="$PROJECT_DIR/iso"
LAUNCHER="$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"
KIOSK_SERVICE="$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"
REFRESH_TIMER="$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.timer"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$*"; }
contains() {
  local file=$1 pattern=$2 label=$3
  grep -qE -- "$pattern" "$file" && ok "$label" || fail "$label"
}

printf '\n=== Stable AppImage build contract ===\n'
contains "$PROJECT_DIR/make-kiosk-iso.sh" 'application source must have an \.AppImage extension' \
  'builder rejects unpacked application directories'
contains "$PROJECT_DIR/make-kiosk-iso.sh" 'AppImage desktop entry does not contain a stable semantic version' \
  'builder requires a stable AppImage version'
contains "$PROJECT_DIR/make-kiosk-iso.sh" 'X-AppImage-Version=' \
  'builder reads the embedded AppImage version instead of trusting its filename'
contains "$PROJECT_DIR/make-kiosk-iso.sh" 'electron-updater replace' \
  'builder preserves the updater-compatible AppImage path'
contains "$PROJECT_DIR/make-kiosk-iso.sh" 'staged_app=.*app\.AppImage' \
  'builder stages the stable AppImage name'
contains "$ISO_DIR/build-inside.sh" 'opt/electron-app/app\.AppImage' \
  'target installs the stable AppImage path'
contains "$ISO_DIR/build-inside.sh" 'chown -R 1000:1000.*electron-app' \
  'appuser owns the replaceable application directory'

printf '\n=== Runtime updater contract ===\n'
contains "$LAUNCHER" 'APP_IMAGE="\$APP_DIR/app\.AppImage"' \
  'launcher selects only the stable AppImage'
contains "$LAUNCHER" '"\$APP_IMAGE" --appimage-extract' \
  'launcher prepares a FUSE-free runtime copy'
contains "$LAUNCHER" 'export APPIMAGE="\$APP_IMAGE"' \
  'electron-updater receives the writable original path'
contains "$LAUNCHER" 'KIOSK_UPDATE_FEED_URL_B64' \
  'runtime updater config reads the configured feed'
contains "$LAUNCHER" 'KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64' \
  'runtime updater config reads the configured cache name'
contains "$KIOSK_SERVICE" '^Restart=always$' \
  'systemd relaunches after a clean updater exit'

printf '\n=== Fleet-safe recheck contract ===\n'
contains "$REFRESH_TIMER" '^OnCalendar=\*-\*-\* 03:00:00$' \
  'kiosk is refreshed daily to trigger the startup update check'
contains "$REFRESH_TIMER" '^RandomizedDelaySec=4h$' \
  'daily fleet checks have four hours of jitter'
contains "$ISO_DIR/build-inside.sh" 'kiosk-refresh\.timer' \
  'refresh timer is enabled in the installed target'

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
