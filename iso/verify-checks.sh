#!/usr/bin/env bash
# Runs inside the privileged builder image. It validates the temporary live
# installer root and the compressed target root separately.
set -Eeuo pipefail

ISO_FILE=${1:?missing ISO file}
LIVE_ROOT=/tmp/kiosk-live-root
TARGET_ROOT=/tmp/kiosk-target-root
ISO_MOUNT=/mnt/kiosk-iso
APP_AUDIT=/tmp/kiosk-appimage-audit
PASS=0
FAIL=0
ERRORS=()

ok() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }
exists() { { [ -e "$1" ] || [ -L "$1" ]; } && ok "$2" || fail "$2 (missing: $1)"; }
absent() { [ ! -e "$1" ] && ok "$2" || fail "$2 (unexpected: $1)"; }
contains() { grep -qE "$2" "$1" 2>/dev/null && ok "$3" || fail "$3"; }
masked() {
  [ "$(readlink "$1" 2>/dev/null || true)" = /dev/null ] && ok "$2" || fail "$2"
}

cleanup() {
  umount "$ISO_MOUNT" >/dev/null 2>&1 || true
  rm -rf "$LIVE_ROOT" "$TARGET_ROOT" "$ISO_MOUNT" "$APP_AUDIT"
}
trap cleanup EXIT

mkdir -p "$ISO_MOUNT"
mount -o loop,ro "$ISO_FILE" "$ISO_MOUNT"
unsquashfs -d "$LIVE_ROOT" "$ISO_MOUNT/arch/x86_64/airootfs.sfs" >/dev/null

BUNDLE_DIR="$LIVE_ROOT/opt/kiosk-installer"
BUNDLE="$BUNDLE_DIR/target-root.tar.zst"
CHECKSUM="$BUNDLE_DIR/target-root.tar.zst.sha512"

printf '\n== Installer live root ==\n'
exists "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'console installer script'
exists "$LIVE_ROOT/etc/systemd/system/kiosk-installer.service" 'installer service'
exists "$LIVE_ROOT/etc/kiosk-installer-logging.env" 'installer optional remote logging configuration'
exists "$LIVE_ROOT/etc/systemd/system/multi-user.target.wants/kiosk-installer.service" 'installer service enabled'
masked "$LIVE_ROOT/etc/systemd/system/getty@tty1.service" 'installer getty is masked'
masked "$LIVE_ROOT/etc/systemd/system/sshd.service" 'installer SSH is masked'
exists "$LIVE_ROOT/usr/bin/bash" 'Bash installer runtime'
exists "$LIVE_ROOT/usr/bin/curl" 'installer best-effort remote logging client'
absent "$LIVE_ROOT/usr/bin/startx" 'no installer display server launcher'
absent "$LIVE_ROOT/usr/bin/openbox" 'no installer window manager'
absent "$LIVE_ROOT/usr/bin/plymouth" 'no installer boot splash runtime'
exists "$LIVE_ROOT/usr/bin/sgdisk" 'GPT partitioning tool'
exists "$LIVE_ROOT/usr/bin/partprobe" 'partition-table refresh tool'
exists "$LIVE_ROOT/usr/bin/genfstab" 'offline fstab generation tool'
exists "$BUNDLE" 'offline target root archive'
exists "$CHECKSUM" 'target archive checksum'
contains "$LIVE_ROOT/etc/systemd/system/kiosk-installer.service" 'ExecStart=/usr/local/bin/kiosk-installer-ui.sh' 'installer starts directly on tty1'
contains "$LIVE_ROOT/etc/systemd/system/kiosk-installer.service" 'StandardOutput=tty' 'installer output is routed directly to tty1'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'Press Enter to begin installation' 'installer requires Enter confirmation'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'wipefs --all' 'installer wipes disk only after Enter confirmation'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'sgdisk --clear' 'installer creates GPT'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'new=1:0:\+512MiB' 'installer creates 512 MiB ESP'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'typecode=2:ef02' 'installer creates BIOS boot partition'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'bsdtar --numeric-owner' 'installer extracts offline target archive'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'bootctl install --no-variables' 'installer installs systemd-boot for UEFI'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'grub-install --target=i386-pc' 'installer installs GRUB for BIOS'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'Remove the flash drive' 'completion screen instructs flash-drive removal'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" '/var/log/kiosk-installer.log' 'failure screen has log path'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'mkfs.fat -F 32 -n KIOSK' 'installer uses a valid FAT volume label'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'Support code:' 'console error includes support code'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'Recent installer log' 'console error includes useful logs'
contains "$LIVE_ROOT/usr/local/bin/kiosk-installer-ui.sh" 'Press R to retry sending error logs' 'installer can retry remote error-log delivery'

