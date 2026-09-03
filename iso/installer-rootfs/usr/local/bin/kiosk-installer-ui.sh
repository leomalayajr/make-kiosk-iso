#!/usr/bin/env bash
# The installer deliberately has one destructive action. It is a console-only
# program: no display server, window manager, or graphical toolkit is started
# from the ISO. It extracts the already-built target archive and never invokes
# pacman or downloads packages while installing.
set -Eeuo pipefail

INSTALLER_DIR=/opt/kiosk-installer
ARCHIVE="$INSTALLER_DIR/target-root.tar.zst"
CHECKSUM_FILE="$INSTALLER_DIR/target-root.tar.zst.sha512"
LOG_FILE=/var/log/kiosk-installer.log
REMOTE_LOG_CONFIG=/etc/kiosk-installer-logging.env
MOUNT_ROOT=/mnt/kiosk-target
STAGE_FILE=''
export LANG=C.UTF-8

KIOSK_VERSION=$(cat /etc/kiosk-version 2>/dev/null || echo 'unknown')

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG_FILE"
}

log "Installer started — version: $KIOSK_VERSION"

# Remote delivery is intentionally best-effort for an installation-start event
# and after an installation error. The offline installer never requires
# networking and always remains usable if neither the internet nor a
# logger-server is available.
LOGGER_SERVER_URL=''
NEW_RELIC_LOG_ENABLED=false
NEW_RELIC_LICENSE_KEY=''
NEW_RELIC_LOG_ENDPOINT=''
NEW_RELIC_ENVIRONMENT=''
NEW_RELIC_SERVICE_NAME='kiosk-production'
NEW_RELIC_LAST_ERROR=''

decode_remote_log_value() {
  local encoded=$1
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 -d 2>/dev/null
}

installer_config_value() {
  local key=$1
  [ -r "$REMOTE_LOG_CONFIG" ] || return 0
  sed -n "s/^${key}=//p" "$REMOTE_LOG_CONFIG" | head -n 1
}

is_new_relic_log_endpoint() {
  case $1 in
    https://log-api.newrelic.com/log/v1|\
    https://log-api.eu.newrelic.com/log/v1|\
    https://log-api.jp.nr-data.net/log/v1|\
    https://gov-log-api.newrelic.com/log/v1) return 0 ;;
    *) return 1 ;;
  esac
}

load_remote_logging() {
  local value
  value=$(installer_config_value KIOSK_LOGGER_SERVER_B64 || true)
  if [ -n "$value" ]; then
    LOGGER_SERVER_URL=$(decode_remote_log_value "$value" || true)
    LOGGER_SERVER_URL="${LOGGER_SERVER_URL%/}/log"
  fi

  value=$(installer_config_value KIOSK_NEW_RELIC_LOG_ENABLED || true)
  [ "$value" = true ] || return 0
  NEW_RELIC_LOG_ENABLED=true

  value=$(installer_config_value KIOSK_NEW_RELIC_LICENSE_KEY_B64 || true)
  [ -n "$value" ] || return 0
  NEW_RELIC_LICENSE_KEY=$(decode_remote_log_value "$value" || true)
  NEW_RELIC_LOG_ENDPOINT=$(decode_remote_log_value "$(installer_config_value KIOSK_NEW_RELIC_LOG_ENDPOINT_B64 || true)" || true)
  NEW_RELIC_ENVIRONMENT=$(decode_remote_log_value "$(installer_config_value KIOSK_NEW_RELIC_ENVIRONMENT_B64 || true)" || true)
  NEW_RELIC_SERVICE_NAME=$(decode_remote_log_value "$(installer_config_value KIOSK_NEW_RELIC_SERVICE_NAME_B64 || true)" || true)
  NEW_RELIC_SERVICE_NAME="${NEW_RELIC_SERVICE_NAME:-kiosk-production}"
  if [ -z "$NEW_RELIC_LICENSE_KEY" ] || [ -z "$NEW_RELIC_LOG_ENDPOINT" ] || [ -z "$NEW_RELIC_ENVIRONMENT" ] || [ -z "$NEW_RELIC_SERVICE_NAME" ] || ! is_new_relic_log_endpoint "$NEW_RELIC_LOG_ENDPOINT"; then
    log 'Remote error logging disabled: invalid New Relic configuration'
    NEW_RELIC_LICENSE_KEY=''
    NEW_RELIC_LOG_ENDPOINT=''
    NEW_RELIC_ENVIRONMENT=''
    NEW_RELIC_SERVICE_NAME='kiosk-production'
  fi
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=$(printf '%s' "$value" | tr -d '\000-\010\013\014\016-\037\177')
  printf '%s' "$value"
}

