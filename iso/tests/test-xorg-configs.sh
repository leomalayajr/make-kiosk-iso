#!/usr/bin/env bash
# =============================================================================
# test-xorg-configs.sh — verify the installed kiosk Xorg display configuration.
# =============================================================================
QUICK_ONLY=1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISO_DIR="$PROJECT_DIR/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s: %s\n' "$RED" "$NC" "$*"; }
warn() { WARN=$((WARN + 1)); printf '  %sWARN%s: %s\n' "$YELLOW" "$NC" "$*"; }

check_xorg_config() {
  local config_path=$1 label=$2
  local full_path="$ISO_DIR/$config_path"

  if [[ ! -f "$full_path" ]]; then
    fail "$label — file not found: $config_path"
    return
  fi

  ok "$label exists: $(basename "$config_path")"

  # Must specify the resolution
  if grep -q '1024x768' "$full_path"; then
    ok "$label has 1024x768 resolution"
  else
    fail "$label missing 1024x768 resolution"
  fi

  # Must be in a Modes line or similar
  if grep -q 'Modes.*1024x768\|1024x768.*Modes' "$full_path"; then
    ok "$label has proper Modes directive"
  else
    warn "$label resolution may not be enforced properly (no Modes directive)"
  fi

  # Should target the right screen section
  if grep -q 'Screen\|Device\|Monitor' "$full_path"; then
    ok "$label references display components"
  else
    fail "$label missing Screen/Device/Monitor references"
  fi
}

printf '\n=== Target Xorg Config ===\n'

check_xorg_config \
  "target-rootfs/etc/X11/xorg.conf.d/60-kiosk-display.conf" \
  "Target (kiosk) Xorg config"

target_conf="$ISO_DIR/target-rootfs/etc/X11/xorg.conf.d/60-kiosk-display.conf"

# Check that Xorg config uses the right driver
if [[ -f "$target_conf" ]]; then
  if grep -q 'libinput\|modesetting\|vesa' "$target_conf"; then
    ok "Target Xorg config uses a valid input driver"
  else
    warn "Target Xorg config may not specify an input driver explicitly"
  fi
fi

if [[ ! -e "$ISO_DIR/installer-rootfs/etc/X11/xorg.conf.d/60-kiosk-display.conf" ]]; then
  ok "Installer has no Xorg configuration (console-only)"
else
  fail "Installer Xorg configuration should be absent"
fi

printf '\nResults: %s passed, %s failed, %s warnings\n' "$PASS" "$FAIL" "$WARN"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sXORG CONFIG CHECK FAILED%s\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
