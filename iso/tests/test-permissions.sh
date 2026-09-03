#!/usr/bin/env bash
# =============================================================================
# test-permissions.sh — verify file permissions, ownership, and command
# availability across all rootfs trees used by Offline Kiosk.
#
# Covers: installer live root, installed target root, build context scripts,
# systemd units, tmpfiles, Xorg config, electron app bundle layout,
# user/group setup, and critical binary paths.
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

# --- helper -----------------------------------------------------------------

check_executable() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ -x "$full" ]]; then
    ok "$label is executable: $path"
  else
    fail "$label not executable or missing: $path"
  fi
}

check_file_perms() {
  local path=$1 expected_mode=$2 label=$3
  local full="$ISO_DIR/$path"
  if [[ ! -e "$full" ]]; then
    fail "$label missing: $path"
    return
  fi
  local actual
  actual=$(stat -c '%a' "$full")
  if [[ "$actual" == "$expected_mode" ]]; then
    ok "$label has mode $expected_mode: $path"
  else
    fail "$label mode is $actual (expected $expected_mode): $path"
  fi
}

check_file_owner() {
  local path=$1 expected_owner=$2 label=$3
  local full="$ISO_DIR/$path"
  if [[ ! -e "$full" ]]; then
    fail "$label missing: $path"
    return
  fi
  local actual
  actual=$(stat -c '%U' "$full")
  if [[ "$actual" == "$expected_owner" ]]; then
    ok "$label owned by $expected_owner: $path"
  else
    fail "$label owned by $actual (expected $expected_owner): $path"
  fi
}

check_not_present() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ ! -e "$full" ]]; then
    ok "$label correctly absent: $path"
  else
    fail "$label unexpectedly present: $path"
  fi
}

check_contains() {
  local path=$1 pattern=$2 label=$3
  local full="$ISO_DIR/$path"
  if [[ ! -f "$full" ]]; then
    fail "$label — file missing: $path"
    return
  fi
  if grep -qE -- "$pattern" "$full"; then
    ok "$label matches pattern in $path"
  else
    fail "$label pattern not found in $path: $pattern"
  fi
}

check_group_membership() {
  local conf_path=$1 user=$2 group=$3 label=$4
  local full="$ISO_DIR/$conf_path"
  if [[ ! -f "$full" ]]; then
    fail "$label — sysusers file missing: $conf_path"
    return
  fi
  # Group membership must be an 'm' line (systemd-sysusers standard format).
  # The 'u' line only has 6 fields; trailing groups on it are silently ignored.
  if grep -q "^m $user $group" "$full"; then
    ok "$label: $user is in $group"
  else
    fail "$label: $user not assigned to $group via 'm' line in $conf_path"
  fi
}

check_tmpfiles_config() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ ! -f "$full" ]]; then
    fail "$label missing: $path"
    return
  fi
  ok "$label exists: $path"
}

check_service_direct_launch() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ ! -f "$full" ]]; then
    fail "$label — file missing: $path"
    return
  fi
  # Should NOT reference .xinitrc in ExecStart
  if grep -q '^ExecStart=.*\.xinitrc' "$full"; then
    fail "$label still uses .xinitrc in ExecStart"
  else
    ok "$label does not use .xinitrc in ExecStart"
  fi
}

check_service_file() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ ! -f "$full" ]]; then
    fail "$label — file not found: $path"
    return
  fi
  ok "$label exists: $(basename "$path")"
}

check_no_nonroot_chmod() {
  local path=$1 label=$2
  local full="$ISO_DIR/$path"
  if [[ ! -f "$full" ]]; then
    fail "$label — file missing: $path"
    return
  fi
  # A non-root service should never chmod /tmp or other root-owned paths
  if grep -qE '^\[Service\]' "$full"; then
    local in_service=0
    while IFS= read -r line; do
      if [[ "$line" == "[Unit]" ]]; then
        in_service=0
      elif [[ "$line" == "[Service]" ]]; then
        in_service=1
      elif [[ "$line" == "["*"]" ]]; then
        in_service=0
      fi
      if [[ $in_service -eq 1 ]] && echo "$line" | grep -qE 'chmod.*/tmp'; then
        fail "$label has chmod of /tmp in [Service] section (non-root will fail)"
        return
      fi
    done < "$full"
    ok "$label does not chmod /tmp in service unit"
  fi
}

# --- tests ------------------------------------------------------------------

printf '\n=== Installer Rootfs — Scripts & Services ===\n'