installer_error_payload() {
  local stage=$1 code=$2 details=$3 timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  details=${details:0:4000}
  printf '{"timestamp":"%s","level":"ERROR","message":"Installation failed: %s during %s","logtype":"kiosk-installer","service.name":"%s","service.namespace":"kiosk","deployment.environment.name":"%s","newrelic.source":"kiosk.installer","installerStage":"%s","supportCode":"%s","diagnosticExcerpt":"%s","version":"%s"}' \
    "$(json_escape "$timestamp")" "$(json_escape "$code")" "$(json_escape "$stage")" \
    "$(json_escape "$NEW_RELIC_SERVICE_NAME")" "$(json_escape "$NEW_RELIC_ENVIRONMENT")" "$(json_escape "$stage")" \
    "$(json_escape "$code")" "$(json_escape "$details")" "$(json_escape "$KIOSK_VERSION")"
}

# This is deliberately limited to operational hardware characteristics useful
# for installation support. Do not add DMI serials, MAC addresses, fingerprints,
# credentials, or partition contents to this event.
installer_started_payload() {
  local disk=$1 timestamp firmware cpu_model cpu_cores memory_mib disk_model disk_size disk_transport
  local unavailable_specs='' specs_status='complete' message
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  firmware=bios
  [ -d /sys/firmware/efi ] && firmware=uefi
  cpu_model=$(awk -F: '/model name/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  if [ -z "$cpu_model" ]; then
    cpu_model=unknown
    unavailable_specs='cpuModel'
  fi
  cpu_cores=$(nproc 2>/dev/null || echo unknown)
  if ! [[ $cpu_cores =~ ^[1-9][0-9]*$ ]]; then
    cpu_cores=unknown
    unavailable_specs="${unavailable_specs:+$unavailable_specs,}cpuLogicalCores"
  fi
  memory_mib=$(awk '/MemTotal/{printf "%d", $2 / 1024; exit}' /proc/meminfo 2>/dev/null || true)
  if [ -z "$memory_mib" ] || [ "$memory_mib" = 0 ]; then
    memory_mib=unknown
    unavailable_specs="${unavailable_specs:+$unavailable_specs,}memoryMiB"
  fi
  disk_model=$(lsblk -dn -o MODEL "$disk" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
  disk_size=$(lsblk -dn -o SIZE "$disk" 2>/dev/null || true)
  disk_transport=$(lsblk -dn -o TRAN "$disk" 2>/dev/null || true)
  if [ -z "$disk_model" ]; then
    disk_model=unknown
    unavailable_specs="${unavailable_specs:+$unavailable_specs,}targetDiskModel"
  fi
  if [ -z "$disk_size" ]; then
    disk_size=unknown
    unavailable_specs="${unavailable_specs:+$unavailable_specs,}targetDiskSize"
  fi
  if [ -z "$disk_transport" ]; then
    disk_transport=unknown
    unavailable_specs="${unavailable_specs:+$unavailable_specs,}targetDiskTransport"
  fi
  if [ -n "$unavailable_specs" ]; then
    specs_status=partial
    message="Offline Kiosk installation initiated — could not pull specs: $unavailable_specs"
  else
    message='Offline Kiosk installation initiated — specs collected'
  fi
  printf '{"timestamp":"%s","level":"INFO","message":"%s","logtype":"kiosk-installer","service.name":"%s","service.namespace":"kiosk","deployment.environment.name":"%s","newrelic.source":"kiosk.installer","installationEvent":"initiated","isoVersion":"%s","firmware":"%s","cpuModel":"%s","cpuLogicalCores":"%s","memoryMiB":"%s","targetDiskModel":"%s","targetDiskSize":"%s","targetDiskTransport":"%s","hardwareSpecsStatus":"%s","unavailableSpecs":"%s"}' \
    "$(json_escape "$timestamp")" "$(json_escape "$message")" "$(json_escape "$NEW_RELIC_SERVICE_NAME")" "$(json_escape "$NEW_RELIC_ENVIRONMENT")" \
    "$(json_escape "$KIOSK_VERSION")" "$(json_escape "$firmware")" \
    "$(json_escape "$cpu_model")" "$(json_escape "$cpu_cores")" \
    "$(json_escape "$memory_mib")" "$(json_escape "$disk_model")" \
    "$(json_escape "$disk_size")" "$(json_escape "$disk_transport")" \
    "$(json_escape "$specs_status")" "$(json_escape "$unavailable_specs")"
}

# Return 0 on a successful 2xx response, 2 for a likely connectivity failure,
# and 1 for any other rejected or failed delivery. The key never appears in a
# command-line argument.
send_new_relic_install_error() {
  local stage=$1 code=$2 details=$3 payload response='' curl_status=0
  [ -n "$NEW_RELIC_LICENSE_KEY" ] || return 3
  NEW_RELIC_LAST_ERROR=''
  payload=$(installer_error_payload "$stage" "$code" "$details")
  if response=$(printf 'Api-Key: %s\n' "$NEW_RELIC_LICENSE_KEY" | curl -sS --connect-timeout 2 --max-time 5 \
    -X POST -H 'Content-Type: application/json' -H @- --data-binary "$payload" \
    -o /dev/null -w '%{http_code}' "$NEW_RELIC_LOG_ENDPOINT" 2>>"$LOG_FILE"); then
    [[ $response =~ ^2[0-9][0-9]$ ]] && return 0
    NEW_RELIC_LAST_ERROR="New Relic returned HTTP ${response:-no-status}"
  else
    curl_status=$?
    NEW_RELIC_LAST_ERROR="New Relic delivery failed (curl exit $curl_status)"
  fi
  case $curl_status in
    5|6|7|28) return 2 ;;
    *) return 1 ;;
  esac
}

