#!/usr/bin/env bash
# =============================================================================
# test-security-runtime.sh — verify that the kiosk launch chain provides the
# D-Bus session, gnome-keyring, libsecret, and fingerprint-data prerequisites
# required by Electron's secure-storage and generate-fingerprint APIs.
#
# These checks run against source files (no Docker needed) because they verify
# build-time configuration rather than runtime behaviour.
# =============================================================================
QUICK_ONLY=1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISO_DIR="$PROJECT_DIR/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s: %s\n' "$RED" "$NC" "$*"; }
warn() { printf '  %sWARN%s: %s\n' "$(tput setaf 3)" "$(tput sgr0)" "$*"; }

launcher="$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"
kiosk_svc="$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"
target_pkgs="$ISO_DIR/target-packages.txt"
builder="$ISO_DIR/build-inside.sh"
installer="$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"

# ── Target packages: libsecret & gnome-keyring must be present ──────────

printf '\n=== Runtime Security Packages ===\n'

if grep -qx 'libsecret' "$target_pkgs"; then
  ok "libsecret listed in target-packages.txt (required for Electron secure-storage)"
else
  fail "libsecret missing from target-packages.txt — storage:clear will fail"
fi

if grep -qx 'gnome-keyring' "$target_pkgs"; then
  ok "gnome-keyring listed in target-packages.txt (secrets backend for libsecret)"
else
  fail "gnome-keyring missing from target-packages.txt — libsecret has no secrets backend"
fi

# ── kiosk.service: keyring starts inside Electron's D-Bus session ───────

printf '\n=== Kiosk Service — Keyring Startup ===\n'

if [[ -f "$kiosk_svc" ]]; then
  if grep -q 'ExecStartPre.*gnome-keyring-daemon' "$kiosk_svc"; then
    fail "kiosk.service starts gnome-keyring before the PAM session bus"
  else
    ok "kiosk.service does not start gnome-keyring outside the session bus"
  fi

  if grep -q 'cap_ipc_lock' "$builder"; then
    ok "Builder grants gnome-keyring the memory-lock capability"
  else
    fail "Builder does not grant CAP_IPC_LOCK — gnome-keyring aborts under libcap-ng"
  fi

  if grep -q "xattrs-include='security.capability'" "$builder"; then
    ok "Target archive preserves the gnome-keyring file capability"
  else
    fail "Target archive may discard gnome-keyring's file capability"
  fi
else
  fail "kiosk.service not found at $kiosk_svc"
fi

# ── kiosk.service: PAMName=login present ────────────────────────────────

printf '\n=== Kiosk Service — D-Bus Session ===\n'

if [[ -f "$kiosk_svc" ]]; then
  if grep -q 'PAMName=login' "$kiosk_svc"; then
    ok "kiosk.service uses PAMName=login for user session bus"
  else
    fail "kiosk.service does not use PAMName=login — libsecret fails without D-Bus session"
  fi

  if grep -q 'After=.*multi-user\.target\|After=.*systemd-user-sessions' "$kiosk_svc"; then
    ok "kiosk.service waits for system readiness (After= directive)"
  else
    warn "kiosk.service After= may not wait for user session; consider systemd-user-sessions.target"
  fi
else
  fail "kiosk.service not found"
fi

# ── installer: least-privilege DMI identity exposure ────────────────────

printf '\n=== Installer — Machine Identity ===\n'

if grep -q '^write_machine_identity()' "$installer"; then
  ok "Installer selects a privileged DMI identity before first boot"
else
  fail "Installer does not prepare the machine identity"
fi

if grep -q 'systemd-machine-id-setup.*--root' "$installer"; then
  ok "Installer creates a unique target machine-id"
else
  fail "Installer does not initialize the target OS GUID"
fi

if grep -q 'BindReadOnlyPaths=.*/kiosk-board-serial:.*/board_serial' "$kiosk_svc"; then
  ok "Kiosk exposes only the selected identity at board_serial"
else
  fail "Kiosk does not expose a readable board serial to Electron"
fi

# ── launch-electron.sh: syntax check ────────────────────────────────────

printf '\n=== Launcher — Syntax Validation ===\n'

