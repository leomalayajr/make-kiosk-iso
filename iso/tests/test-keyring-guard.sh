#!/usr/bin/env bash
# Test suite for launch-electron.sh gnome-keyring handling.
# These tests verify that the keyring guard logic correctly:
#   1. Identifies appuser as the target user for gnome-keyring-daemon
#   2. Uses appropriate commands to start keyring as non-root
#   3. Handles dbus session bus connectivity checks
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LAUNCH_SCRIPT="$BASE_DIR/target-rootfs/usr/local/bin/launch-electron.sh"

PASSED=0
FAILED=0
TOTAL=0

assert_contains() {
  local file="$1" pattern="$2" description="$3"
  TOTAL=$((TOTAL + 1))
  if grep -q "$pattern" "$file" 2>/dev/null; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $description"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $description"
    echo "    Expected pattern '$pattern' not found in $file"
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2" description="$3"
  TOTAL=$((TOTAL + 1))
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $description"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $description"
    echo "    Pattern '$pattern' should NOT be found in $file"
  fi
}

assert_file_exists() {
  local file="$1" description="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$file" ]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $description"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $description"
    echo "    File '$file' does not exist"
  fi
}

echo "=========================================="
echo " launch-electron.sh tests"
echo "=========================================="

echo ""
echo "[Test Group 1] Launcher exists"
assert_file_exists "$LAUNCH_SCRIPT" "target launcher exists"

echo ""
echo "[Test Group 2] Keyring user targeting"
assert_contains "$LAUNCH_SCRIPT" 'APPUSER_NAME=' \
  "APPUSER_NAME variable is defined with default appuser"
assert_not_contains "$LAUNCH_SCRIPT" 'pkill.*gnome-keyring-daemon' \
  "Launcher does not kill a persistent keyring daemon on startup"

echo ""
echo "[Test Group 3] Keyring runs as appuser when script is root"
assert_contains "$LAUNCH_SCRIPT" '\[ "\$(id -u)" -eq 0 \]' \
  "Root detection check exists"
assert_contains "$LAUNCH_SCRIPT" 'runuser -u "\$APPUSER_NAME"' \
  "runuser is used to start keyring as appuser when running as root"
assert_contains "$LAUNCH_SCRIPT" 'XDG_RUNTIME_DIR=\$XDG_RUNTIME_DIR' \
  "XDG_RUNTIME_DIR is passed to runuser environment"

echo ""
echo "[Test Group 4] D-Bus session bus check"
assert_contains "$LAUNCH_SCRIPT" 'DBUS_SESSION_BUS_ADDRESS=' \
  "D-Bus session bus address is set correctly"
assert_contains "$LAUNCH_SCRIPT" 'dbus_ready=1' \
  "D-Bus readiness flag is set on success"

echo ""
echo "[Test Group 5] Secret Service activation flow"
assert_contains "$LAUNCH_SCRIPT" 'secret_service_ready()' \
  "secret_service_ready() function is defined"
assert_contains "$LAUNCH_SCRIPT" 'wait_secret_service()' \
  "wait_secret_service() function is defined"
assert_contains "$LAUNCH_SCRIPT" 'gnome-keyring-daemon --daemonize --components=secrets' \
  "gnome-keyring can start the Secret Service"

echo ""
echo "[Test Group 6] Encryption fallback"
assert_contains "$LAUNCH_SCRIPT" '\[ "\$keyring_available" -ne 1 \]' \
  "keyring availability check exists"
assert_contains "$LAUNCH_SCRIPT" 'launching Electron with its storage fallback' \
  "Script launches Electron when encrypted storage is unavailable"
assert_not_contains "$LAUNCH_SCRIPT" 'Refusing to launch Electron without encrypted storage' \
  "Keyring failure cannot block kiosk startup"

echo ""
echo "[Test Group 7] Build script verification"
BUILD_SCRIPT="$BASE_DIR/build-inside.sh"
if [ -f "$BUILD_SCRIPT" ]; then
  assert_contains "$BUILD_SCRIPT" 'setcap cap_ipc_lock=+ep' \
    "Build script grants cap_ipc_lock to gnome-keyring-daemon"
  assert_contains "$BUILD_SCRIPT" 'getcap.*gnome-keyring-daemon.*cap_ipc_lock' \
    "Build script verifies cap_ipc_lock was set"
else
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  echo "  FAIL: build-inside.sh not found"
fi

echo ""
echo "[Test Group 8] Package list includes required deps"
PKG_LIST="$BASE_DIR/target-packages.txt"
if [ -f "$PKG_LIST" ]; then
  assert_contains "$PKG_LIST" '^gnome-keyring$' \
    "gnome-keyring is in target packages"
  assert_contains "$PKG_LIST" '^libsecret$' \
    "libsecret is in target packages"
else
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  echo "  FAIL: target-packages.txt not found"
fi

echo ""
echo "[Test Group 9] Syntax validation"
if bash -n "$LAUNCH_SCRIPT" 2>/dev/null; then
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
  echo "  PASS: launcher has valid bash syntax"
else
  FAILED=$((FAILED + 1))
  echo "  FAIL: launcher has syntax errors"
fi

echo ""
echo "[Test Group 10] Fingerprint override flag support"
assert_contains "$LAUNCH_SCRIPT" 'KIOSK_ALLOW_OVERRIDE_FINGERPRINT' \
  "launch script reads KIOSK_ALLOW_OVERRIDE_FINGERPRINT env var"
assert_contains "$LAUNCH_SCRIPT" '\-\-allow-override-fingerprint' \
  "launch script passes --allow-override-fingerprint to Electron when enabled"
assert_not_contains "$LAUNCH_SCRIPT" 'KIOSK_ALLOW_OVERRIDE_FINGERPRINT=1' \
  "launch script uses variable reference, not hardcoded value"

echo ""
echo "[Test Group 11] Chromium OSCrypt backend selection"
assert_contains "$LAUNCH_SCRIPT" 'XDG_CURRENT_DESKTOP' \
  "launch script exports XDG_CURRENT_DESKTOP for Chromium backend detection"
assert_contains "$LAUNCH_SCRIPT" 'password-store=gnome-libsecret' \
  "launch script passes --password-store=gnome-libsecret (bare 'gnome' is rejected by newer Chromium OSCrypt)"
assert_contains "$LAUNCH_SCRIPT" 'electron_args=' \
  "launch script uses electron_args array for Electron flags"

echo ""
echo "[Test Group 12] Keyring state preservation"
assert_not_contains "$LAUNCH_SCRIPT" 'rm -rf "\${XDG_RUNTIME_DIR:?}/keyring"' \
  "runtime keyring state is never wiped at kiosk startup"
assert_not_contains "$LAUNCH_SCRIPT" '\.local/share/keyrings' \
  "persisted keyring collections are never deleted at kiosk startup"

echo ""
echo "=========================================="
echo " Results: $PASSED passed, $FAILED failed, $TOTAL total"
echo "=========================================="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
