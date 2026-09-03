#!/usr/bin/env bash
# Build the Offline Kiosk hands-free installer ISO.
#
# Usage:
#   ./make-kiosk-iso.sh [appimage] \
#     --fingerprint=... --api-key=... --api-secret=... --resolution=WxH \
#     --new-relic-license-key-file=/secure/path/new-relic-license-key \
#     [--new-relic-log-enabled=true] \
#     [--new-relic-log-endpoint=https://log-api.newrelic.com/log/v1] \
#     [--new-relic-environment=production] \
#     --logger-server-url=https://... \
#     [--allow-override-fingerprint]
#
# The Electron application must be an AppImage. It is preserved unchanged at a
# stable writable path in the installed kiosk so electron-updater can replace
# it. Packages are downloaded only while building; the USB installer extracts
# the bundled target archive without network access.
#
# NEW_RELIC_* and LOGGER_SERVER_URL settings can be set via environment
# variables or .env. Direct New Relic Log API delivery is the primary optional
# remote sink; the legacy logger-server is an independent optional secondary
# sink. Failures are always ignored so remote logging can never prevent the
# kiosk from launching.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ISO_DIR="$SCRIPT_DIR/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \?//'
}

die() {
  printf "${RED}ERROR:${NC} %s\n" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is not available: $1"
}