if [[ -f "$launcher" ]]; then
  if bash -n "$launcher" 2>/dev/null; then
    ok "launch-electron.sh passes bash syntax check (bash -n)"
  else
    fail "launch-electron.sh has syntax errors — will crash at startup"
  fi

  # Ensure no 'local' is used outside of functions (common cause of crashes)
  local_outside_func=0
  in_function=0
  while IFS= read -r line; do
    # Strip leading/trailing whitespace for analysis
    trimmed=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    # Skip comments and blank lines
    [[ "$trimmed" =~ ^#.*$ || -z "$trimmed" ]] && continue
    if [[ "$trimmed" =~ ^[a-zA-Z_]+\(\) ]]; then
      in_function=1
      continue
    fi
    if [[ $in_function -eq 1 && "$trimmed" == "}"* ]]; then
      in_function=0
      continue
    fi
    # Check for 'local' at the start of a non-function line
    if [[ $in_function -eq 0 && "$trimmed" =~ ^local[[:space:]] ]]; then
      local_outside_func=1
    fi
  done < "$launcher"

  if [[ $local_outside_func -eq 0 ]]; then
    ok "No 'local' keyword used outside functions (prevents crash with set -e)"
  else
    fail "Found 'local' used outside of functions — will crash on some bash versions"
  fi
else
  fail "launch-electron.sh not found at $launcher"
fi

# ── launch-electron.sh: optional remote logging ─────────────────────────

printf '\n=== Launcher — Optional Remote Logging ===\n'

if [[ -f "$launcher" ]]; then
  if grep -q '^send_new_relic_log()' "$launcher" \
    && grep -q '^send_logger_server_log()' "$launcher"; then
    ok "Launcher supports independent New Relic and logger-server sinks"
  else
    fail "Launcher does not define both optional remote logging sinks"
  fi

  if grep -A3 '^remote_log()' "$launcher" | grep -q 'send_new_relic_log' \
    && grep -A4 '^remote_log()' "$launcher" | grep -q 'send_logger_server_log'; then
    ok "Launcher sends New Relic before the secondary logger-server"
  else
    fail "Launcher does not prioritize New Relic before logger-server"
  fi

  if grep -q -- "--header @-" "$launcher"; then
    ok "Launcher keeps the New Relic ingest key out of curl arguments"
  else
    fail "Launcher may expose the New Relic ingest key in curl arguments"
  fi

  if grep -q 'is_new_relic_log_endpoint' "$launcher"; then
    ok "Launcher restricts New Relic credentials to official Log API endpoints"
  else
    fail "Launcher does not restrict the New Relic Log API endpoint"
  fi

  if grep -q 'KIOSK_NEW_RELIC_LOG_ENABLED' "$launcher"; then
    ok "Launcher requires the explicit New Relic enable switch"
  else
    fail "Launcher may enable New Relic logging without the explicit switch"
  fi

  if grep -q 'KIOSK_NEW_RELIC_SERVICE_NAME_B64' "$launcher" \
    && grep -q 'service.name.*%s' "$launcher" \
    && grep -q 'json_escape "$NEW_RELIC_SERVICE_NAME"' "$launcher"; then
    ok "Launcher reads the configurable New Relic service name"
  else
    fail "Launcher does not use the configurable New Relic service name"
  fi
else
  fail "launch-electron.sh not found at $launcher"
fi

# ── installer: configurable New Relic service name ─────────────────────

printf '\n=== Installer — Configurable New Relic Service Name ===\n'

if [[ -f "$installer" ]]; then
  if grep -q 'KIOSK_NEW_RELIC_SERVICE_NAME_B64' "$installer" \
    && grep -q 'service.name.*%s' "$installer" \
    && grep -q 'json_escape "$NEW_RELIC_SERVICE_NAME"' "$installer"; then
    ok "Installer reads the configurable New Relic service name"
  else
    fail "Installer does not use the configurable New Relic service name"
  fi
else
  fail "kiosk-installer-ui.sh not found at $installer"
fi

# ── launch-electron.sh: D-Bus session guard ─────────────────────────────

printf '\n=== Launcher — D-Bus Session Guard ===\n'

if [[ -f "$launcher" ]]; then
  if grep -q 'DBUS_SESSION_BUS_ADDRESS' "$launcher"; then
    ok "Launcher checks DBUS_SESSION_BUS_ADDRESS environment variable"
  else
    fail "Launcher does not check DBUS_SESSION_BUS_ADDRESS — D-Bus issues will be silent"
  fi

  if grep -q 'XDG_RUNTIME_DIR.*run/user' "$launcher" && grep -q 'DBUS_SESSION_BUS_ADDRESS.*XDG_RUNTIME_DIR' "$launcher"; then
    ok "Launcher uses systemd user bus via XDG_RUNTIME_DIR"
  else
    fail "Launcher does not set user bus address — libsecret cannot reach gnome-keyring"
  fi

  if grep -q 'dbus-send' "$launcher"; then
    ok "Launcher verifies D-Bus session bus connectivity via dbus-send"
  else
    warn "Launcher does not actively verify D-Bus; relying on env var only"
  fi
else
  fail "launch-electron.sh not found at $launcher"
fi

# ── launch-electron.sh: gnome-keyring guard ─────────────────────────────

printf '\n=== Launcher — Keyring Guard ===\n'

if [[ -f "$launcher" ]]; then
  if grep -q 'gnome-keyring-daemon' "$launcher"; then
    ok "Launcher checks for running gnome-keyring-daemon"
  else
    fail "Launcher does not verify gnome-keyring-daemon — storage:clear will silently fail"
  fi

  if grep -q 'gnome-keyring-daemon.*--start\|gnome-keyring-daemon.*--daemonize' "$launcher"; then
    ok "Launcher can start gnome-keyring-daemon if not already running"
  else
    warn "Launcher does not attempt to start gnome-keyring-daemon"
  fi

  if grep -q '\[WARN\].*Secret Service\|\[ERROR\].*keyring\|\[ERROR\].*Secret Service' "$launcher"; then
    ok "Launcher logs when encrypted storage is unavailable"
  else
    warn "Launcher may not log keyring failure — debugging will be harder"
  fi

  # Ensure gnome-keyring-daemon stderr is captured for debugging capability errors
  if grep -q 'gnome-keyring-daemon.*2>>\|gnome-keyring-daemon.*stderr' "$launcher"; then
    ok "gnome-keyring-daemon stderr is redirected to log file for debugging"
  else
    warn "gnome-keyring-daemon stderr may not be captured — capability errors hard to debug"
  fi

  if grep -q 'org.freedesktop.secrets' "$launcher"; then
    ok "Launcher verifies the Secret Service owns its D-Bus name"
  else
    fail "Launcher does not verify Secret Service readiness"
  fi

  if grep -q 'keyring_available.*-ne 1' "$launcher"; then
    if grep -q 'launching Electron with its storage fallback' "$launcher"; then
      ok "Launcher uses Electron storage fallback when encrypted storage is unavailable"
    else
      fail "Launcher checks keyring availability but lacks a boot-safe fallback"
    fi
  else
    fail "Launcher does not handle Secret Service unavailability"
  fi
else
  fail "launch-electron.sh not found"
fi

# ── launch-electron.sh: fingerprint data guard ──────────────────────────

printf '\n=== Launcher — Fingerprint Data Guard ===\n'

if [[ -f "$launcher" ]]; then
  if grep -q '/sys/class/dmi/id/' "$launcher"; then
    ok "Launcher reads DMI/sysfs paths for machine fingerprint"
  else
    fail "Launcher does not read DMI/sysfs — generate-fingerprint will fail on first boot"
  fi

  if grep -q 'board_serial' "$launcher"; then
    ok "Launcher checks /sys/class/dmi/id/board_serial"
  else
    warn "Launcher does not check board_serial fingerprint source"
  fi

  if grep -q 'product_uuid' "$launcher"; then
    ok "Launcher checks /sys/class/dmi/id/product_uuid"
  else
    warn "Launcher does not check product_uuid fingerprint source"
  fi

  if grep -q 'product_serial' "$launcher"; then
    ok "Launcher checks /sys/class/dmi/id/product_serial (OEM service tags)"
  else
    warn "Launcher does not check product_serial fingerprint source"
  fi

  if grep -q 'machine-id' "$launcher"; then
    ok "Launcher checks /etc/machine-id as VM/cloud fallback"
  else
    warn "Launcher does not check machine-id — VMs may fail fingerprint"
  fi

  if grep -q 'ip -br link\|sha256sum.*board' "$launcher"; then
    ok "Launcher has fingerprint fallback (MAC / board hash)"
  else
    fail "Launcher has no fingerprint fallback — VMs/containers will break"
  fi

  if grep -q 'ip -br link' "$launcher"; then
    ok "Launcher checks network interfaces for fingerprint data"
  else
    warn "Launcher does not check network interfaces"
  fi

  if grep -q 'fingerprint_data' "$launcher"; then
    ok "Launcher uses collected fingerprint data as build-time fallback"
  else
    fail "Launcher has no fallback from collected fingerprint — empty builds will break"
  fi

  # Verify fingerprint source identification function exists (for better logging)
  if grep -q 'identify_fingerprint_source' "$launcher"; then
    ok "Launcher identifies which fingerprint source was used in logs"
  else
    warn "Launcher does not identify fingerprint source — harder to debug VM vs physical"
  fi

  # Verify collect_fingerprint is wrapped in a function (not bare code)
  if grep -q '^collect_fingerprint()' "$launcher"; then
    ok "collect_fingerprint() is a proper function (no 'local' outside scope issues)"
  else
    fail "collect_fingerprint may not be a function — local variable scope could break"
  fi

  # Verify no xrandr before Electron launch (xrandr without X server causes issues)
  if grep -B5 'exec.*app_bin\|"\$app_bin"' "$launcher" | grep -q 'xrandr'; then
    fail "xrandr call found before Electron launch — will fail without X server"
  else
    ok "No xrandr before Electron launch (safe for headless/kiosk startup)"
  fi
else
  fail "launch-electron.sh not found"
fi

# ── Summary ─────────────────────────────────────────────────────────────

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sSECURITY RUNTIME CHECK FAILED%s — check failures above\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