send_logger_server_install_error() {
  local stage=$1 code=$2 details=$3 payload response='' curl_status=0
  [ -n "$LOGGER_SERVER_URL" ] || return 3
  payload=$(installer_error_payload "$stage" "$code" "$details")
  if response=$(curl -sS --connect-timeout 2 --max-time 5 -X POST \
    -H 'Content-Type: application/json' --data-binary "$payload" \
    -o /dev/null -w '%{http_code}' "$LOGGER_SERVER_URL" 2>>"$LOG_FILE"); then
    [[ $response =~ ^2[0-9][0-9]$ ]] && return 0
  else
    curl_status=$?
  fi
  case $curl_status in
    5|6|7|28) return 2 ;;
    *) return 1 ;;
  esac
}

send_new_relic_install_started() {
  local disk=$1 payload response='' curl_status=0
  [ -n "$NEW_RELIC_LICENSE_KEY" ] || return 3
  NEW_RELIC_LAST_ERROR=''
  payload=$(installer_started_payload "$disk")
  if response=$(printf 'Api-Key: %s\n' "$NEW_RELIC_LICENSE_KEY" | curl -sS --connect-timeout 2 --max-time 5 \
    -X POST -H 'Content-Type: application/json' -H @- --data-binary "$payload" \
    -o /dev/null -w '%{http_code}' "$NEW_RELIC_LOG_ENDPOINT" 2>>"$LOG_FILE"); then
    [[ $response =~ ^2[0-9][0-9]$ ]] && return 0
    NEW_RELIC_LAST_ERROR="New Relic returned HTTP ${response:-no-status}"
  else
    curl_status=$?
    NEW_RELIC_LAST_ERROR="New Relic delivery failed (curl exit $curl_status)"
  fi
  case $curl_status in
    5|6|7|28) return 2 ;;
    *) return 1 ;;
  esac
}

