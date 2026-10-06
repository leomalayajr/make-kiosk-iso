#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR="$SCRIPT_DIR"
STATE_DIR="$PROJECT_DIR/.notes"
UPLOAD_ENABLED=0
DEBUG_BUILD_ENABLED=0
BUILT_ISO=''
DROPBOX_DATE_DIR_NAME=''
DROPBOX_RUN_DIR_NAME=''
DROPBOX_UPLOAD_RELATIVE_DIR=''
DROPBOX_UPLOAD_DIR=''

usage() {
  printf 'Usage: %s [--debug] [--upload|--no-upload]\n' "${BASH_SOURCE[0]}"
  printf '\nBuild all premium installer ISOs. Upload mode builds and uploads each product one at a time.\n'
  printf 'Product and Dropbox settings are loaded from the local .env file.\n'
  printf '\nOptions:\n'
  printf '  --debug      Enable Electron debug mode and prefix ISO names with DEBUG-\n'
  printf '  --upload     Build and upload ISOs; remove local outputs after confirmed sync\n'
  printf '  --no-upload  Build ISOs locally without using Dropbox (default)\n'
  printf '  --help       Show this help\n'
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --debug) DEBUG_BUILD_ENABLED=1 ;;
    --upload) UPLOAD_ENABLED=1 ;;
    --no-upload) UPLOAD_ENABLED=0 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# Load trusted local Bash configuration; caller overrides take precedence.
CONFIG_VARIABLES=(APP_WORKSPACE_DIR NODE24_BIN APPIMAGE_RUNTIME SHARED_BUILD_FILTER
  PREMIUM_PRODUCTS DROPBOX_DIR DROPBOX_INSTALLERS_PATH
  DROPBOX_SYNC_TIMEOUT_SECONDS DROPBOX_CLEANUP_TIMEOUT_SECONDS)
declare -A INLINE_CONFIG=()
for variable_name in "${CONFIG_VARIABLES[@]}"; do
  if [ "${!variable_name+x}" = x ]; then
    INLINE_CONFIG["$variable_name"]=${!variable_name}
  fi
done
if [ -f "$PROJECT_DIR/.env" ]; then
  source "$PROJECT_DIR/.env"
fi
for variable_name in "${CONFIG_VARIABLES[@]}"; do
  if [ "${INLINE_CONFIG[$variable_name]+x}" = x ]; then
    printf -v "$variable_name" '%s' "${INLINE_CONFIG[$variable_name]}"
  fi
done
for variable_name in APP_WORKSPACE_DIR NODE24_BIN APPIMAGE_RUNTIME SHARED_BUILD_FILTER PREMIUM_PRODUCTS; do
  [ -n "${!variable_name:-}" ] || die "$variable_name must be set in .env"
