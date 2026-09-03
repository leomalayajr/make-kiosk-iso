#!/usr/bin/env bash
# =============================================================================
# test-systemd-services.sh — verify systemd service files are valid,
# properly enabled, and have correct configurations.
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

check_service_file() {
  local service_path=$1 label=$2
  local full_path="$ISO_DIR/$service_path"

  if [[ ! -f "$full_path" ]]; then
    fail "$label — file not found: $service_path"
    return
  fi

  ok "$label exists: $(basename "$service_path")"

  # Must have [Unit] section
  if grep -q '^\[Unit\]' "$full_path"; then
    ok "$(basename "$service_path") has [Unit] section"
  else
    fail "$(basename "$service_path") missing [Unit] section"
  fi

  # Must have [Service] section
  if grep -q '^\[Service\]' "$full_path"; then
    ok "$(basename "$service_path") has [Service] section"
  else
    fail "$(basename "$service_path") missing [Service] section"
  fi

  # Must have ExecStart
  if grep -q '^ExecStart=' "$full_path"; then
    ok "$(basename "$service_path") has ExecStart"
  else
    fail "$(basename "$service_path") missing ExecStart directive"
  fi

  # Must have [Install] section with WantedBy
  if grep -q '^\[Install\]' "$full_path" && grep -q 'WantedBy=' "$full_path"; then
    ok "$(basename "$service_path") has [Install] WantedBy"
  else
    fail "$(basename "$service_path") missing [Install] or WantedBy"
  fi
}

check_service_disabled() {
  local service_path=$1 label=$2
  local full_path="$ISO_DIR/$service_path"

  if [[ -f "$full_path" ]]; then
    local link_target
    link_target=$(readlink "$full_path" 2>/dev/null || true)
    if [[ "$link_target" == "/dev/null" ]]; then
      ok "$label is correctly masked (symlink to /dev/null)"
    else
      fail "$label should be masked but points to: $link_target"
    fi
  else
    fail "$label — file not found: $service_path"
  fi
}

printf '\n=== Installer Service ===\n'

check_service_file "installer-rootfs/etc/systemd/system/kiosk-installer.service" \
  "Installer service"

# Check installer service runs the console script directly on tty1
if grep -q '^ExecStart=/usr/local/bin/kiosk-installer-ui.sh$' "$ISO_DIR/installer-rootfs/etc/systemd/system/kiosk-installer.service" 2>/dev/null; then
  ok "Installer service launches the console installer directly"
else
  fail "Installer service does not launch the console installer directly"
fi

if grep -q '^StandardOutput=tty$' "$ISO_DIR/installer-rootfs/etc/systemd/system/kiosk-installer.service" 2>/dev/null && \
   grep -q '^StandardError=tty$' "$ISO_DIR/installer-rootfs/etc/systemd/system/kiosk-installer.service" 2>/dev/null; then
  ok "Installer output and errors are routed directly to tty1"
else
  fail "Installer output and errors are not routed directly to tty1"
fi

printf '\n=== Kiosk Service ===\n'

check_service_file "target-rootfs/etc/systemd/system/kiosk.service" \
  "Kiosk service"

# Check kiosk service has restart policy with a start limit (prevents
# infinite restart loops while still auto-recovering transient failures)
if grep -q 'Restart=always' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service has Restart=always (including clean updater exits)"
else
  fail "Kiosk service missing Restart=always — installed updates may not relaunch"
fi
if grep -q 'StartLimitBurst=' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service has StartLimitBurst (prevents infinite restart loop)"
else
  fail "Kiosk service missing StartLimitBurst — may loop forever on hard failure"
fi

# Check kiosk service uses startx
if grep -q 'ExecStart=.*startx' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service launches via startx"
else
  fail "Kiosk service does not use startx to launch X session"
fi

if grep -q '^ExecStart=/usr/bin/startx /usr/local/bin/launch-electron.sh' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk starts Electron directly without an xinitrc hop"
else
  fail "Kiosk does not start Electron directly"
fi

# PAMName=login provides the systemd user session bus so Electron and
# gnome-keyring share a single session.  dbus-run-session is not used.
if grep -q '^PAMName=login' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk uses PAMName=login for user session bus"
else
  fail "Kiosk missing PAMName=login — no user session bus for gnome-keyring"
fi

# Check kiosk service has EnvironmentFile
if grep -q 'EnvironmentFile=' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service loads environment file"
else
  fail "Kiosk service missing EnvironmentFile — no credentials at runtime"
fi

# Kiosk service must set HOME so startx can resolve .Xauthority
if grep -q '^Environment=HOME=' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service sets HOME for X authority resolution"
else
  fail "Kiosk service missing HOME env — startx cannot create .Xauthority"
fi

# Kiosk service must create .Xauthority before launching X
if grep -q 'ExecStartPre=.*touch.*/\.Xauthority' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service creates .Xauthority before starting X"
else
  fail "Kiosk service does not create .Xauthority — Electron cannot connect to X server"
fi

# Kiosk service must chown .Xauthority to the app user — must run as root (+)
if grep -q 'ExecStartPre=+.*chown.*\.Xauthority' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service chowns .Xauthority as root (+ prefix)"
else
  fail "Kiosk service does not chown .Xauthority as root — appuser cannot chown"
fi

