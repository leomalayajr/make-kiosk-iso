#!/usr/bin/env bash
# =============================================================================
# test-installer-completeness.sh — verify that the installer has all required
# components, services, configs, and assets in place.
#
# This simulates what the live ISO would contain without actually building it.
# =============================================================================
QUICK_ONLY=1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISO_DIR="$PROJECT_DIR/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s: %s\n' "$RED" "$NC" "$*"; }
warn() { WARN=$((WARN + 1)); printf '  %sWARN%s: %s\n' "$YELLOW" "$NC" "$*"; }

# --- Installer Live Root ===

printf '\n=== Installer Overlay Files ===\n'

check_file() {
  local path=$1 label=$2 should_exist=${3:-true}
  local full_path="$ISO_DIR/installer-rootfs/$path"
  if [[ "$should_exist" == "true" ]]; then
    if [[ -e "$full_path" || -L "$full_path" ]]; then
      ok "$label : $path"
    else
      fail "$label — missing: $path"
    fi
  else
    if [[ ! -e "$full_path" && ! -L "$full_path" ]]; then
      ok "$label correctly absent: $path"
    else
      fail "$label should NOT exist: $path"
    fi
  fi
}

# Core installer script
check_file "usr/local/bin/kiosk-installer-ui.sh" "Console installer script"
check_file "usr/local/bin/kiosk-installer-session.sh" "No installer X session" false
check_file "usr/local/bin/kiosk-installer-panel.py" "No installer GUI panel" false

# Installer systemd service
check_file "etc/systemd/system/kiosk-installer.service" "Installer systemd service"

check_file "etc/X11/xorg.conf.d/60-kiosk-display.conf" "No installer Xorg config" false
check_file "etc/plymouth/plymouthd.conf" "No installer Plymouth config" false

# --- Installer UI Script Content Checks ===

printf '\n=== Installer UI Script — Critical Patterns ===\n'

ui_script="$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"

check_pattern_in_file() {
  local file=$1 pattern=$2 label=$3 should_exist=${4:-true}
  if grep -qE -- "$pattern" "$file" 2>/dev/null; then
    if [[ "$should_exist" == "true" ]]; then
      ok "UI script contains: $label"
    else
      fail "UI script should NOT contain: $label"
    fi
  else
    if [[ "$should_exist" == "true" ]]; then
      fail "UI script missing critical pattern: $label (pattern: '$pattern')"
    else
      ok "UI script correctly excludes: $label"
    fi
  fi
}

# The installer MUST use destructive operations
check_pattern_in_file "$ui_script" 'wipefs --all' "disk wipe command"
check_pattern_in_file "$ui_script" 'sgdisk --clear' "GPT partition clearing"
check_pattern_in_file "$ui_script" 'set -Eeuo pipefail' "strict error handling"

# Must check integrity of the target archive
check_pattern_in_file "$ui_script" 'sha512sum.*-c' "archive integrity verification"

# Must use bsdtar for extraction
check_pattern_in_file "$ui_script" 'bsdtar' "archive extraction tool"

# Must have proper error handling
check_pattern_in_file "$ui_script" 'show_error' "error handler function"
check_pattern_in_file "$ui_script" 'systemctl reboot' "reboot on completion/error"
check_pattern_in_file "$ui_script" 'Press Enter to begin installation' "Enter confirmation"
check_pattern_in_file "$ui_script" 'Recent installer log' "console failure diagnostics"
check_pattern_in_file "$ui_script" 'systemd-machine-id-setup.*--root' "unique installed machine-id"
check_pattern_in_file "$ui_script" '^write_machine_identity' "hardware identity preparation"
check_pattern_in_file "$ui_script" 'kiosk-board-serial' "readable Electron board serial"
check_pattern_in_file "$ui_script" 'kiosk-installer-panel.py' "GUI panel invocation" false
check_pattern_in_file "$ui_script" 'xrandr' "X display invocation" false

# The installer remains offline-first: it must not download packages, but may
# make a bounded best-effort error-log delivery after an installation failure.
check_pattern_in_file "$ui_script" 'pacman -S' "NO online package install" false
check_pattern_in_file "$ui_script" '^send_install_error_logs' "best-effort installation error logging"
check_pattern_in_file "$ui_script" '^send_install_started_logs' "best-effort installation-start logging"
check_pattern_in_file "$ui_script" 'Installation initiated log delivered to New Relic' "New Relic-first installation-start logging"
check_pattern_in_file "$ui_script" 'isoVersion.*cpuModel.*memoryMiB.*targetDiskModel' "installation-start hardware metadata"
check_pattern_in_file "$ui_script" 'Attempt to send error logs failed because there is no internet connection' "offline error-log retry guidance"
check_pattern_in_file "$ui_script" 'Press R to retry sending error logs' "manual error-log retry option"
check_pattern_in_file "$ui_script" 'wget' "NO wget usage" false

# --- Target Rootfs ===

printf '\n=== Target Overlay Files ===\n'

check_file2() {
  local path=$1 label=$2 should_exist=${3:-true}
  local full_path="$ISO_DIR/target-rootfs/$path"
  if [[ "$should_exist" == "true" ]]; then
    if [[ -e "$full_path" || -L "$full_path" ]]; then
      ok "$label : $path"
    else
      fail "$label — missing: $path"
    fi
  else
    if [[ ! -e "$full_path" && ! -L "$full_path" ]]; then
      ok "$label correctly absent: $path"
    else
      fail "$label should NOT exist: $path"
    fi
  fi
}