if (cd "$BUNDLE_DIR" && sha512sum -c "$(basename "$CHECKSUM")") >/dev/null 2>&1; then
  ok 'target archive checksum matches'
else
  fail 'target archive checksum matches'
fi
mkdir -p "$TARGET_ROOT"
bsdtar --numeric-owner --xattrs --acls -xpf "$BUNDLE" -C "$TARGET_ROOT"

printf '\n== Installed target root ==\n'
exists "$TARGET_ROOT/opt/electron-app/.kiosk-app-manifest" 'Electron app bundled in target'
APP_IMAGE="$TARGET_ROOT/opt/electron-app/app.AppImage"
if [ -x "$APP_IMAGE" ]; then
  ok 'stable AppImage is executable'
else
  fail 'stable AppImage is executable'
fi
mkdir -p "$APP_AUDIT"
if (cd "$APP_AUDIT" && "$APP_IMAGE" --appimage-extract >/dev/null 2>&1) && \
   [ -x "$APP_AUDIT/squashfs-root/AppRun" ]; then
  ok 'AppImage extracts without FUSE and contains AppRun'
else
  fail 'AppImage extracts without FUSE and contains AppRun'
fi
app_asar=$(find "$APP_AUDIT/squashfs-root" -type f -path '*/resources/app.asar' -print -quit)
if [ -n "$app_asar" ] && [ -f "$app_asar" ]; then
  ok 'Electron app.asar preserved'
else
  fail 'Electron app.asar preserved'
fi
locale_dir=$(find "$APP_AUDIT/squashfs-root" -type d -name locales -print -quit)
if [ -d "$locale_dir" ] && [ "$(find "$locale_dir" -maxdepth 1 -name '*.pak' | wc -l)" -gt 0 ]; then
  ok 'Electron locale files preserved'
else
  fail 'Electron locale files preserved'