send_logger_server_install_started() {
  local disk=$1 payload response='' curl_status=0
  [ -n "$LOGGER_SERVER_URL" ] || return 3
  payload=$(installer_started_payload "$disk")
  if response=$(curl -sS --connect-timeout 2 --max-time 5 -X POST \
    -H 'Content-Type: application/json' --data-binary "$payload" \
    -o /dev/null -w '%{http_code}' "$LOGGER_SERVER_URL" 2>>"$LOG_FILE"); then
    [[ $response =~ ^2[0-9][0-9]$ ]] && return 0
  else
    curl_status=$?
  fi
  case $curl_status in
    5|6|7|28) return 2 ;;
    *) return 1 ;;
  esac
}

# Both remote sinks remain optional. New Relic is always attempted first and a
# logger-server failure cannot prevent the installation from beginning.
send_install_started_logs() {
  local disk=$1 status
  if send_new_relic_install_started "$disk"; then
    log 'Installation initiated log delivered to New Relic'
  else
    status=$?
    [ "$status" -eq 3 ] || log "Installation initiated log was not delivered to New Relic (status $status)"
    if [ "$status" -ne 3 ] && [ -n "$LOGGER_SERVER_URL" ]; then
      send_logger_server_install_error 'new-relic-log-delivery' 'NEW_RELIC_DELIVERY_FAILED' "$NEW_RELIC_LAST_ERROR" || true
    fi
  fi
  if send_logger_server_install_started "$disk"; then
    log 'Installation initiated log delivered to logger-server'
  else
    status=$?
    [ "$status" -eq 3 ] || log "Installation initiated log was not delivered to logger-server (status $status)"
  fi
}

# New Relic is attempted first, with logger-server retained as an optional
# secondary sink. Return 3 when remote logging was not configured.
send_install_error_logs() {
  local stage=$1 code=$2 details=$3 status attempted=0 delivered=0 network_failures=0
  if [ -n "$NEW_RELIC_LICENSE_KEY" ]; then
    attempted=$((attempted + 1))
    if send_new_relic_install_error "$stage" "$code" "$details"; then
      status=0
    else
      status=$?
    fi
    [ "$status" -eq 0 ] && delivered=1
    [ "$status" -eq 2 ] && network_failures=$((network_failures + 1))
    if [ "$status" -ne 0 ] && [ -n "$LOGGER_SERVER_URL" ]; then
      send_logger_server_install_error 'new-relic-log-delivery' 'NEW_RELIC_DELIVERY_FAILED' "$NEW_RELIC_LAST_ERROR" || true
    fi
  fi
  if [ -n "$LOGGER_SERVER_URL" ]; then
    attempted=$((attempted + 1))
    if send_logger_server_install_error "$stage" "$code" "$details"; then
      status=0
    else
      status=$?
    fi
    [ "$status" -eq 0 ] && delivered=1
    [ "$status" -eq 2 ] && network_failures=$((network_failures + 1))
  fi
  [ "$delivered" -eq 1 ] && return 0
  [ "$attempted" -eq 0 ] && return 3
  [ "$network_failures" -eq "$attempted" ] && return 2
  return 1
}

retry_install_error_logs() {
  local stage=$1 code=$2 details=$3 status choice
  while true; do
    if send_install_error_logs "$stage" "$code" "$details"; then
      status=0
    else
      status=$?
    fi
    case $status in
      0)
        log 'Installation error logs delivered to a remote sink'
        printf '\n%s\n' 'Installation error logs were sent successfully.'
        return 0
        ;;
      3)
        return 0
        ;;
      2)
        log 'Attempt to send installation error logs failed: no internet or reachable logging endpoint'
        printf '\n%s\n' 'Attempt to send error logs failed because there is no internet connection.'
        printf '%s\n' 'Please connect to the internet, then press R to retry sending the logs.'
        ;;
      *)
        log 'Attempt to send installation error logs failed: logging endpoint rejected or could not process the request'
        printf '\n%s\n' 'Attempt to send error logs failed because the logging endpoint could not accept them.'
        printf '%s\n' 'Check the connection and logging configuration, then press R to retry.'
        ;;
    esac
    printf '%s' 'Press R to retry sending error logs, or Enter to restart: '
    read -r choice || true
    [[ $choice =~ ^[Rr]$ ]] || return 0
  done
}

load_remote_logging

progress() {
  local percent=$1
  shift
  [ -z "$STAGE_FILE" ] || printf '%s\n' "$*" >"$STAGE_FILE"
  printf '\n[%3s%%] %s\n' "$percent" "$*"
  log "[$percent%] $*"
}