# Core kiosk components
check_file2 "usr/local/bin/launch-electron.sh" "Kiosk Electron launcher"
check_file2 "usr/local/bin/kiosk-show-failure.sh" "Kiosk failure diagnostics script"
check_file2 "etc/systemd/system/kiosk.service" "Kiosk systemd service"
check_file2 "etc/systemd/system/kiosk-failure.service" "Kiosk failure diagnostics service"
check_file2 "etc/systemd/system/kiosk-refresh.service" "Kiosk update refresh service"
check_file2 "etc/systemd/system/kiosk-refresh.timer" "Randomized kiosk update refresh timer"
check_file2 "etc/systemd/network/20-wired-dhcp.network" "Wired DHCP network config"
check_file2 "etc/X11/xorg.conf.d/60-kiosk-display.conf" "Target Xorg display config"
check_file2 "usr/lib/sysusers.d/appuser.conf" "App user sysusers config"
check_file2 "home/appuser/.xinitrc" "No app-user xinitrc hop" false

# Target launch-electron.sh content checks
target_launch="$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"

printf '\n=== Target Launcher — Runtime Safety ===\n'

check_pattern_in_file "$target_launch" '--no-sandbox' "Electron no-sandbox flag"
check_pattern_in_file "$target_launch" 'window-size=1024,768' "Fixed window size"
check_pattern_in_file "$target_launch" 'gpu-attempted' "GPU fallback state tracking"
check_pattern_in_file "$target_launch" '--disable-gpu' "Software rendering fallback"
check_pattern_in_file "$target_launch" 'FIXED_RESOLUTION=1024x768' "Fixed resolution constant"
check_pattern_in_file "$target_launch" 'base64 -d' "Credential decoding"
check_pattern_in_file "$target_launch" 'org.freedesktop.secrets' "Secret Service readiness check"
check_pattern_in_file "$target_launch" 'export APPIMAGE=' "AppImage updater runtime context"
check_pattern_in_file "$target_launch" 'app-update.yml' "Runtime updater configuration"
check_pattern_in_file "$target_launch" 'KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64' "Configured updater cache directory"

# --- Build Script Checks ===

printf '\n=== Build Script — Critical Patterns ===\n'

build_script="$ISO_DIR/build-inside.sh"

check_pattern_in_file "$build_script" 'pacstrap' "Uses pacstrap for target root"
check_pattern_in_file "$build_script" 'mkarchiso' "Uses mkarchiso for ISO build"
check_pattern_in_file "$build_script" 'tar --zstd' "Creates zstd-compressed archive"
check_pattern_in_file "$build_script" 'sha512sum' "Generates SHA-512 checksums"
check_pattern_in_file "$build_script" 'systemd-sysusers' "Creates the kiosk application user"
check_pattern_in_file "$build_script" 'installed AppImage is not executable' "Rejects a missing AppImage entrypoint"
check_pattern_in_file "$build_script" 'setcap cap_ipc_lock' "Grants keyring memory-lock capability"
check_pattern_in_file "$build_script" "xattrs-include='security.capability'" "Preserves keyring file capability"

# bootctl and grub-install are called by the installer UI script, not build-inside.sh
ui_script="$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"
check_pattern_in_file "$ui_script" 'bootctl install' "Installer installs systemd-boot (UEFI)"
check_pattern_in_file "$ui_script" 'grub-install' "Installer installs GRUB (BIOS)"

# Must prune the target for size
check_pattern_in_file "$build_script" 'rm.*var/cache/pacman' "Removes pacman cache"
check_pattern_in_file "$build_script" 'rm.*var/lib/pacman' "Removes pacman database"
check_pattern_in_file "$build_script" 'rm.*pacman' "Removes pacman binary"
check_pattern_in_file "$build_script" '/usr/share/doc' "Removes documentation"

# --- Dockerfile.builder Checks ===

printf '\n=== Builder Image — Required Packages ===\n'

builder_dockerfile="$ISO_DIR/Dockerfile.builder"

if [[ -f "$builder_dockerfile" ]]; then
  check_pattern_in_file "$builder_dockerfile" 'archiso' "Builds with archiso"
  check_pattern_in_file "$builder_dockerfile" 'arch-install-scripts' "Has arch-install-scripts"
  check_pattern_in_file "$builder_dockerfile" 'gptfdisk' "Has GPT tools (sgdisk)"
  check_pattern_in_file "$builder_dockerfile" 'dosfstools' "Has FAT filesystem tools"
  check_pattern_in_file "$builder_dockerfile" 'e2fsprogs' "Has ext4 tools"
  check_pattern_in_file "$builder_dockerfile" 'zstd' "Has zstd compression"
  check_pattern_in_file "$builder_dockerfile" 'squashfs-tools' "Has squashfs tools"
  check_pattern_in_file "$builder_dockerfile" 'libisoburn' "Has ISO9660 burn tools"
  check_pattern_in_file "$builder_dockerfile" 'libarchive' "Has bsdtar for archive ops"
else
  fail "Dockerfile.builder not found at $builder_dockerfile"
fi

# --- Test Fixture Check ===

printf '\n=== Test Fixtures ===\n'

check_file2 "../test-fixtures/kiosk.env" "Test environment fixture"

# --- Summary ===

printf '\nResults: %s passed, %s failed, %s warnings\n' "$PASS" "$FAIL" "$WARN"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sINSTALLER COMPLETENESS CHECK FAILED%s\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