check_executable "installer-rootfs/usr/local/bin/kiosk-installer-ui.sh" \
  "Installer UI script"
check_file_perms "installer-rootfs/usr/local/bin/kiosk-installer-ui.sh" "755" \
  "Installer UI mode"

check_service_file "installer-rootfs/etc/systemd/system/kiosk-installer.service" \
  "Installer service"

printf '\n=== Target Rootfs — Core Files ===\n'

check_executable "target-rootfs/usr/local/bin/launch-electron.sh" \
  "Electron launcher"
check_file_perms "target-rootfs/usr/local/bin/launch-electron.sh" "755" \
  "Electron launcher mode"

# Owner is set by build-inside.sh at build time; verify the script sets it
if grep -q 'chown.*1000:1000.*electron-app\|chown.*appuser.*electron-app' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh sets electron-app ownership to appuser (uid 1000)"
else
  fail "build-inside.sh does not set electron-app ownership"
fi

# Environment file — should be root-owned, mode 0600 (created at build time)
if grep -q 'install.*-D.*-m 0600.*kiosk.env\|chmod.*0600.*kiosk.env' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh sets env file mode to 0600"
else
  fail "build-inside.sh does not set secure env file permissions"
fi

# tmpfiles.d config
check_tmpfiles_config "target-rootfs/etc/tmpfiles.d/kiosk-runtime.conf" \
  "Custom tmpfiles config"

printf '\n=== Target Rootfs — Xorg Configuration ===\n'

for conf in \
  "target-rootfs/etc/X11/xorg.conf.d/40-libinput.conf" \
  "target-rootfs/etc/X11/xorg.conf.d/50-kiosk.conf" \
  "target-rootfs/etc/X11/xorg.conf.d/60-kiosk-display.conf"; do
  if [[ -f "$ISO_DIR/$conf" ]]; then
    ok "Xorg config present: $(basename "$conf")"
  else
    fail "Xorg config missing: $conf"
  fi
done

check_contains "target-rootfs/etc/X11/xorg.conf.d/60-kiosk-display.conf" \
  'Modes "1024x768"' \
  "Display mode is fixed at 1024x768"

printf '\n=== Target Rootfs — systemd Services ===\n'

# Kiosk service should NOT use .xinitrc
check_service_direct_launch "target-rootfs/etc/systemd/system/kiosk.service" \
  "Kiosk service"

# Kiosk service should NOT chmod /tmp (non-root user can't)
check_no_nonroot_chmod "target-rootfs/etc/systemd/system/kiosk.service" \
  "Kiosk service permission check"

# Kiosk service should use PAMName=login for D-Bus session management
check_contains "target-rootfs/etc/systemd/system/kiosk.service" \
  'PAMName=login' \
  "Kiosk service uses PAMName=login"

# Kiosk service should have correct user/group
check_contains "target-rootfs/etc/systemd/system/kiosk.service" \
  'User=appuser' \
  "Kiosk runs as appuser"

printf '\n=== Target Rootfs — User / Group Setup ===\n'

check_group_membership "target-rootfs/usr/lib/sysusers.d/appuser.conf" \
  "appuser" "video" "Video group membership"
check_group_membership "target-rootfs/usr/lib/sysusers.d/appuser.conf" \
  "appuser" "input" "Input group membership"
check_group_membership "target-rootfs/usr/lib/sysusers.d/appuser.conf" \
  "appuser" "render" "Render group membership"

# appuser should have nologin shell (service doesn't need login)
check_contains "target-rootfs/usr/lib/sysusers.d/appuser.conf" \
  'nologin' \
  "appuser has nologin shell"

printf '\n=== Target Rootfs — Kiosk / Electron Integration ===\n'

# launch-electron.sh must reference electron app dir
check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  '/opt/electron-app' \
  "Launcher references electron app directory"

check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  'export APPIMAGE=' \
  "Launcher exports the stable AppImage path for electron-updater"

check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  'KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64' \
  "Launcher supplies updater cache configuration"

# Must have GPU fallback logic
check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  'disable-gpu' \
  "Launcher has GPU fallback (--disable-gpu)"

check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  'renderD' \
  "Launcher checks for render node"

# Must use --no-sandbox (runs as non-root user)
check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  '--no-sandbox' \
  "Launcher uses --no-sandbox for non-root execution"

# Fixed resolution enforcement
check_contains "target-rootfs/usr/local/bin/launch-electron.sh" \
  '1024,768' \
  "Launcher enforces fixed 1024x768 window size"

printf '\n=== Target Rootfs — Security: masked services ===\n'

