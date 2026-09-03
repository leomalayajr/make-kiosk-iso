#!/usr/bin/env bash
# Build an Arch ISO with two independent images:
#   1. a temporary console installer live root, and
#   2. a compressed, offline target root copied to the selected disk.
#
# The build context is supplied by make-kiosk-iso.sh and is intentionally
# mounted separately so application credentials never become source assets.
set -Eeuo pipefail

PROFILE_SRC=/usr/share/archiso/configs/releng
PROFILE_DST=/tmp/profile
TARGET_ROOT=/tmp/kiosk-target-root
WORK_DIR=/tmp/work
OUT_DIR=/out
CUSTOM_DIR=/custom
BUILD_CONTEXT=/build-context
BUNDLE_NAME=target-root.tar.zst

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_context() {
  [ -x "$BUILD_CONTEXT/app/app.AppImage" ] || die 'build context has no staged AppImage'
  [ -f "$BUILD_CONTEXT/kiosk.env" ] || die 'build context has no environment file'
  [ -f "$BUILD_CONTEXT/installer-logging.env" ] || die 'build context has no installer logging environment file'
  [ -n "${OUTPUT_FILE_PREFIX:-}" ] || die 'build context has no output file prefix'
}

read_packages() {
  local package_file=$1
  mapfile -t PACKAGES < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$package_file")
  ((${#PACKAGES[@]})) || die "no packages in $package_file"
}

set_live_boot_options() {
  # Boot directly into the installer. Keep UEFI, BIOS, and GRUB fallbacks
  # aligned so the experience is identical regardless of firmware.
  sed -i 's/^UI vesamenu.c32/PROMPT 0/' "$PROFILE_DST/syslinux/archiso_head.cfg"
  sed -i 's/^TIMEOUT 150/TIMEOUT 1/' "$PROFILE_DST/syslinux/archiso_sys.cfg"
  sed -i 's/Arch Linux install medium/Offline Kiosk Installer/g' \
    "$PROFILE_DST"/syslinux/*.cfg
  sed -i '/^APPEND / s/$/ video=1024x768/' "$PROFILE_DST"/syslinux/*.cfg

  sed -i 's/^timeout 15/timeout 0/' "$PROFILE_DST/efiboot/loader/loader.conf"
  sed -i 's/Arch Linux install medium/Offline Kiosk Installer/g' \
    "$PROFILE_DST"/efiboot/loader/entries/*.conf
  sed -i '/^options / s/$/ video=1024x768/' "$PROFILE_DST"/efiboot/loader/entries/*.conf

  local grub_file
  for grub_file in "$PROFILE_DST/grub/grub.cfg" "$PROFILE_DST/grub/loopback.cfg"; do
    [ -f "$grub_file" ] || continue
    sed -i 's/^timeout=15/timeout=0/; s/^timeout_style=menu/timeout_style=countdown/' "$grub_file"
    sed -i '/^play 600/d; s/Arch Linux install medium/Offline Kiosk Installer/g' "$grub_file"
    sed -i '/^[[:space:]]*linux / s/$/ video=1024x768/' "$grub_file"
  done
}

prepare_target_root() {
  local package_count target_size largest_files app_entrypoint
  printf '[1/6] Creating minimal offline target root...\n'
  rm -rf "$TARGET_ROOT"
  mkdir -p "$TARGET_ROOT"
  read_packages "$CUSTOM_DIR/target-packages.txt"
  pacstrap -K -c -G -M "$TARGET_ROOT" "${PACKAGES[@]}"

  # Install only target runtime assets. The app is copied from the ephemeral
  # build context, never from the installer live root.
  cp -a "$CUSTOM_DIR/target-rootfs/." "$TARGET_ROOT/"
  mkdir -p "$TARGET_ROOT/opt/electron-app"
  install -m 0755 "$BUILD_CONTEXT/app/app.AppImage" \
    "$TARGET_ROOT/opt/electron-app/app.AppImage"
  install -D -m 0600 "$BUILD_CONTEXT/kiosk.env" \
    "$TARGET_ROOT/etc/kiosk.env"
  printf '%s-%s-x86_64.iso\n' "$OUTPUT_FILE_PREFIX" \
    "${ISO_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}" >"$TARGET_ROOT/etc/kiosk-version"
  # gnome-keyring uses locked memory for secret material.  Without this
  # narrowly-scoped file capability libcap-ng aborts the daemon before
  # Electron can initialize safeStorage ("Encryption not available").
  command -v setcap >/dev/null 2>&1 || die 'setcap is required to configure gnome-keyring'
  setcap cap_ipc_lock=+ep "$TARGET_ROOT/usr/bin/gnome-keyring-daemon"
  getcap "$TARGET_ROOT/usr/bin/gnome-keyring-daemon" | grep -q 'cap_ipc_lock=ep' \
    || die 'failed to grant CAP_IPC_LOCK to gnome-keyring-daemon'
  app_entrypoint="$TARGET_ROOT/opt/electron-app/app.AppImage"
  [ -x "$app_entrypoint" ] || die 'installed AppImage is not executable'
  printf 'Electron application entrypoint: %s\n' "$app_entrypoint"
  printf 'Offline Kiosk app bundle\n' >"$TARGET_ROOT/opt/electron-app/.kiosk-app-manifest"

  # The kiosk runs under its dedicated account. Creating it during the build
  # and owning the copied bundle with it avoids permission failures at launch.
  systemd-sysusers --root="$TARGET_ROOT"
  grep -q '^appuser:' "$TARGET_ROOT/etc/passwd" \
    || die 'systemd-sysusers did not create appuser — check usr/lib/sysusers.d/appuser.conf'
  mkdir -p "$TARGET_ROOT/home/appuser/.cache"
  chown -R 1000:1000 "$TARGET_ROOT/home/appuser" "$TARGET_ROOT/opt/electron-app"
  chmod 0755 "$TARGET_ROOT/usr/local/bin/launch-electron.sh" \
    "$TARGET_ROOT/usr/local/bin/kiosk-show-failure.sh"
  chmod 0600 "$TARGET_ROOT/etc/kiosk.env"

  systemctl --root="$TARGET_ROOT" enable kiosk.service kiosk-failure.service \
    kiosk-refresh.timer \
    systemd-networkd.service systemd-resolved.service
  for tty in 1 2 3 4 5 6; do
    ln -sfn /dev/null "$TARGET_ROOT/etc/systemd/system/getty@tty${tty}.service"
  done
  ln -sfn /dev/null "$TARGET_ROOT/etc/systemd/system/serial-getty@.service"
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$TARGET_ROOT/etc/resolv.conf"
  ln -sfn ../getty@.service "$TARGET_ROOT/etc/systemd/system/multi-user.target.wants/getty@tty1.service"
  ln -sfn /dev/null "$TARGET_ROOT/etc/systemd/system/sshd.service"

  # The target is an appliance, not a package-managed workstation. Remove
  # caches, documentation, and the pacman database/binaries after dependency
  # resolution has completed at build time.
  package_count=$(find "$TARGET_ROOT/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  rm -rf "$TARGET_ROOT/var/cache/pacman" "$TARGET_ROOT/var/lib/pacman" \
    "$TARGET_ROOT/usr/share/doc" "$TARGET_ROOT/usr/share/man" \
    "$TARGET_ROOT/usr/share/info" "$TARGET_ROOT/usr/share/gtk-doc"
  rm -f "$TARGET_ROOT/usr/bin/pacman" "$TARGET_ROOT/usr/bin/pacman-key" \
    "$TARGET_ROOT/usr/bin/makepkg" "$TARGET_ROOT/usr/bin/repo-add" \
    "$TARGET_ROOT/usr/bin/repo-remove" \
    "$TARGET_ROOT/usr/bin/sshd"
  rm -rf "$TARGET_ROOT/etc/pacman.conf" "$TARGET_ROOT/etc/pacman.d"
  find "$TARGET_ROOT/usr" -type f \( -name '*.a' -o -name '*.la' \) -delete

  target_size=$(du -sh "$TARGET_ROOT" | cut -f1)
  largest_files=$(find "$TARGET_ROOT" -type f -printf '%s %p\n' | sort -nr | sed -n '1,10p')
  tar --zstd --xattrs --xattrs-include='security.capability' --acl \
    --numeric-owner -cpf "$BUNDLE_PATH" -C "$TARGET_ROOT" .
  # Write a relocatable manifest: the installer verifies it after the archive
  # is copied to /opt/kiosk-installer rather than at this temporary path.
  (cd "$bundle_dir" && sha512sum "$BUNDLE_NAME" >"${BUNDLE_NAME}.sha512")
  {
    printf 'target root size: %s\n' "$target_size"
    printf 'target package count before appliance pruning: %s\n' "$package_count"
    printf 'largest target files (bytes path):\n%s\n' "$largest_files"
  } >"$METRICS_PATH"
}

prepare_installer_profile() {
  printf '[2/6] Creating console installer live root...\n'
  rm -rf "$PROFILE_DST"
  cp -a "$PROFILE_SRC" "$PROFILE_DST"
  read_packages "$CUSTOM_DIR/installer-packages.txt"
  printf '%s\n' "${PACKAGES[@]}" >"$PROFILE_DST/packages.x86_64"
  set_live_boot_options

  # Releng's installation helpers would provide an escape hatch from the
  # appliance flow, so remove them before adding the dedicated installer.
  rm -rf "$PROFILE_DST/airootfs/root"
  rm -f "$PROFILE_DST/airootfs/usr/local/bin/Installation_guide" \
    "$PROFILE_DST/airootfs/usr/local/bin/choose-mirror" \
    "$PROFILE_DST/airootfs/usr/local/bin/livecd-sound" \
    "$PROFILE_DST/airootfs/etc/systemd/system/livecd-talk.service" \
    "$PROFILE_DST/airootfs/etc/systemd/system/livecd-alsa-unmuter.service" \
    "$PROFILE_DST/airootfs/etc/systemd/system/choose-mirror.service"
  # The stock profile lists permissions for the files above. Remove those
  # entries as well; mkarchiso rejects permission mappings outside airootfs.
  sed -i \
    -e '\|^  \["/root"\]=|d' \
    -e '\|^  \["/root/\.automated_script\.sh"\]=|d' \
    -e '\|^  \["/root/\.gnupg"\]=|d' \
    -e '\|^  \["/usr/local/bin/choose-mirror"\]=|d' \
    -e '\|^  \["/usr/local/bin/Installation_guide"\]=|d' \
    -e '\|^  \["/usr/local/bin/livecd-sound"\]=|d' \
    "$PROFILE_DST/profiledef.sh"

  cp -a "$CUSTOM_DIR/installer-rootfs/." "$PROFILE_DST/airootfs/"
  # mkarchiso writes its clock epoch marker under this overlay path before the
  # package root has been populated, so create it even though our own overlay
  # has no static files directly in /usr/lib.
  mkdir -p "$PROFILE_DST/airootfs/usr/lib"
  mkdir -p "$PROFILE_DST/airootfs/opt/kiosk-installer"
  cp "$BUNDLE_PATH" "${BUNDLE_PATH}.sha512" "$METRICS_PATH" \
    "$PROFILE_DST/airootfs/opt/kiosk-installer/"
  install -D -m 0600 "$BUILD_CONTEXT/installer-logging.env" \
    "$PROFILE_DST/airootfs/etc/kiosk-installer-logging.env"
  printf '%s-%s-x86_64.iso\n' "$OUTPUT_FILE_PREFIX" \
    "${ISO_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}" >"$PROFILE_DST/airootfs/etc/kiosk-version"
  chmod 0755 "$PROFILE_DST/airootfs/usr/local/bin/kiosk-installer-ui.sh"
  chmod 0644 "$PROFILE_DST/airootfs/etc/systemd/system/kiosk-installer.service"

  local systemd_dir=$PROFILE_DST/airootfs/etc/systemd/system tty
  mkdir -p "$systemd_dir/multi-user.target.wants"
  ln -sfn ../kiosk-installer.service "$systemd_dir/multi-user.target.wants/kiosk-installer.service"
  for tty in 1 2 3 4 5 6; do
    ln -sfn /dev/null "$systemd_dir/getty@tty${tty}.service"
  done
  ln -sfn /dev/null "$systemd_dir/serial-getty@.service"
  ln -sfn /dev/null "$systemd_dir/sshd.service"
  rm -rf "$systemd_dir/getty@tty1.service.d"

  # This ISO boots from local media only. Remove ArchISO's optional PXE hooks:
  # their helper binaries are intentionally not included in this small live
  # image, and leaving the hooks enabled makes mkinitcpio report false errors.
  local mkinit=$PROFILE_DST/airootfs/etc/mkinitcpio.conf.d/archiso.conf
  if [ -f "$mkinit" ]; then
    sed -i 's/ archiso_pxe_common//g; s/ archiso_pxe_nbd//g; s/ archiso_pxe_http//g; s/ archiso_pxe_nfs//g' "$mkinit"
  fi

  sed -i "s/^iso_name=.*/iso_name=\"${OUTPUT_FILE_PREFIX}-${ISO_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}\"/" "$PROFILE_DST/profiledef.sh"
  sed -i 's/^iso_publisher=.*/iso_publisher="Offline Kiosk"/' "$PROFILE_DST/profiledef.sh"
  sed -i 's/^iso_application=.*/iso_application="Offline Kiosk Offline Installer"/' "$PROFILE_DST/profiledef.sh"
  cat >>"$PROFILE_DST/profiledef.sh" <<'EOF_PERMS'
file_permissions["/usr/local/bin/kiosk-installer-ui.sh"]="0:0:755"
file_permissions["/etc/systemd/system/kiosk-installer.service"]="0:0:644"
file_permissions["/etc/kiosk-installer-logging.env"]="0:0:600"
file_permissions["/opt/kiosk-installer/target-root.tar.zst"]="0:0:644"
file_permissions["/opt/kiosk-installer/target-root.tar.zst.sha512"]="0:0:644"
EOF_PERMS
}

main() {
  require_context
  mkdir -p "$WORK_DIR" "$OUT_DIR"
  # Wipe the work directory inside the container (as root) so stale mkarchiso
  # marker files from a prior failed run do not cause _run_once to skip critical
  # steps (e.g. squashfs creation) on retry.  Doing this here rather than in
  # make-kiosk-iso.sh avoids permission-denied errors on Docker-mounted paths.
  find "$WORK_DIR" -mindepth 1 -delete 2>/dev/null || true

  local bundle_dir
  bundle_dir=$(mktemp -d /tmp/kiosk-bundle.XXXXXX)
  trap 'rm -rf "${bundle_dir:-}"' EXIT
  BUNDLE_PATH="$bundle_dir/$BUNDLE_NAME"
  METRICS_PATH="$bundle_dir/target-build-metrics.txt"

  prepare_target_root
  prepare_installer_profile
  printf '[3/6] Building installer ISO with mkarchiso...\n'
  mkarchiso -v -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DST"

  local iso_file
  iso_file=$(find "$OUT_DIR" -maxdepth 1 -type f \
    -name "${OUTPUT_FILE_PREFIX}-${ISO_TIMESTAMP}-*.iso" -print -quit)
  [ -n "$iso_file" ] || die 'mkarchiso did not create an installer ISO'
  printf '[4/6] Build metrics\n'
  printf 'ISO size: %s\n' "$(du -h "$iso_file" | cut -f1)"
  cat "$METRICS_PATH"
  printf '[5/6] Offline bundle: %s\n' "$(du -h "$BUNDLE_PATH" | cut -f1)"
  printf '[6/6] ISO ready: %s\n' "$iso_file"
}

main "$@"