# Kiosk service must have RuntimeDirectory for GPU state tracking
if grep -q 'RuntimeDirectory=kiosk' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service has RuntimeDirectory for state directory"
else
  fail "Kiosk service missing RuntimeDirectory — /run/kiosk creation may fail"
fi

if grep -q '^BindReadOnlyPaths=/etc/kiosk-board-serial:/sys/devices/virtual/dmi/id/board_serial$' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk exposes the selected machine identity read-only"
else
  fail "Kiosk does not provide Electron a readable board serial"
fi

if grep -q '^ExecStartPre=.*gnome-keyring-daemon' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  fail "Kiosk starts gnome-keyring before its D-Bus session exists"
else
  ok "Kiosk starts gnome-keyring only inside the D-Bus session"
fi

# Kiosk service must trigger failure diagnostics
if grep -q 'OnFailure=kiosk-failure.service' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk.service"; then
  ok "Kiosk service triggers failure diagnostics on crash"
else
  fail "Kiosk service missing OnFailure — no diagnostics shown on crash"
fi

printf '\n=== Kiosk Update Refresh Timer ===\n'

if [[ -f "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.service" ]]; then
  ok "Kiosk refresh service exists"
  grep -q '^ExecStart=/usr/bin/systemctl try-restart kiosk.service$' \
    "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.service" \
    && ok "Kiosk refresh service restarts the kiosk safely" \
    || fail "Kiosk refresh service does not restart kiosk.service"
else
  fail "Kiosk refresh service missing"
fi
if [[ -f "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.timer" ]]; then
  ok "Kiosk refresh timer exists"
  grep -q '^OnCalendar=\*-\*-\* 03:00:00$' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.timer" \
    && ok "Kiosk refresh timer runs daily" \
    || fail "Kiosk refresh timer is not scheduled daily"
  grep -q '^RandomizedDelaySec=4h$' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-refresh.timer" \
    && ok "Kiosk refresh timer staggers fleet checks" \
    || fail "Kiosk refresh timer lacks fleet-safe jitter"
else
  fail "Kiosk refresh timer missing"
fi

# Kiosk failure diagnostics service must exist and run the failure script
if [[ -f "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-failure.service" ]]; then
  ok "Kiosk failure service exists: kiosk-failure.service"
  if grep -q 'kiosk-show-failure.sh' "$ISO_DIR/target-rootfs/etc/systemd/system/kiosk-failure.service"; then
    ok "Kiosk failure service runs diagnostics script"
  else
    fail "Kiosk failure service does not reference kiosk-show-failure.sh"
  fi
else
  fail "Kiosk failure service missing — no diagnostics on crash"
fi

# Kiosk failure diagnostics script must exist and be executable
if [[ -f "$ISO_DIR/target-rootfs/usr/local/bin/kiosk-show-failure.sh" ]]; then
  ok "Kiosk failure diagnostics script exists: kiosk-show-failure.sh"
  if [[ -x "$ISO_DIR/target-rootfs/usr/local/bin/kiosk-show-failure.sh" ]]; then
    ok "Kiosk failure diagnostics script is executable"
  else
    fail "Kiosk failure diagnostics script is not executable"
  fi
else
  fail "Kiosk failure diagnostics script missing"
fi

# Boot parameters must disable RDSEED32 (broken on some CPUs, causes hangs)
if grep -q 'rdseed=off' "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"; then
  ok "Installer disables rdseed32 in boot parameters (prevents CPU hang)"
else
  fail "Boot parameters missing rdseed=off — broken RDSEED32 may cause boot hang"
fi

# Boot parameters must NOT suppress output with quiet/loglevel=3
if grep -q 'quiet loglevel=3' "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"; then
  fail "Boot parameters use 'quiet loglevel=3' — boot progress is invisible"
else
  ok "Boot parameters do not suppress output (boot progress visible)"
fi

printf '\n=== Security: Services that should be masked ===\n'

# These services are masked dynamically at build time by build-inside.sh.
# The tests verify the masking logic exists in build-inside.sh instead.
printf '  (Checking build-inside.sh creates masked symlinks for getty/sshd)\n'

if grep -q 'ln -sfn /dev/null.*getty' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh masks getty services at build time"
else
  fail "build-inside.sh does not mask getty services"
fi

if grep -q 'ln -sfn /dev/null.*sshd' "$ISO_DIR/build-inside.sh"; then
  ok "build-inside.sh masks sshd at build time"
else
  fail "build-inside.sh does not mask sshd"
fi

# Verify the network config exists at the right path
network_conf="$ISO_DIR/target-rootfs/etc/systemd/network/20-wired-dhcp.network"
if [[ -f "$network_conf" ]]; then
  ok "Network config found at expected path"
else
  fail "Network config not found at: $network_conf"
fi

printf '\n=== Network Config ===\n'

if [[ -f "$network_conf" ]]; then
  if grep -q 'DHCP=yes' "$network_conf"; then
    ok "Network config uses DHCP"
  else
    fail "Network config does not use DHCP"
  fi

  if grep -q '\[Match\]' "$network_conf"; then
    ok "Network config has [Match] section"
  else
    fail "Network config missing [Match] section"
  fi

  if grep -q '\[Network\]' "$network_conf"; then
    ok "Network config has [Network] section"
  else
    fail "Network config missing [Network] section"
  fi
else
  fail "Network config not found: $network_conf"
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sSYSTEMD SERVICE CHECK FAILED%s\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