clear_screen() {
  printf '\033[2J\033[H'
}

partition_path() {
  if [[ $1 =~ [0-9]$ ]]; then
    printf '%sp%s' "$1" "$2"
  else
    printf '%s%s' "$1" "$2"
  fi
}

installer_disk() {
  local source parent
  source=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [ -n "$source" ] || return 0
  source=$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")
  parent=$(lsblk -ndo PKNAME "$source" 2>/dev/null || true)
  if [ -n "$parent" ]; then
    printf '/dev/%s\n' "$parent"
  elif [ -b "$source" ]; then
    printf '%s\n' "$source"
  fi
}

target_disk() {
  local live name type removable readonly transport
  live=$(installer_disk || true)
  while read -r name type removable readonly transport; do
    [ "$type" = disk ] || continue
    [ "$removable" = 0 ] || continue
    [ "$readonly" = 0 ] || continue
    [ "/dev/$name" = "$live" ] && continue
    [ "$transport" = usb ] && continue
    printf '/dev/%s\n' "$name"
    return 0
  done < <(lsblk -dn -o NAME,TYPE,RM,RO,TRAN)
  return 1
}

disk_description() {
  lsblk -dn -o MODEL,SIZE "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

write_machine_identity() {
  local candidate='' source normalized identity_source='target machine-id'

  # These DMI attributes are deliberately root-only on Linux.  Select the
  # best real hardware identifier while the installer is privileged, then
  # expose only that value to the kiosk (never the rest of root-only sysfs).
  for source in \
    /sys/devices/virtual/dmi/id/board_serial \
    /sys/devices/virtual/dmi/id/product_uuid \
    /sys/devices/virtual/dmi/id/product_serial; do
    [ -r "$source" ] || continue
    candidate=$(tr -d '[:space:]' <"$source" 2>/dev/null || true)
    normalized=${candidate,,}
    case $normalized in
      ''|none|unknown|defaultstring|notspecified|tobefilledbyo.e.m.)
        candidate=''
        continue
        ;;
    esac
    identity_source=$source
    break
  done

  # Some VMs publish no usable DMI serial.  The freshly generated target
  # machine-id is stable for this installation and prevents a blank serial.
  if [ -z "$candidate" ]; then
    candidate=$(tr -d '[:space:]' <"$MOUNT_ROOT/etc/machine-id")
  fi
  [ -n "$candidate" ]

  printf '%s\n' "$candidate" >"$MOUNT_ROOT/etc/kiosk-board-serial"
  chmod 0444 "$MOUNT_ROOT/etc/kiosk-board-serial"
  log "Machine identity prepared from $identity_source"
}

show_start_screen() {
  local disk=$1 description line
  description=$(disk_description "$disk")
  clear_screen
  printf '%s\n' 'Offline Kiosk Offline Installer'
  printf 'Version: %s\n\n' "$KIOSK_VERSION"
  printf 'Target disk: %s — %s\n\n' "$disk" "$description"
  printf '%s\n' '╔══════════════════════════════════════════════════════════╗'
  printf '%s\n' '║          WARNING: Disk Will Be Erased                    ║'
  printf '%s\n' '╠══════════════════════════════════════════════════════════╣'
  for line in \
    '  Continuing with the installation will format the' \
    '  selected disk and permanently erase all data stored' \
    '  on it, including files, applications, and existing' \
    '  operating systems.' \
    '' \
    '  Please make sure you have backed up any important data' \
    '  before proceeding.' \
    '' \
    '  This action cannot be undone.'; do
    printf '║ %-56s ║\n' "$line"
  done
  printf '%s\n' '╚══════════════════════════════════════════════════════════╝'
  printf '\n%s' 'Do you want to continue? Press Enter to begin installation, or Ctrl+C to cancel: '
  read -r _
}