done
if [ "$UPLOAD_ENABLED" -eq 1 ]; then
  for variable_name in DROPBOX_DIR DROPBOX_INSTALLERS_PATH; do
    [ -n "${!variable_name:-}" ] || die "$variable_name must be set in .env for uploads"
  done
  [[ $DROPBOX_INSTALLERS_PATH != /* && /$DROPBOX_INSTALLERS_PATH/ != */../* ]] \
    || die 'DROPBOX_INSTALLERS_PATH must stay under the Dropbox root'
fi
case "$APPIMAGE_RUNTIME" in
  /*) ;;
  *) APPIMAGE_RUNTIME="$PROJECT_DIR/$APPIMAGE_RUNTIME" ;;
esac
[ -d "$APP_WORKSPACE_DIR" ] || die 'APP_WORKSPACE_DIR must be an existing directory'
APP_WORKSPACE_DIR=$(cd "$APP_WORKSPACE_DIR" && pwd -P)

# Validate every product before any cleanup. Output folders must stay in dist.
declare -a PRODUCT_NAMES=() PRODUCT_FILTERS=() PRODUCT_DIRS=() PRODUCT_PREFIXES=()
while IFS= read -r product || [ -n "$product" ]; do
  [ -n "$product" ] || continue
  IFS='|' read -r app_name app_filter app_dist output_prefix extra <<<"$product"
  [ -n "$app_name" ] && [ -n "$app_filter" ] && [ -n "$app_dist" ] && [ -n "$output_prefix" ] \
    && [ -z "$extra" ] && [[ $product != *'|' ]] || die 'invalid PREMIUM_PRODUCTS row'
  [[ $app_filter =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'invalid product build filter'
  [[ $output_prefix =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'invalid product output prefix'
  [[ $app_dist =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'product output must be one directory name under dist'
  app_dist="$APP_WORKSPACE_DIR/dist/$app_dist"
  [[ $(realpath -m -- "$app_dist") == "$app_dist" ]] || die 'product output must not resolve outside its configured path'
  for previous in "${PRODUCT_DIRS[@]}"; do
    [ "$previous" != "$app_dist" ] || die 'duplicate product output directory'
  done
  for previous in "${PRODUCT_PREFIXES[@]}"; do
    [ "$previous" != "$output_prefix" ] || die 'duplicate product output prefix'
  done
  PRODUCT_NAMES+=("$app_name")
  PRODUCT_FILTERS+=("$app_filter")
  PRODUCT_DIRS+=("$app_dist")
  PRODUCT_PREFIXES+=("$output_prefix")
done <<<"$PREMIUM_PRODUCTS"
[ "${#PRODUCT_NAMES[@]}" -gt 0 ] || die 'PREMIUM_PRODUCTS must contain at least one product'

# Hold the lock through all builds, uploads, and cleanup.
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/premium-build.lock"
flock -n 9 || die 'another premium ISO build is already running'

clean_previous_build_artifacts() {
  local app_dist iso_file

  for app_dist in "${PRODUCT_DIRS[@]}"; do
    if [ -e "$app_dist" ] || [ -L "$app_dist" ]; then
      printf 'Removing previous AppImage output: %s\n' "$app_dist"
      rm -rf -- "$app_dist"
    fi
  done

  shopt -s nullglob
  for iso_file in "$PROJECT_DIR"/iso/output/*.iso; do
    printf 'Removing previous installer ISO: %s\n' "$iso_file"
    rm -f -- "$iso_file"
  done
  shopt -u nullglob
}

clean_previous_build_artifacts

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: required command is not available: %s\n' "$1" >&2
    exit 1
  }
}

build_and_package() {
  local app_name=$1
  local app_filter=$2
  local app_source=$3
  local output_prefix=$4
  local app_image effective_output_prefix debug_args=()

  effective_output_prefix=$output_prefix
  if [ "$DEBUG_BUILD_ENABLED" -eq 1 ]; then
    effective_output_prefix="DEBUG-$output_prefix"
    debug_args+=(--debug)
  fi

  printf '\n=== Building %s Linux AppImage ===\n' "$app_name"
  (
    cd "$APP_WORKSPACE_DIR"
    pnpm "$app_filter" make:linux
  )

  app_image=$(find "$app_source" -type f -name '*-x64.AppImage' -print0 | sort -z -V | tail -z -n 1 | tr -d '\0')
  [ -n "$app_image" ] || {
    printf 'ERROR: no generated x64 AppImage found under: %s\n' "$app_source" >&2
    exit 1
  }
  printf 'Generated AppImage: %s\n' "$app_image"

  printf '\n=== Building %s installer ISO ===\n' "$app_name"
  (
    cd "$PROJECT_DIR"
    OUTPUT_FILE_PREFIX="$effective_output_prefix" \
      ./make-kiosk-iso.sh "$app_image" "${debug_args[@]}"
  )

  local iso_file
  iso_file=$(find "$PROJECT_DIR/iso/output" -maxdepth 1 -type f \
    -name "${effective_output_prefix}-*.iso" -print -quit)
  [ -n "$iso_file" ] || die "no generated ISO found for prefix: $effective_output_prefix"
  BUILT_ISO=$iso_file
  printf 'Generated ISO: %s\n' "$iso_file"
}

wait_for_dropbox_sync() {
  local iso_file=$1
  local relative_path="${DROPBOX_UPLOAD_RELATIVE_DIR}/$(basename "$iso_file")"
  local status status_lower frame=0 deadline=$((SECONDS + DROPBOX_SYNC_TIMEOUT_SECONDS))
  local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  while (( SECONDS < deadline )); do
    if status=$(cd "$DROPBOX_DIR" && LC_ALL=C dropbox filestatus "$relative_path" 2>&1); then
      status_lower=${status,,}
      if [[ $status_lower == *': up to date' ]]; then
        printf '\rDropbox sync complete: %-80s\n' "$relative_path"
        return 0
      fi
    fi

    if [ -t 1 ]; then
      printf '\r%s Dropbox syncing: %-68s' "${frames[frame % ${#frames[@]}]}" "$relative_path"
    elif (( frame % 30 == 0 )); then
      printf 'Dropbox upload status: %s\n' "$status"
    fi
    ((frame += 1))
    sleep 1
  done

  printf '\nERROR: Dropbox did not finish syncing %s within %s seconds.\n%s\n' \
    "$relative_path" "$DROPBOX_SYNC_TIMEOUT_SECONDS" "$status" >&2
  return 1
}

remove_local_dropbox_copy() {
  local deadline

  printf '\n=== Removing local Dropbox staging folder (keeping the online copy) ===\n'
  printf 'Selective-sync exclude: %s\n' "$DROPBOX_UPLOAD_RELATIVE_DIR"
  (
    cd "$DROPBOX_DIR"
    dropbox exclude add "$DROPBOX_UPLOAD_RELATIVE_DIR"
  ) || return 1

  # Exclusion returns before the daemon finishes removing the local folder.
  deadline=$((SECONDS + DROPBOX_CLEANUP_TIMEOUT_SECONDS))
  while [ -e "$DROPBOX_UPLOAD_DIR" ] || [ -L "$DROPBOX_UPLOAD_DIR" ]; do
    if (( SECONDS >= deadline )); then
      printf '\nERROR: Dropbox local cleanup did not finish within %s seconds: %s\n' \
        "$DROPBOX_CLEANUP_TIMEOUT_SECONDS" "$DROPBOX_UPLOAD_DIR" >&2
      printf 'Local build outputs are kept. Check Dropbox before retrying.\n' >&2
      return 1
    fi
    if [ -t 1 ] || (( (deadline - SECONDS) % 30 == 0 )); then
      printf 'Waiting for Dropbox to remove the local folder... %ss remaining\n' "$((deadline - SECONDS))"
    fi
    sleep 1
  done
  printf '\nDropbox local staging folder removed.\n'
}

prepare_dropbox_upload() {
  [ "$UPLOAD_ENABLED" -eq 1 ] || return 0

  DROPBOX_SYNC_TIMEOUT_SECONDS="${DROPBOX_SYNC_TIMEOUT_SECONDS:-3600}"
  [[ $DROPBOX_SYNC_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] \
    || die 'DROPBOX_SYNC_TIMEOUT_SECONDS must be a positive integer'
  DROPBOX_CLEANUP_TIMEOUT_SECONDS="${DROPBOX_CLEANUP_TIMEOUT_SECONDS:-300}"
  [[ $DROPBOX_CLEANUP_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]] \
    || die 'DROPBOX_CLEANUP_TIMEOUT_SECONDS must be a positive integer'

  require_command dropbox
  require_command rsync
  [ -d "$DROPBOX_DIR" ] || die "Dropbox folder not found: $DROPBOX_DIR (set DROPBOX_DIR if it is elsewhere)"

  DROPBOX_DATE_DIR_NAME=$(LC_ALL=C date +%b-%d-%Y)

  dropbox_is_running() {
    local running_exit=0
    (cd "$DROPBOX_DIR" && dropbox running >/dev/null 2>&1) || running_exit=$?
    # Dropbox's CLI returns 1 when the daemon is running and 0 when it is not.
    [ "$running_exit" -eq 1 ]
  }

  if ! dropbox_is_running; then
    printf 'Dropbox daemon is not running; starting it...\n'
    (cd "$DROPBOX_DIR" && dropbox start)
    for _ in {1..30}; do
      dropbox_is_running && break
      sleep 1
    done
    dropbox_is_running || die 'Dropbox daemon did not become ready'
  fi
}

upload_iso() {
  local iso_file=$1
  local app_dist=$2
  local attempt checksum size

  DROPBOX_RUN_DIR_NAME="$(LC_ALL=C date +%H-%M-%S)-$(basename "$iso_file" .iso)-$$"
  DROPBOX_UPLOAD_RELATIVE_DIR="${DROPBOX_INSTALLERS_PATH}/${DROPBOX_DATE_DIR_NAME}/${DROPBOX_RUN_DIR_NAME}"
  DROPBOX_UPLOAD_DIR="$DROPBOX_DIR/$DROPBOX_UPLOAD_RELATIVE_DIR"
  mkdir -p "$DROPBOX_UPLOAD_DIR"
  printf '\n=== Staging ISO in %s/%s ===\n' \
    "$DROPBOX_DIR" "$DROPBOX_UPLOAD_RELATIVE_DIR"

  printf '\nCopying %s (local staging progress):\n' "$(basename "$iso_file")"
  for attempt in 1 2 3; do
    if rsync -ah --partial --info=progress2 -- "$iso_file" "$DROPBOX_UPLOAD_DIR/"; then
      break
    fi
    [ "$attempt" -lt 3 ] || return 1
    printf 'Local staging failed; retrying in 10 seconds (%s/3).\n' "$attempt"
    sleep 10
  done
  cmp -s -- "$iso_file" "$DROPBOX_UPLOAD_DIR/$(basename "$iso_file")" \
    || die 'Dropbox staging copy differs from the built ISO; keeping both files'
  checksum=$(sha256sum "$iso_file")
  checksum=${checksum%% *}
  size=$(stat -c '%s' "$iso_file")

  printf '\n=== Waiting for Dropbox upload ===\n'
  wait_for_dropbox_sync "$iso_file" || return 1
  printf '%s\tsynced\t%s\t%s\t%s/%s\n' "$(date -Is)" "$size" "$checksum" \
    "$DROPBOX_UPLOAD_RELATIVE_DIR" "$(basename "$iso_file")" >>"$STATE_DIR/premium-upload-receipts.tsv"

  remove_local_dropbox_copy || return 1

  printf '\n=== Removing local build outputs after confirmed Dropbox sync ===\n'
  if [ -f "$iso_file" ]; then
    printf 'Removing local ISO: %s\n' "$iso_file"
    rm -f -- "$iso_file"
  fi
  if [ -e "$app_dist" ] || [ -L "$app_dist" ]; then
    printf 'Removing local AppImage output: %s\n' "$app_dist"
    rm -rf -- "$app_dist"
  fi
  printf '%s\tcleaned\t%s\t%s\t%s/%s\n' "$(date -Is)" "$size" "$checksum" \
    "$DROPBOX_UPLOAD_RELATIVE_DIR" "$(basename "$iso_file")" >>"$STATE_DIR/premium-upload-receipts.tsv"
}

build_and_maybe_upload() {
  build_and_package "$@"
  if [ "$UPLOAD_ENABLED" -eq 1 ]; then
    upload_iso "$BUILT_ISO" "$3"
  fi
}

[ -x "$NODE24_BIN/node" ] || {
  printf 'ERROR: Node 24.19.0 was not found at: %s\n' "$NODE24_BIN" >&2
  exit 1
}

export PATH="$NODE24_BIN:$PATH"
require_command node

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" = 24 ] || {
  printf 'ERROR: this script requires Node 24, found: %s\n' "$(node --version)" >&2
  exit 1
}

require_command pnpm

[ -f "$APPIMAGE_RUNTIME" ] || die "AppImage runtime not found: $APPIMAGE_RUNTIME"
export APPIMAGE_RUNTIME

[ -d "$APP_WORKSPACE_DIR" ] || {
  printf 'ERROR: portal project directory not found: %s\n' "$APP_WORKSPACE_DIR" >&2
  exit 1
}

printf '\n=== Building shared Electron package ===\n'
(
  cd "$APP_WORKSPACE_DIR"
  pnpm "$SHARED_BUILD_FILTER" build
)

prepare_dropbox_upload

for index in "${!PRODUCT_NAMES[@]}"; do
  build_and_maybe_upload "${PRODUCT_NAMES[index]}" "${PRODUCT_FILTERS[index]}" \
    "${PRODUCT_DIRS[index]}" "${PRODUCT_PREFIXES[index]}"
done

if [ "$UPLOAD_ENABLED" -eq 1 ]; then
  printf '\nAll AppImages and installer ISOs completed successfully; ISOs are synced to Dropbox.\n'
else
  printf '\nAll AppImages and installer ISOs completed successfully locally (--no-upload).\n'
fi