fi
exists "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'installed kiosk service'
exists "$TARGET_ROOT/etc/systemd/system/kiosk-failure.service" 'installed kiosk failure diagnostics service'
exists "$TARGET_ROOT/etc/systemd/system/kiosk-refresh.timer" 'installed randomized update-check timer'
exists "$TARGET_ROOT/etc/systemd/system/multi-user.target.wants/kiosk.service" 'installed kiosk service enabled'
exists "$TARGET_ROOT/etc/systemd/system/multi-user.target.wants/kiosk-failure.service" 'installed kiosk failure service enabled'
exists "$TARGET_ROOT/etc/systemd/system/timers.target.wants/kiosk-refresh.timer" 'randomized update-check timer enabled'
exists "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'installed Electron launcher'
exists "$TARGET_ROOT/usr/local/bin/kiosk-show-failure.sh" 'installed kiosk failure diagnostics script'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'User=appuser' 'kiosk uses its dedicated application user'
exists "$TARGET_ROOT/etc/passwd" 'target has /etc/passwd'
contains "$TARGET_ROOT/etc/passwd" 'appuser' 'appuser account exists in target passwd'
exists "$TARGET_ROOT/usr/lib/sysusers.d/appuser.conf" 'appuser sysusers config installed'
contains "$TARGET_ROOT/usr/lib/sysusers.d/appuser.conf" '^m appuser video' 'appuser in video group via m line'
contains "$TARGET_ROOT/usr/lib/sysusers.d/appuser.conf" '^m appuser input' 'appuser in input group via m line'
contains "$TARGET_ROOT/usr/lib/sysusers.d/appuser.conf" '^m appuser render' 'appuser in render group via m line'
contains /custom/build-inside.sh 'grep -q.*appuser.*passwd' 'build verifies appuser creation after sysusers'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'OnFailure=kiosk-failure.service' 'kiosk triggers failure diagnostics on crash'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'RuntimeDirectory=kiosk' 'kiosk has runtime directory for state'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'Restart=always' 'kiosk restarts cleanly after updater installation'
contains "$TARGET_ROOT/etc/systemd/system/kiosk-refresh.timer" 'RandomizedDelaySec=4h' 'fleet update checks are randomized'
contains "$TARGET_ROOT/etc/systemd/system/kiosk-failure.service" 'kiosk-show-failure.sh' 'failure service runs diagnostics script'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'ExecStart=/usr/bin/startx /usr/local/bin/launch-electron.sh' 'kiosk launches Electron directly without an xinitrc hop'
contains "$TARGET_ROOT/etc/systemd/system/kiosk.service" 'PAMName=login' 'kiosk uses PAM login for user session bus'
contains "$TARGET_ROOT/etc/kiosk.env" 'INSTALL_UI=tty-bash' 'target metadata records the console installer'
exists "$TARGET_ROOT/usr/bin/grub-install" 'installed BIOS bootloader runtime'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'gpu-attempted' 'GPU launch has software fallback after a failure'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'disable-gpu' 'software-safe Electron flags available'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'export APPIMAGE=' 'launcher enables the AppImage updater'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64' 'launcher reads updater cache configuration'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'FIXED_RESOLUTION=1024x768' 'kiosk resolution is fixed at 1024x768'
contains "$TARGET_ROOT/usr/local/bin/launch-electron.sh" 'window-size=1024,768' 'Electron window is forced to 1024x768'
contains "$TARGET_ROOT/etc/X11/xorg.conf.d/60-kiosk-display.conf" 'Modes "1024x768"' 'kiosk Xorg mode is fixed at 1024x768'
contains "$TARGET_ROOT/etc/systemd/network/20-wired-dhcp.network" 'DHCP=yes' 'wired DHCP configuration'
exists "$TARGET_ROOT/usr/lib/systemd/systemd-networkd" 'systemd-networkd runtime'
exists "$TARGET_ROOT/usr/lib/systemd/systemd-resolved" 'systemd-resolved runtime'
exists "$TARGET_ROOT/usr/bin/bootctl" 'systemd-boot installation runtime'
masked "$TARGET_ROOT/etc/systemd/system/getty@tty1.service" 'target getty is masked (no login prompt)'
masked "$TARGET_ROOT/etc/systemd/system/sshd.service" 'target SSH is masked'

printf '\n== Target exclusions ==\n'
for forbidden in \
  "$TARGET_ROOT/usr/bin/zenity:installer Zenity" \
  "$TARGET_ROOT/usr/bin/plymouth:installer Plymouth" \
  "$TARGET_ROOT/usr/bin/sgdisk:installer partitioner" \
  "$TARGET_ROOT/usr/bin/pacman:pacman runtime" \
  "$TARGET_ROOT/var/lib/pacman:pacman database" \
  "$TARGET_ROOT/usr/bin/sshd:SSH server" \
  "$TARGET_ROOT/usr/bin/x11vnc:VNC server" \
  "$TARGET_ROOT/usr/bin/wpa_supplicant:Wi-Fi tooling" \
  "$TARGET_ROOT/usr/bin/gnome-session:GNOME desktop" \
  "$TARGET_ROOT/usr/bin/startplasma-x11:Plasma desktop" \
  "$TARGET_ROOT/usr/bin/xfce4-session:XFCE desktop" \
  "$TARGET_ROOT/usr/share/doc:documentation tree" \
  "$TARGET_ROOT/usr/share/man:manual-page tree"; do
  path=${forbidden%%:*}
  label=${forbidden#*:}
  absent "$path" "no $label"
done

printf '\n== Build metrics ==\n'
exists "$BUNDLE_DIR/target-build-metrics.txt" 'target size/package metrics'
[ -f "$BUNDLE_DIR/target-build-metrics.txt" ] && cat "$BUNDLE_DIR/target-build-metrics.txt"
printf 'ISO size: %s\n' "$(du -h "$ISO_FILE" | cut -f1)"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' 'Failed checks:' >&2
  printf '  - %s\n' "${ERRORS[@]}" >&2
  exit 1
fi