install_target() {
  local disk=$1 esp root root_uuid
  esp=$(partition_path "$disk" 1)
  root=$(partition_path "$disk" 3)

  cleanup_mounts() {
    umount -R "$MOUNT_ROOT" >/dev/null 2>&1 || true
  }
  trap cleanup_mounts RETURN

  progress 5 'Preparing target disk'
  test -r "$ARCHIVE"
  test -r "$CHECKSUM_FILE"
  (cd "$INSTALLER_DIR" && sha512sum -c "$(basename "$CHECKSUM_FILE")") >&2
  wipefs --all --force "$disk" >&2
  sgdisk --zap-all "$disk" >&2
  sgdisk --clear --new=1:0:+512MiB --typecode=1:ef00 --change-name=1:'KIOSK EFI' "$disk" >&2
  sgdisk --new=2:0:+2MiB --typecode=2:ef02 --change-name=2:'KIOSK BIOS BOOT' "$disk" >&2
  sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:'Offline Kiosk' "$disk" >&2
  partprobe "$disk" >&2
  udevadm settle >&2

  progress 20 'Formatting system partitions'
  mkfs.fat -F 32 -n KIOSK "$esp" >&2
  mkfs.ext4 -F -L kiosk-root "$root" >&2

  progress 38 'Copying Offline Kiosk'
  mkdir -p "$MOUNT_ROOT"
  mount "$root" "$MOUNT_ROOT"
  mkdir -p "$MOUNT_ROOT/boot"
  mount "$esp" "$MOUNT_ROOT/boot"
  bsdtar --numeric-owner --xattrs --acls -xpf "$ARCHIVE" -C "$MOUNT_ROOT" >&2

  progress 64 'Configuring boot and network'
  genfstab -U "$MOUNT_ROOT" >"$MOUNT_ROOT/etc/fstab"
  # Each installed appliance needs its own OS GUID.  The Electron fingerprint
  # helper reads this through /etc/machine-id.
  : >"$MOUNT_ROOT/etc/machine-id"
  systemd-machine-id-setup --root="$MOUNT_ROOT" >&2
  write_machine_identity
  root_uuid=$(blkid -s UUID -o value "$root")
  if [ -d /sys/firmware/efi ]; then
    # The fallback EFI path written by --no-variables avoids relying on an
    # NVRAM boot entry, which makes removable-media and VM installs reliable.
    arch-chroot "$MOUNT_ROOT" bootctl install --no-variables >&2
    mkdir -p "$MOUNT_ROOT/boot/loader/entries"
    cat >"$MOUNT_ROOT/boot/loader/loader.conf" <<'EOF_LOADER'
default kiosk.conf
timeout 0
console-mode keep
editor no
EOF_LOADER
    cat >"$MOUNT_ROOT/boot/loader/entries/kiosk.conf" <<EOF_ENTRY
title Offline Kiosk
linux /vmlinuz-linux
initrd /amd-ucode.img
initrd /intel-ucode.img
initrd /initramfs-linux.img
options root=UUID=$root_uuid rw rdseed=off loglevel=5 vt.global_cursor_default=0 video=1024x768
EOF_ENTRY
  else
    arch-chroot "$MOUNT_ROOT" grub-install --target=i386-pc --recheck "$disk" >&2
    mkdir -p "$MOUNT_ROOT/boot/grub"
    cat >"$MOUNT_ROOT/boot/grub/grub.cfg" <<EOF_GRUB
set default=0
set timeout=0

menuentry 'Offline Kiosk' {
    linux /vmlinuz-linux root=UUID=$root_uuid rw rdseed=off loglevel=5 vt.global_cursor_default=0 video=1024x768
  initrd /amd-ucode.img /intel-ucode.img /initramfs-linux.img
}
EOF_GRUB
  fi

  progress 82 'Verifying installed system'
  test -x "$MOUNT_ROOT/usr/local/bin/launch-electron.sh"
  test -L "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/kiosk.service"
  test -f "$MOUNT_ROOT/opt/electron-app/.kiosk-app-manifest"
  test -x "$MOUNT_ROOT/usr/bin/grub-install"
  test -s "$MOUNT_ROOT/etc/machine-id"
  test -s "$MOUNT_ROOT/etc/kiosk-board-serial"
  getcap "$MOUNT_ROOT/usr/bin/gnome-keyring-daemon" | grep -q 'cap_ipc_lock=ep'
  test ! -e "$MOUNT_ROOT/usr/bin/zenity"
  test ! -e "$MOUNT_ROOT/usr/bin/sshd"
  sync

  progress 96 'Finishing installation'
  cleanup_mounts
  trap - RETURN
  progress 100 'Installation complete'
}