preflight() {
  # This script is already running under Bash, so check its supported version
  # rather than attempting to find another Bash executable.
  (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required'

  local required_command
  for required_command in \
    docker base64 sort file find sed stat cp chmod mkdir mktemp du tail date grep awk; do
    require_command "$required_command"
  done

  docker info >/dev/null 2>&1 \
    || die 'Docker is not available. Start Docker and ensure your user can access it, then retry.'
}

find_latest_appimage() {
  local app_dir=$1 candidate latest=''

  [ -d "$app_dir" ] || die "Application build-output directory not found: $app_dir"

  # Sort by version rather than modification time: copying or rebuilding an
  # older artifact must not make it the bootstrap application by accident.
  while IFS= read -r -d '' candidate; do
    latest=$candidate
  done < <(
    find "$app_dir" -type f -name '*-x64.AppImage' -print0 | sort -z -V
  )

  [ -n "$latest" ] || die "no x64 AppImage found under: $app_dir"
  printf '%s\n' "$latest"
}

require_safe_value() {
  local name=$1 value=$2
  # Bash variables cannot contain NUL bytes. Reject line breaks because this
  # value is later written to a line-oriented systemd EnvironmentFile.
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "$name may not contain a newline"
}

require_secret_file() {
  local name=$1 file=$2 mode
  [ -f "$file" ] || die "$name file does not exist or is not a regular file"
  [ ! -L "$file" ] || die "$name file may not be a symbolic link"
  [ -r "$file" ] || die "$name file is not readable"
  mode=$(stat -c '%a' "$file") || die "could not read permissions for $name file"
  (( (8#$mode & 0077) == 0 )) || die "$name file must not be readable by group or others (for example: chmod 600 '$file')"
}

read_secret_file() {
  local file=$1 value=''
  IFS= read -r value <"$file" || true
  printf '%s' "$value"
}

require_boolean() {
  local name=$1 value=$2
  case $value in
    true|false) ;;
    *) die "$name must be true or false" ;;
  esac
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

base64_value() {
  printf '%s' "$1" | base64 -w 0
}

# Load configuration from .env in the project root if it exists. Preserve
# variables supplied by the caller so one-command overrides take precedence.
CONFIG_VARIABLES=(
  DEFAULT_APP_SOURCE OUTPUT_FILE_PREFIX
  UPDATE_FEED_URL APP_UPDATER_CACHE_DIR_NAME
  FINGERPRINT API_KEY API_SECRET LOGGER_SERVER_URL
  NEW_RELIC_LOG_ENABLED NEW_RELIC_LOG_ENDPOINT NEW_RELIC_LICENSE_KEY
  NEW_RELIC_LICENSE_KEY_FILE NEW_RELIC_ENVIRONMENT NEW_RELIC_SERVICE_NAME
  ALLOW_OVERRIDE_FINGERPRINT
)
declare -A INLINE_CONFIG=()
for variable_name in "${CONFIG_VARIABLES[@]}"; do
  if [ "${!variable_name+x}" = x ]; then
    INLINE_CONFIG["$variable_name"]=${!variable_name}
  fi
done

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi

for variable_name in "${CONFIG_VARIABLES[@]}"; do
  if [ "${INLINE_CONFIG[$variable_name]+x}" = x ]; then
    printf -v "$variable_name" '%s' "${INLINE_CONFIG[$variable_name]}"
  fi
done
unset CONFIG_VARIABLES INLINE_CONFIG variable_name

# An explicit positional AppImage always takes precedence. Otherwise select
# the highest-version x64 release from the directory set in .env.
DEFAULT_APP_SOURCE="${DEFAULT_APP_SOURCE:-}"
OUTPUT_FILE_PREFIX="${OUTPUT_FILE_PREFIX:-}"
UPDATE_FEED_URL="${UPDATE_FEED_URL:-}"
APP_UPDATER_CACHE_DIR_NAME="${APP_UPDATER_CACHE_DIR_NAME:-}"
APP_SOURCE=''

FINGERPRINT="${FINGERPRINT:-}"
API_KEY="${API_KEY:-}"
API_SECRET="${API_SECRET:-}"
LOGGER_SERVER_URL="${LOGGER_SERVER_URL:-}"
NEW_RELIC_LOG_ENABLED="${NEW_RELIC_LOG_ENABLED:-false}"
NEW_RELIC_LOG_ENDPOINT="${NEW_RELIC_LOG_ENDPOINT:-https://log-api.newrelic.com/log/v1}"
NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}"
NEW_RELIC_LICENSE_KEY_FILE="${NEW_RELIC_LICENSE_KEY_FILE:-}"
NEW_RELIC_ENVIRONMENT="${NEW_RELIC_ENVIRONMENT:-production}"
NEW_RELIC_SERVICE_NAME="${NEW_RELIC_SERVICE_NAME:-kiosk-production}"
ALLOW_OVERRIDE_FINGERPRINT="${ALLOW_OVERRIDE_FINGERPRINT:-0}"
# 1024x768 is the fixed kiosk and installer display contract. Keep the public
# flag for compatibility, but reject any value that would make an image behave
# differently from the supported hardware fleet.
RESOLUTION=1024x768
QEMU_TEST=0
BUILD_CONTEXT=''

# Resolve localhost/127.0.0.1 to the host's actual IP so the kiosk (running
# inside a bootable ISO) can reach the logger server on the host machine.
if [[ "$LOGGER_SERVER_URL" =~ ^http://localhost: ]]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [ -n "$HOST_IP" ]; then
        LOGGER_SERVER_URL="${LOGGER_SERVER_URL/localhost/$HOST_IP}"
    fi
elif [[ "$LOGGER_SERVER_URL" =~ ^http://127\.0\.0\.1: ]]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    if [ -n "$HOST_IP" ]; then
        LOGGER_SERVER_URL="${LOGGER_SERVER_URL/127.0.0.1/$HOST_IP}"
    fi
fi

if [ "$#" -gt 0 ] && [[ $1 != --* ]]; then
  APP_SOURCE=$1
  shift
fi

while [ "$#" -gt 0 ]; do
  case $1 in
    --fingerprint=*) FINGERPRINT=${1#*=} ;;
    --api-key=*) API_KEY=${1#*=} ;;
    --api-secret=*) API_SECRET=${1#*=} ;;
    --logger-server-url=*) LOGGER_SERVER_URL=${1#*=} ;;
    --new-relic-log-enabled=*) NEW_RELIC_LOG_ENABLED=${1#*=} ;;
    --new-relic-license-key-file=*) NEW_RELIC_LICENSE_KEY_FILE=${1#*=} ;;
    --new-relic-log-endpoint=*) NEW_RELIC_LOG_ENDPOINT=${1#*=} ;;
    --new-relic-environment=*) NEW_RELIC_ENVIRONMENT=${1#*=} ;;
    --allow-override-fingerprint) ALLOW_OVERRIDE_FINGERPRINT=1 ;;
    --resolution=*)
      [ "${1#*=}" = 1024x768 ] || die 'resolution is fixed at 1024x768 for the installer and kiosk'
      ;;
    --qemu-test) QEMU_TEST=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

preflight

if [ -z "$APP_SOURCE" ]; then
  [ -n "$DEFAULT_APP_SOURCE" ] || die 'DEFAULT_APP_SOURCE must be set in .env or supplied as the first argument'
  APP_SOURCE=$(find_latest_appimage "$DEFAULT_APP_SOURCE")
fi

[ -n "$OUTPUT_FILE_PREFIX" ] || die 'OUTPUT_FILE_PREFIX must be set in .env'
[ -n "$UPDATE_FEED_URL" ] || die 'UPDATE_FEED_URL must be set in .env'
[ -n "$APP_UPDATER_CACHE_DIR_NAME" ] || die 'APP_UPDATER_CACHE_DIR_NAME must be set in .env'
require_safe_value fingerprint "$FINGERPRINT"
require_safe_value api-key "$API_KEY"
require_safe_value api-secret "$API_SECRET"
require_safe_value output-file-prefix "$OUTPUT_FILE_PREFIX"
require_safe_value update-feed-url "$UPDATE_FEED_URL"
require_safe_value app-updater-cache-dir-name "$APP_UPDATER_CACHE_DIR_NAME"
require_safe_value new-relic-log-endpoint "$NEW_RELIC_LOG_ENDPOINT"
require_safe_value new-relic-environment "$NEW_RELIC_ENVIRONMENT"
require_safe_value new-relic-service-name "$NEW_RELIC_SERVICE_NAME"
require_boolean new-relic-log-enabled "$NEW_RELIC_LOG_ENABLED"

if [ "$NEW_RELIC_LOG_ENABLED" = true ]; then
  [ -z "$NEW_RELIC_LICENSE_KEY$NEW_RELIC_LICENSE_KEY_FILE" ] && die 'NEW_RELIC_LICENSE_KEY or NEW_RELIC_LICENSE_KEY_FILE is required when New Relic logging is enabled'
  [ -z "$NEW_RELIC_LICENSE_KEY" ] || [ -z "$NEW_RELIC_LICENSE_KEY_FILE" ] || die 'set either NEW_RELIC_LICENSE_KEY or NEW_RELIC_LICENSE_KEY_FILE, not both'
  if [ -n "$NEW_RELIC_LICENSE_KEY_FILE" ]; then
    require_secret_file new-relic-license-key "$NEW_RELIC_LICENSE_KEY_FILE"
    NEW_RELIC_LICENSE_KEY=$(read_secret_file "$NEW_RELIC_LICENSE_KEY_FILE")
  fi
  [ -n "$NEW_RELIC_LICENSE_KEY" ] || die 'New Relic license key is empty'
  require_safe_value new-relic-license-key "$NEW_RELIC_LICENSE_KEY"
  is_new_relic_log_endpoint "$NEW_RELIC_LOG_ENDPOINT" || die 'new-relic-log-endpoint must be an official New Relic Log API endpoint'
fi

prepare_app() {
  local app_dir=$1 staged_app="$1/app.AppImage" audit_dir desktop_file app_version
  [ -f "$APP_SOURCE" ] || die "AppImage not found: $APP_SOURCE"
  APP_SOURCE=$(cd "$(dirname "$APP_SOURCE")" && pwd)/$(basename "$APP_SOURCE")
  mkdir -p "$app_dir"

  [[ $APP_SOURCE == *.AppImage ]] || die 'application source must have an .AppImage extension'
  file "$APP_SOURCE" 2>/dev/null | grep -q 'ELF.*executable' \
    || die 'application source must be an ELF AppImage'
  "$APP_SOURCE" --appimage-offset >/dev/null 2>&1 \
    || die 'application source does not have a valid AppImage runtime'

  audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/kiosk-appimage-audit.XXXXXX")
  if ! (cd "$audit_dir" && "$APP_SOURCE" --appimage-extract '*.desktop' >/dev/null 2>&1); then
    rm -rf "$audit_dir"
    die 'could not read application metadata from the AppImage'
  fi
  desktop_file=$(find "$audit_dir/squashfs-root" -type f -name '*.desktop' -print -quit)
  if [ -z "$desktop_file" ]; then
    rm -rf "$audit_dir"
    die 'AppImage metadata does not contain a desktop entry'
  fi
  app_version=$(sed -n 's/^X-AppImage-Version=//p' "$desktop_file" | head -n 1)
  rm -rf "$audit_dir"
  [[ $app_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die 'AppImage desktop entry does not contain a stable semantic version'
  printf 'Application version: %s\n' "$app_version"

  # Keep the release artifact byte-for-byte intact. The stable unversioned
  # name makes electron-updater replace this same writable path on every
  # release, regardless of the versioned filename used in S3.
  cp "$APP_SOURCE" "$staged_app"
  chmod 0755 "$staged_app"
}

write_target_environment() {
  local target=$1
  umask 077
  cat >"$target" <<EOF_ENV
# Generated for this installer build. Values are base64-encoded to keep the
# systemd EnvironmentFile syntax injection-safe; launch-electron.sh decodes
# them only when passing the requested flags to the kiosk application.
KIOSK_FINGERPRINT_B64=$(base64_value "$FINGERPRINT")
KIOSK_API_KEY_B64=$(base64_value "$API_KEY")
KIOSK_API_SECRET_B64=$(base64_value "$API_SECRET")
KIOSK_RESOLUTION=$RESOLUTION
KIOSK_UPDATE_FEED_URL_B64=$(base64_value "$UPDATE_FEED_URL")
KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64=$(base64_value "$APP_UPDATER_CACHE_DIR_NAME")
INSTALL_MODE=wipe-first-disk
INSTALL_UI=tty-bash
NETWORK=wired-dhcp
VIDEO_MODE=auto
BOOT_MODE=auto-uefi-systemd-boot-or-bios-grub
EOF_ENV

if [ -n "$LOGGER_SERVER_URL" ]; then
    printf 'KIOSK_LOGGER_SERVER_B64=%s\n' "$(base64_value "$LOGGER_SERVER_URL")" >>"$target"
fi

printf 'KIOSK_NEW_RELIC_LOG_ENABLED=%s\n' "$NEW_RELIC_LOG_ENABLED" >>"$target"
if [ "$NEW_RELIC_LOG_ENABLED" = true ]; then
    printf 'KIOSK_NEW_RELIC_LICENSE_KEY_B64=%s\n' "$(base64_value "$NEW_RELIC_LICENSE_KEY")" >>"$target"
    printf 'KIOSK_NEW_RELIC_LOG_ENDPOINT_B64=%s\n' "$(base64_value "$NEW_RELIC_LOG_ENDPOINT")" >>"$target"
    printf 'KIOSK_NEW_RELIC_ENVIRONMENT_B64=%s\n' "$(base64_value "$NEW_RELIC_ENVIRONMENT")" >>"$target"
    printf 'KIOSK_NEW_RELIC_SERVICE_NAME_B64=%s\n' "$(base64_value "$NEW_RELIC_SERVICE_NAME")" >>"$target"
fi

if [ "$ALLOW_OVERRIDE_FINGERPRINT" = "1" ]; then
    printf 'KIOSK_ALLOW_OVERRIDE_FINGERPRINT=1\n' >>"$target"
fi
}

write_installer_logging_environment() {
  local target=$1
  umask 077
  cat >"$target" <<'EOF_ENV'
# Generated for this installer build. This file contains only optional remote
# logging settings; application credentials are deliberately excluded.
EOF_ENV

  if [ -n "$LOGGER_SERVER_URL" ]; then
    printf 'KIOSK_LOGGER_SERVER_B64=%s\n' "$(base64_value "$LOGGER_SERVER_URL")" >>"$target"
  fi
  printf 'KIOSK_NEW_RELIC_LOG_ENABLED=%s\n' "$NEW_RELIC_LOG_ENABLED" >>"$target"
  if [ "$NEW_RELIC_LOG_ENABLED" = true ]; then
    printf 'KIOSK_NEW_RELIC_LICENSE_KEY_B64=%s\n' "$(base64_value "$NEW_RELIC_LICENSE_KEY")" >>"$target"
    printf 'KIOSK_NEW_RELIC_LOG_ENDPOINT_B64=%s\n' "$(base64_value "$NEW_RELIC_LOG_ENDPOINT")" >>"$target"
    printf 'KIOSK_NEW_RELIC_ENVIRONMENT_B64=%s\n' "$(base64_value "$NEW_RELIC_ENVIRONMENT")" >>"$target"
    printf 'KIOSK_NEW_RELIC_SERVICE_NAME_B64=%s\n' "$(base64_value "$NEW_RELIC_SERVICE_NAME")" >>"$target"
  fi
}

cleanup() {
  [ -n "$BUILD_CONTEXT" ] && rm -rf "$BUILD_CONTEXT"
}
trap cleanup EXIT

printf "${CYAN}Offline Kiosk offline installer builder${NC}\n"
printf 'App source: %s\n' "$APP_SOURCE"
printf 'Install mode: wipe first non-USB disk (shown before Start)\n'
printf 'Video mode: auto; enforced installer and kiosk resolution: %s\n' "$RESOLUTION"

BUILD_CONTEXT=$(mktemp -d "${TMPDIR:-/tmp}/kiosk-build-context.XXXXXX")
prepare_app "$BUILD_CONTEXT/app"
write_target_environment "$BUILD_CONTEXT/kiosk.env"
write_installer_logging_environment "$BUILD_CONTEXT/installer-logging.env"

printf 'Staged Electron app: %s\n' "$(du -sh "$BUILD_CONTEXT/app" | cut -f1)"
if [ -n "$FINGERPRINT$API_KEY$API_SECRET" ]; then
  printf 'Credentials: supplied (stored only in the generated target archive)\n'
else
  printf 'Credentials: not supplied\n'
fi
if [ -n "$LOGGER_SERVER_URL" ]; then
  printf 'Logger server: %s\n' "$LOGGER_SERVER_URL"
fi
if [ "$NEW_RELIC_LOG_ENABLED" = true ]; then
  printf 'New Relic logging: enabled (endpoint: %s; key: supplied)\n' "$NEW_RELIC_LOG_ENDPOINT"
fi

BUILDER_IMAGE=kiosk-archiso-builder:latest
OUTPUT_DIR="$ISO_DIR/output"
WORK_DIR="$ISO_DIR/work/kiosk-installer"
BUILD_LOG="$OUTPUT_DIR/kiosk-installer-build.log"
PACKAGE_CACHE="$ISO_DIR/cache/pacman"
ISO_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$PACKAGE_CACHE"
: >"$BUILD_LOG"

printf "\n${GREEN}[1/3] Building Arch ISO toolchain...${NC}\n"
docker build -t "$BUILDER_IMAGE" -f "$ISO_DIR/Dockerfile.builder" "$ISO_DIR"

printf "\n${GREEN}[2/3] Building offline target archive and installer ISO...${NC}\n"
if ! docker run --rm --privileged \
  -v "$OUTPUT_DIR:/out" \
  -v "$WORK_DIR:/tmp/work" \
  -v "$PACKAGE_CACHE:/var/cache/pacman/pkg" \
  -v "$ISO_DIR:/custom:ro" \
  -v "$BUILD_CONTEXT:/build-context:ro" \
  -e ISO_TIMESTAMP="$ISO_TIMESTAMP" \
  -e OUTPUT_FILE_PREFIX="$OUTPUT_FILE_PREFIX" \
  "$BUILDER_IMAGE" >"$BUILD_LOG" 2>&1; then
  tail -n 120 "$BUILD_LOG" >&2 || true
  die "ISO build failed; full log: $BUILD_LOG"
fi
tail -n 40 "$BUILD_LOG"

ISO_FILE=$(find "$OUTPUT_DIR" -maxdepth 1 -type f \
  -name "${OUTPUT_FILE_PREFIX}-${ISO_TIMESTAMP}-*.iso" -print -quit)
[ -n "$ISO_FILE" ] || die 'no installer ISO was produced'

printf "\n${GREEN}[3/3] Verifying installer and bundled target...${NC}\n"
"$ISO_DIR/verify-iso.sh" "$ISO_FILE"

if [ "$QEMU_TEST" -eq 1 ]; then
  "$ISO_DIR/qemu-uefi-test.sh" "$ISO_FILE"
fi

printf "\n${GREEN}ISO READY${NC}\n"
printf 'File: %s\n' "$ISO_FILE"
printf 'Size: %s\n' "$(du -h "$ISO_FILE" | cut -f1)"
printf 'Built: %s\n' "$(date -d "@$(stat -c '%Y' "$ISO_FILE")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ISO_TIMESTAMP")"