# These are created at build time, but the masking logic must exist in build-inside.sh
if grep -q 'ln -sfn /dev/null.*getty@tty' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh masks getty@tty1"
else
  fail "build-inside.sh does not mask getty@tty1"
fi

if grep -q 'ln -sfn /dev/null.*serial-getty' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh masks serial-getty"
else
  fail "build-inside.sh does not mask serial-getty"
fi

if grep -q 'ln -sfn /dev/null.*sshd' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh masks sshd"
else
  fail "build-inside.sh does not mask sshd"
fi

printf '\n=== Target Rootfs — No .xinitrc in target ===\n'

if [[ ! -f "$ISO_DIR/target-rootfs/home/appuser/.xinitrc" ]]; then
  ok "No .xinitrc in target root (kiosk uses direct ExecStart)"
else
  fail ".xinitrc present in target root — should be removed"
fi

printf '\n=== Target Rootfs — Network Config ===\n'

check_contains "target-rootfs/etc/systemd/network/20-wired-dhcp.network" \
  'DHCP=yes' \
  "Network uses DHCP"
check_contains "target-rootfs/etc/systemd/network/20-wired-dhcp.network" \
  '\[Match\]' \
  "Network config has [Match]"
check_contains "target-rootfs/etc/systemd/network/20-wired-dhcp.network" \
  '\[Network\]' \
  "Network config has [Network]"

printf '\n=== Target Rootfs — Pruned packages ===\n'

# pacman should be removed from target
if [[ ! -f "$ISO_DIR/target-rootfs/usr/bin/pacman" ]]; then
  ok "pacman binary pruned from target root"
else
  fail "pacman still present in target root"
fi

if [[ ! -d "$ISO_DIR/target-rootfs/var/lib/pacman" ]]; then
  ok "pacman database pruned from target root"
else
  fail "pacman database still present in target root"
fi

if [[ ! -d "$ISO_DIR/target-rootfs/usr/share/doc" ]]; then
  ok "documentation pruned from target root"
else
  fail "documentation still present in target root"
fi

printf '\n=== Build Script Safety Checks ===\n'

# build-inside.sh should create .cache dir for appuser
if grep -q 'mkdir.*appuser.*\.cache\|mkdir.*-p.*appuser' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh creates appuser home/.cache"
else
  fail "build-inside.sh does not create appuser home directory"
fi

# build-inside.sh should chown electron-app to appuser
if grep -q 'chown.*appuser.*electron-app\|chown.*1000:1000.*electron-app' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh sets electron-app ownership to appuser"
else
  fail "build-inside.sh does not set electron-app ownership"
fi

# build-inside.sh should set env file permissions to 0600
if grep -q 'chmod.*0600.*kiosk.env\|install.*-m 0600.*kiosk.env' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh sets env file mode to 0600"
else
  fail "build-inside.sh does not set secure env file permissions"
fi

# make-kiosk-iso.sh should reject non-1024x768 resolution
if grep -q '1024x768' "$PROJECT_DIR/make-kiosk-iso.sh"; then
  ok "make-kiosk-iso.sh enforces 1024x768 resolution"
else
  fail "make-kiosk-iso.sh does not enforce fixed resolution"
fi

# credential_args should use safe expansion (no unbound variable risk)
if grep -q 'credential_args=()' "$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"; then
  ok "launch-electron.sh initializes credential_args as empty array"
else
  fail "launch-electron.sh does not initialize credential_args"
fi

# Verify no unquoted ${credential_args[@]} that could break with set -u
if grep -q '${credential_args[@]}' "$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"; then
  fail "launch-electron.sh uses \${credential_args[@]} which fails with set -u on empty array"
else
  ok "launch-electron.sh uses safe credential expansion"
fi

printf '\n=== Installer Script Safety ===\n'

# kiosk-installer-ui.sh should verify checksum before installing
if grep -q 'sha512sum.*-c' "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"; then
  ok "Installer verifies archive checksum"
else
  fail "Installer does not verify archive checksum"
fi

# Installer should wipe disk only after confirmation
if grep -q 'wipefs\|sgdisk' "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"; then
  ok "Installer uses safe disk operations (wipefs/sgdisk)"
else
  fail "Installer missing safe disk operations"
fi

# Installer should log to /var/log/kiosk-installer.log
if grep -q '/var/log/kiosk-installer.log' "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"; then
  ok "Installer logs to /var/log/kiosk-installer.log"
else
  fail "Installer missing log path"
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sPERMISSION CHECK FAILED%s\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