recent_log_details() {
  local details
  details=$(tail -n 14 "$LOG_FILE" 2>/dev/null || true)
  if [ -n "$details" ]; then
    printf '%s' "$details"
  else
    printf '%s' 'No additional diagnostic lines were written.'
  fi
}

show_error() {
  local stage=${1:-'the offline installation'} code title summary details
  case "$stage" in
    'No usable installation disk')
      code=IW-DISK
      title='No usable installation disk found'
      summary='The installer could not find a writable, non-USB internal disk.'
      ;;
    'Preparing target disk')
      code=IW-PREP
      title='Could not prepare the installation disk'
      summary='The selected disk could not be checked, erased, or partitioned.'
      ;;
    'Formatting system partitions')
      code=IW-FORMAT
      title='Could not format the installation disk'
      summary='The system partitions could not be created for Offline Kiosk.'
      ;;
    'Copying Offline Kiosk')
      code=IW-COPY
      title='Could not copy Offline Kiosk'
      summary='The offline system files could not be copied to the installation disk.'
      ;;
    'Configuring boot and network')
      code=IW-BOOT
      title='Could not configure the installed system'
      summary='The installer copied the system but could not finish its boot or network setup.'
      ;;
    'Verifying installed system')
      code=IW-VERIFY
      title='Installed system verification failed'
      summary='The installer found an incomplete or unexpected installed-system file.'
      ;;
    'Finishing installation')
      code=IW-FINISH
      title='Could not finish installation'
      summary='The installation was almost complete but could not perform its final cleanup.'
      ;;
    *)
      code=IW-UNKNOWN
      title='Installation could not finish'
      summary='The installer stopped unexpectedly before it could complete.'
      ;;
  esac
  log "INSTALLATION FAILED: code=${code}; stage=${stage}"
  details=$(recent_log_details)
  clear_screen
  printf '%s\n\n' 'INSTALLATION FAILED'
  printf 'Version: %s\n' "$KIOSK_VERSION"
  printf '%s\n' "$title"
  printf '\nSummary: %s\n' "$summary"
  printf 'Support code: %s\n' "$code"
  printf '%s\n' 'Send the title and support code above to Kiosk support.'
  printf '\n%s\n' 'Recent installer log:'
  printf '%s\n' '------------------------------------------------------------'
  printf '%s\n' "$details"
  printf '%s\n' '------------------------------------------------------------'
  printf 'Full log: %s\n\n' "$LOG_FILE"
  retry_install_error_logs "$stage" "$code" "$details"
  printf '\n'
  printf '%s' 'Press Enter to restart: '
  read -r _ || true
  systemctl reboot --force
}

show_complete() {
  clear_screen
  printf '%s\n\n' 'INSTALLATION COMPLETE'
  printf '%s\n' 'Offline Kiosk has been installed successfully.'
  printf 'Version: %s\n\n' "$KIOSK_VERSION"
  printf '%s\n\n' 'Remove the flash drive, then press Enter to restart.'
  read -r _ || true
  systemctl reboot --force
}

main() {
  local disk stage_file failed_stage install_pid
  if ! disk=$(target_disk); then
    show_error 'No usable installation disk'
  fi

  show_start_screen "$disk"
  log "Installation initiated by operator for target disk $disk"
  # A slow or missing network must not delay destructive installation work.
  # The child observes New Relic first, then the optional logger-server.
  send_install_started_logs "$disk" &
  stage_file=$(mktemp /tmp/kiosk-stage.XXXXXX)
  STAGE_FILE=$stage_file
  # Run in a separate shell so `set -e` reliably stops at the first failed
  # disk command. The parent keeps stdout/stderr on the console and waits for
  # the real exit status before showing either the result or diagnostics.
  install_target "$disk" 2> >(tee -a "$LOG_FILE" >&2) &
  install_pid=$!
  if wait "$install_pid"; then
    rm -f "$stage_file"
    show_complete
  fi
  failed_stage='the offline installation'
  [ ! -s "$stage_file" ] || failed_stage=$(tail -n 1 "$stage_file")
  rm -f "$stage_file"
  show_error "$failed_stage"
}

main "$@"
