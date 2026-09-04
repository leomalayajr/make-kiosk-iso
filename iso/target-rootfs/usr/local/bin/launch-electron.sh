#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/electron-app
APP_IMAGE="$APP_DIR/app.AppImage"
APP_RUNTIME_DIR=/home/appuser/.cache/kiosk-app-runtime
APP_RUNTIME_STAGING=/home/appuser/.cache/kiosk-app-runtime.new
UPDATE_FEED_URL=''
APP_UPDATER_CACHE_DIR_NAME=''
LOG_FILE=/home/appuser/.cache/kiosk.log
FIXED_RESOLUTION=1024x768
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

KIOSK_VERSION=$(cat /etc/kiosk-version 2>/dev/null || echo 'unknown')
echo "[INFO] launch-electron.sh starting — version: $KIOSK_VERSION" >>"$LOG_FILE"

# ── Optional remote logging sinks ─────────────────────────────────────
# New Relic is the primary sink and logger-server remains an independent,
# secondary sink. Both are intentionally best-effort: the kiosk must always
# launch when either endpoint is unavailable.
LOGGER_SERVER_URL=''
NEW_RELIC_LICENSE_KEY=''
NEW_RELIC_LOG_ENDPOINT=''
NEW_RELIC_ENVIRONMENT=''
NEW_RELIC_SERVICE_NAME='kiosk-production'
NEW_RELIC_LAST_ERROR=''
REMOTE_LOG_PID=''

decode_remote_log_value() {
  local encoded=$1
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 -d 2>/dev/null
}

UPDATE_FEED_URL=$(decode_remote_log_value "${KIOSK_UPDATE_FEED_URL_B64:-}" || true)
APP_UPDATER_CACHE_DIR_NAME=$(decode_remote_log_value "${KIOSK_APP_UPDATER_CACHE_DIR_NAME_B64:-}" || true)

is_new_relic_log_endpoint() {
  case $1 in
    https://log-api.newrelic.com/log/v1|\
    https://log-api.eu.newrelic.com/log/v1|\
    https://log-api.jp.nr-data.net/log/v1|\
    https://gov-log-api.newrelic.com/log/v1) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "${KIOSK_LOGGER_SERVER_B64:-}" ]; then
  LOGGER_SERVER_URL=$(decode_remote_log_value "$KIOSK_LOGGER_SERVER_B64" || true)
  LOGGER_SERVER_URL="${LOGGER_SERVER_URL%/}"
  LOGGER_SERVER_URL="${LOGGER_SERVER_URL}/log"
fi

if [ "${KIOSK_NEW_RELIC_LOG_ENABLED:-false}" = true ]; then
  NEW_RELIC_LICENSE_KEY=$(decode_remote_log_value "${KIOSK_NEW_RELIC_LICENSE_KEY_B64:-}" || true)
  NEW_RELIC_LOG_ENDPOINT=$(decode_remote_log_value "${KIOSK_NEW_RELIC_LOG_ENDPOINT_B64:-}" || true)
  NEW_RELIC_ENVIRONMENT=$(decode_remote_log_value "${KIOSK_NEW_RELIC_ENVIRONMENT_B64:-}" || true)
  NEW_RELIC_SERVICE_NAME=$(decode_remote_log_value "${KIOSK_NEW_RELIC_SERVICE_NAME_B64:-}" || true)
  NEW_RELIC_SERVICE_NAME="${NEW_RELIC_SERVICE_NAME:-kiosk-production}"
  if [ -z "$NEW_RELIC_LICENSE_KEY" ] || [ -z "$NEW_RELIC_LOG_ENDPOINT" ] || [ -z "$NEW_RELIC_ENVIRONMENT" ] || [ -z "$NEW_RELIC_SERVICE_NAME" ] || ! is_new_relic_log_endpoint "$NEW_RELIC_LOG_ENDPOINT"; then
    echo '[WARN] New Relic logging configuration is invalid; New Relic logging disabled' >>"$LOG_FILE"
    NEW_RELIC_LICENSE_KEY=''
    NEW_RELIC_LOG_ENDPOINT=''
    NEW_RELIC_ENVIRONMENT=''
    NEW_RELIC_SERVICE_NAME='kiosk-production'
  fi
fi

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

remote_log_payload() {
  local level=$1 message=$2 timestamp
  timestamp=$(date +%s%3N)
  printf '{"deployment.environment.name":"%s","level":"%s","logtype":"kiosk","message":"%s","newrelic.logPattern":"nr.DID_NOT_MATCH","newrelic.source":"kiosk.kiosk","service.name":"%s","service.namespace":"kiosk","timestamp":%s,"version":"%s"}' \
    "$(json_escape "$NEW_RELIC_ENVIRONMENT")" "$(json_escape "$level")" "$(json_escape "$message")" \
    "$(json_escape "$NEW_RELIC_SERVICE_NAME")" "$timestamp" "$(json_escape "$KIOSK_VERSION")"
}

send_new_relic_log() {
  local level=$1 message=$2 payload response='' curl_status=0
  [ -n "$NEW_RELIC_LICENSE_KEY" ] || return 0
  NEW_RELIC_LAST_ERROR=''
  payload=$(remote_log_payload "$level" "$message")
  # --header @- keeps the ingest key out of curl's command-line arguments.
  if response=$(printf 'Api-Key: %s\n' "$NEW_RELIC_LICENSE_KEY" | curl -sS --connect-timeout 2 --max-time 3 \
    -X POST -H 'Content-Type: application/json' -H @- \
    --data-binary "$payload" -o /dev/null -w '%{http_code}' "$NEW_RELIC_LOG_ENDPOINT" 2>/dev/null); then
    [[ $response =~ ^2[0-9][0-9]$ ]] && return 0
    NEW_RELIC_LAST_ERROR="New Relic returned HTTP ${response:-no-status}"
  else
    curl_status=$?
    case $curl_status in
      5|6|7|28) NEW_RELIC_LAST_ERROR="New Relic connection failed (curl exit $curl_status)" ;;
      *) NEW_RELIC_LAST_ERROR="New Relic delivery failed (curl exit $curl_status)" ;;
    esac
  fi
  return 1
}

send_logger_server_log() {
  local level=$1 message=$2 payload
  [ -n "$LOGGER_SERVER_URL" ] || return 0
  payload=$(remote_log_payload "$level" "$message")
  curl -sS --max-time 3 -X POST -H 'Content-Type: application/json' \
    --data-binary "$payload" "$LOGGER_SERVER_URL" >/dev/null 2>&1 || true
}

# Send to New Relic first, then independently to the existing logger-server.
# Silently ignores all errors to preserve kiosk availability.
remote_log() {
  local level=$1 message=$2
  if ! send_new_relic_log "$level" "$message"; then
    # Record the cause at the secondary sink without including the ingest key.
    send_logger_server_log 'WARN' "New Relic log delivery failed: $NEW_RELIC_LAST_ERROR"
  fi
  send_logger_server_log "$level" "$message"
}

if [ -n "$NEW_RELIC_LICENSE_KEY" ]; then
  echo "[INFO] New Relic logging enabled: $NEW_RELIC_LOG_ENDPOINT" >>"$LOG_FILE"
fi
if [ -n "$LOGGER_SERVER_URL" ]; then
  echo "[INFO] Secondary logger server enabled: $LOGGER_SERVER_URL" >>"$LOG_FILE"
fi
if [ -n "$NEW_RELIC_LICENSE_KEY" ] || [ -n "$LOGGER_SERVER_URL" ]; then
  remote_log "BOOT" "launch-electron.sh starting — version: $KIOSK_VERSION"
  pkill -f "tail -n 0 -f $LOG_FILE" 2>/dev/null || true
  (
    tail -n 0 -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      [ -n "$line" ] || continue
      remote_level="INFO"
      if [[ "$line" =~ ^\[([A-Z]+)\] ]]; then
        remote_level="${BASH_REMATCH[1]}"
      fi
      remote_log "$remote_level" "$line"
    done
  ) &
  REMOTE_LOG_PID=$!
fi

on_error() {
    local exit_code=$?
    local line=${BASH_LINENO[0]}
    echo "[FATAL] launch-electron.sh line $line: command failed with exit code $exit_code" >>"$LOG_FILE"
    echo "[FATAL] Last command: $BASH_COMMAND" >>"$LOG_FILE"
    remote_log "FATAL" "launch-electron.sh line $line: command failed with exit code $exit_code"
}
trap on_error ERR

prepare_app_runtime() {
  local resources_dir=''

  [ -n "$UPDATE_FEED_URL" ] || {
    echo '[FATAL] Update feed URL is not configured' >>"$LOG_FILE"
    remote_log "FATAL" "Update feed URL is not configured"
    return 1
  }
  [ -n "$APP_UPDATER_CACHE_DIR_NAME" ] || {
    echo '[FATAL] App updater cache directory is not configured' >>"$LOG_FILE"
    remote_log "FATAL" "App updater cache directory is not configured"
    return 1
  }

  [ -x "$APP_IMAGE" ] || {
    echo "[FATAL] AppImage is missing or not executable: $APP_IMAGE" >>"$LOG_FILE"
    remote_log "FATAL" "AppImage is missing or not executable"
    return 1
  }

  # The published AppImage is the writable source of truth that
  # electron-updater replaces. Extract a separate runtime tree so the kiosk
  # does not require FUSE, then inject the updater cache configuration missing
  # from older production AppImages. APPIMAGE remains pointed at the untouched
  # release artifact below, preserving native AppImage update semantics.
  rm -rf "$APP_RUNTIME_STAGING"
  mkdir -p "$APP_RUNTIME_STAGING"
  (
    cd "$APP_RUNTIME_STAGING"
    "$APP_IMAGE" --appimage-extract >/dev/null
  )

  [ -x "$APP_RUNTIME_STAGING/squashfs-root/AppRun" ] \
    || { echo '[FATAL] AppImage extraction did not create AppRun' >>"$LOG_FILE"; return 1; }
  resources_dir=$(find "$APP_RUNTIME_STAGING/squashfs-root" -type f \
    -path '*/resources/app.asar' -printf '%h\n' -quit)
  [ -n "$resources_dir" ] \
    || { echo '[FATAL] AppImage runtime does not contain resources/app.asar' >>"$LOG_FILE"; return 1; }

  {
    printf 'provider: generic\n'
    printf 'url: %s\n' "$UPDATE_FEED_URL"
    printf 'updaterCacheDirName: %s\n' "$APP_UPDATER_CACHE_DIR_NAME"
  } >"$resources_dir/app-update.yml"
  chmod 0644 "$resources_dir/app-update.yml"

  rm -rf "$APP_RUNTIME_DIR"
  mv "$APP_RUNTIME_STAGING/squashfs-root" "$APP_RUNTIME_DIR"
  rmdir "$APP_RUNTIME_STAGING"
}

prepare_app_runtime
app_bin="$APP_RUNTIME_DIR/AppRun"
export APPIMAGE="$APP_IMAGE"
export APPDIR="$APP_RUNTIME_DIR"
remote_log "BOOT" "Prepared AppImage runtime: $APP_IMAGE"

# ── systemd user D-Bus guard ──────────────────────────────────────────
# PAMName=login creates appuser's runtime directory and user bus.  Always use
# that bus so Electron and the already-running gnome-keyring daemon agree on
# the same login session.
app_uid=$(id -u)
export XDG_RUNTIME_DIR="/run/user/$app_uid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

dbus_ready=0
if command -v dbus-send >/dev/null 2>&1; then
  for _ in {1..50}; do
    if dbus-send --session --print-reply \
      --dest=org.freedesktop.DBus \
      /org/freedesktop/DBus \
      org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
      dbus_ready=1
      break
    fi
    sleep 0.1
  done
fi

if [ "$dbus_ready" -ne 1 ]; then
  # A missing session bus must not turn a recoverable safeStorage problem into
  # an appliance boot failure. Electron can use its application fallback and
  # the kiosk will still be usable while the underlying session issue is
  # reported in the log.
  echo "[WARN] appuser systemd D-Bus is not reachable at $DBUS_SESSION_BUS_ADDRESS; continuing without Secret Service" >>"$LOG_FILE"
  remote_log "WARN" "appuser systemd D-Bus is not reachable; continuing without Secret Service"
else
  echo "[INFO] appuser systemd D-Bus is reachable" >>"$LOG_FILE"
  remote_log "INFO" "appuser systemd D-Bus is reachable"
fi

# ── gnome-keyring guard ───────────────────────────────────────────────
# Electron's safeStorage uses the Secret Service D-Bus name
# (org.freedesktop.secrets).  It is an optional enhancement: the app has a
# compatible fallback when a headless VM cannot provide a usable collection.
# Never delete a user's keyring or fail the kiosk just because Secret Service
# is unavailable.
keyring_available=0
APPUSER_NAME="${KIOSK_USER:-appuser}"

secret_service_ready() {
  dbus-send --session --print-reply \
    --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus \
    org.freedesktop.DBus.GetNameOwner \
    string:org.freedesktop.secrets >/dev/null 2>&1
}

wait_secret_service() {
  local tries=$1 i
  for ((i = 0; i < tries; i++)); do
    secret_service_ready && return 0
    sleep 0.1
  done
  return 1
}

# Diagnostic only. gnome-keyring never creates a "default" collection on its
# own — it only exists once some client asks the Secret Service to create
# one (Chromium's OSCrypt does this itself on startup; see
# freedesktop_secret_key_provider.cc).  So checking this before Electron
# launches always shows "/" and proves nothing.  This is called from a
# backgrounded subshell a few seconds after Electron starts, to see what
# Chromium's own CreateCollection/Unlock attempt actually resulted in —
# Chromium doesn't log an error either way if that attempt fails.
log_default_collection_state() {
  local tag=$1 path locked
  path=$(dbus-send --session --print-reply --dest=org.freedesktop.secrets \
    /org/freedesktop/secrets org.freedesktop.Secret.Service.ReadAlias string:default 2>&1 \
    | awk '/object path/{print $3}' | tr -d '"')
  echo "[DEBUG] ($tag) Secret Service default alias -> ${path:-<none>}" >>"$LOG_FILE"
  remote_log "DEBUG" "($tag) Secret Service default alias -> ${path:-<none>}"
  if [ -n "$path" ] && [ "$path" != "/" ]; then
    locked=$(dbus-send --session --print-reply --dest=org.freedesktop.secrets \
      "$path" org.freedesktop.DBus.Properties.Get \
      string:org.freedesktop.Secret.Collection string:Locked 2>&1 | tail -1)
    echo "[DEBUG] ($tag) Default collection Locked property -> $locked" >>"$LOG_FILE"
    remote_log "DEBUG" "($tag) Default collection Locked property -> $locked"
  fi
}

start_keyring_as_appuser() {
  if [ "$(id -u)" -eq 0 ]; then
    runuser -u "$APPUSER_NAME" -- env \
      "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
      "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" \
      gnome-keyring-daemon --daemonize --components=secrets >>"$LOG_FILE" 2>>"$LOG_FILE"
  else
    gnome-keyring-daemon --daemonize --components=secrets >>"$LOG_FILE" 2>>"$LOG_FILE"
  fi
}

if [ "$dbus_ready" -eq 1 ] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
  if secret_service_ready; then
    keyring_available=1
    echo "[INFO] Secret Service is available on the session bus" >>"$LOG_FILE"
    remote_log "INFO" "Secret Service is available on the session bus"
  else
    echo "[INFO] Starting gnome-keyring Secret Service" >>"$LOG_FILE"
    unset GNOME_KEYRING_CONTROL 2>/dev/null || true
    start_keyring_as_appuser || true
    if wait_secret_service 50; then
      keyring_available=1
      echo "[INFO] gnome-keyring Secret Service started as $APPUSER_NAME" >>"$LOG_FILE"
      remote_log "INFO" "gnome-keyring Secret Service started"
    fi
  fi
fi

if [ "$keyring_available" -ne 1 ]; then
  echo "[WARN] Secret Service unavailable; launching Electron with its storage fallback" >>"$LOG_FILE"
  remote_log "WARN" "Secret Service unavailable; launching Electron with storage fallback"
fi

# ── Machine fingerprint data guard ────────────────────────────────────
fingerprint_sources_ok=0
fingerprint_data=""

collect_fingerprint() {
  # Primary: board serial (most reliable on physical hardware)
  if [ -r /sys/class/dmi/id/board_serial ]; then
    local val
    val=$(cat /sys/class/dmi/id/board_serial 2>/dev/null | tr -d '[:space:]')
    if [ -n "$val" ]; then fingerprint_data="$val"; return 0; fi
  fi

  # Secondary: product UUID (standard on most x86 systems)
  if [ -r /sys/class/dmi/id/product_uuid ]; then
    local val
    val=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '[:space:]')
    if [ -n "$val" ]; then fingerprint_data="$val"; return 0; fi
  fi

  # Tertiary: product serial (OEM service tags, HP/Dell/Lenovo)
  if [ -r /sys/class/dmi/id/product_serial ]; then
    local val
    val=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '[:space:]')
    if [ -n "$val" ]; then fingerprint_data="$val"; return 0; fi
  fi

  # Quaternary: /etc/machine-id (always available on systemd systems, works in VMs)
  if [ -r /etc/machine-id ]; then
    local val
    val=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')
    if [ -n "$val" ]; then fingerprint_data="$val"; return 0; fi
  fi

  # Quinary: board vendor + product name hash (fallback for containers)
  local bv="" bn=""
  [ -r /sys/class/dmi/id/board_vendor ] && bv=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null | tr -d '[:space:]') || true
  [ -r /sys/class/dmi/id/board_name ] && bn=$(cat /sys/class/dmi/id/board_name 2>/dev/null | tr -d '[:space:]') || true
  if [ -n "$bv" ] || [ -n "$bn" ]; then
    fingerprint_data=$(printf '%s-%s' "$bv" "$bn" | sha256sum | cut -d' ' -f1)
    return 0
  fi

  # Senary: MAC address of first physical network interface
  local mac
  mac=$(ip -br link show 2>/dev/null | awk '$3 != "lo" && $1 !~ /^docker/ { split($2, a, ":"); if (a[1] != "00:00:00:00:00:00") { print $2; exit } }' || true)
  if [ -n "$mac" ]; then
    fingerprint_data=$(printf '%s' "$mac" | sha256sum | cut -d' ' -f1)
    return 0
  fi

  return 1
}

# ── Identify which source provided the fingerprint (for logging) ──────
identify_fingerprint_source() {
  local fp="$1"
  # Check each source in priority order
  if [ -r /sys/class/dmi/id/board_serial ]; then
    local val; val=$(cat /sys/class/dmi/id/board_serial 2>/dev/null | tr -d '[:space:]')
    if [ "$val" = "$fp" ]; then echo "board_serial"; return; fi
  fi
  if [ -r /sys/class/dmi/id/product_uuid ]; then
    local val; val=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '[:space:]')
    if [ "$val" = "$fp" ]; then echo "product_uuid"; return; fi
  fi
  if [ -r /sys/class/dmi/id/product_serial ]; then
    local val; val=$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '[:space:]')
    if [ "$val" = "$fp" ]; then echo "product_serial"; return; fi
  fi
  if [ -r /etc/machine-id ]; then
    local val; val=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')
    if [ "$val" = "$fp" ]; then echo "machine-id"; return; fi
  fi
  local bv="" bn=""
  [ -r /sys/class/dmi/id/board_vendor ] && bv=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null | tr -d '[:space:]') || true
  [ -r /sys/class/dmi/id/board_name ] && bn=$(cat /sys/class/dmi/id/board_name 2>/dev/null | tr -d '[:space:]') || true
  if [ -n "$bv" ] || [ -n "$bn" ]; then
    local h; h=$(printf '%s-%s' "$bv" "$bn" | sha256sum | cut -d' ' -f1)
    if [ "$h" = "$fp" ]; then echo "board_vendor+name"; return; fi
  fi
  local mac_check
  mac_check=$(ip -br link show 2>/dev/null | awk '$3 != "lo" && $1 !~ /^docker/ { print $2; exit }')
  if [ -n "$mac_check" ]; then
    local h; h=$(printf '%s' "$mac_check" | sha256sum | cut -d' ' -f1)
    if [ "$h" = "$fp" ]; then echo "MAC"; return; fi
  fi
  echo "unknown"
}

if collect_fingerprint; then
  fingerprint_sources_ok=1
  fp_source=$(identify_fingerprint_source "$fingerprint_data")
  echo "[INFO] Machine fingerprint collected: ${fingerprint_data:0:8}... (source: ${fp_source})" >>"$LOG_FILE"
  remote_log "INFO" "Machine fingerprint collected successfully via ${fp_source}"
else
  echo "[WARN] Could not collect machine fingerprint — Electron generate-fingerprint will fail" >>"$LOG_FILE"
  remote_log "WARN" "No fingerprint data available; Electron may fallback to network-based ID"
fi

# ── Network interface guard (for Electron fingerprint helper) ─────────
network_interfaces_ok=0
if ip -br link show 2>/dev/null | grep -qv '^lo$'; then
  network_interfaces_ok=1
  echo "[INFO] Network interfaces detected: $(ip -br link show 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')" >>"$LOG_FILE"
  remote_log "INFO" "Network interfaces available for fingerprint collection"
else
  echo "[WARN] No network interfaces detected — fingerprint collection may be limited" >>"$LOG_FILE"
  remote_log "WARN" "No network interfaces detected"
fi

# ── Credential arguments ──────────────────────────────────────────────
decode_value() {
  local encoded=$1
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 -d 2>/dev/null
}

credential_args=()
fingerprint=$(decode_value "${KIOSK_FINGERPRINT_B64:-}")
if [ -z "$fingerprint" ] && [ -n "${fingerprint_data:-}" ]; then
  fingerprint="$fingerprint_data"
  echo "[INFO] Using collected machine fingerprint as build-time value was empty" >>"$LOG_FILE"
fi
api_key=$(decode_value "${KIOSK_API_KEY_B64:-}")
api_secret=$(decode_value "${KIOSK_API_SECRET_B64:-}")
[ -n "$fingerprint" ] && credential_args+=("--fingerprint=$fingerprint")
[ -n "$api_key" ] && credential_args+=("--api-key=$api_key")
[ -n "$api_secret" ] && credential_args+=("--api-secret=$api_secret")
if [ "${KIOSK_ALLOW_OVERRIDE_FINGERPRINT:-0}" = "1" ]; then
  credential_args+=("--allow-override-fingerprint")
  echo "[INFO] Fingerprint override enabled via build-time flag" >>"$LOG_FILE"
fi

cd "$APP_RUNTIME_DIR"

# Enable [IMPORTANT] log output from the Electron app's $logger. The packaged
# app checks process.env.NODE_ENV === 'development' to emit [IMPORTANT] lines.
export NODE_ENV=development

# Chromium's OSCrypt (which backs Electron's safeStorage) selects its encryption
# backend at startup by checking XDG_CURRENT_DESKTOP.  Without this, it defaults
# to "basic_text" (no encryption) even when gnome-keyring is running and
# org.freedesktop.secrets is on the D-Bus session bus.  Newer Chromium's async
# OSCrypt (components/os_crypt/async/browser/freedesktop_secret_key_provider.cc)
# only recognizes "gnome-libsecret", "kwallet[56]" or "basic" for
# --password-store; the older "gnome" alias logs "Unknown password store: gnome"
# and silently falls back to no encryption.
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-GNOME}"
electron_args=(--no-sandbox --password-store=gnome-libsecret --window-size=1024,768 --force-device-scale-factor=1)

if [ -n "$REMOTE_LOG_PID" ]; then
  trap 'kill '"$REMOTE_LOG_PID"' 2>/dev/null; wait '"$REMOTE_LOG_PID"' 2>/dev/null || true' EXIT
fi

# First give a detected render node a normal GPU launch. If Electron exits,
# kiosk.service restarts this script and the marker selects the safe software
# path, preventing a broken DRM driver from creating a restart loop.
state_dir=/run/kiosk
mkdir -p "$state_dir"

# Backgrounded so it doesn't delay Electron's launch below; the sleep gives
# Chromium's OSCrypt init time to run before we sample the result.
( sleep 5; log_default_collection_state "post-launch" ) &
if { [ -c /dev/dri/renderD128 ] || compgen -G '/dev/dri/renderD*' >/dev/null; } \
  && [ ! -e "$state_dir/gpu-attempted" ]; then
  : >"$state_dir/gpu-attempted"
  remote_log "BOOT" "Launching Electron with GPU rasterization"
  if [ -n "$REMOTE_LOG_PID" ]; then
    "$app_bin" "${electron_args[@]}" --enable-gpu-rasterization ${credential_args[*]} >>"$LOG_FILE" 2>&1
  else
    exec "$app_bin" "${electron_args[@]}" --enable-gpu-rasterization ${credential_args[*]} >>"$LOG_FILE" 2>&1
  fi
fi
if [ -n "$REMOTE_LOG_PID" ]; then
  remote_log "BOOT" "Launching Electron with software rendering (disable-gpu)"
  "$app_bin" "${electron_args[@]}" --disable-gpu ${credential_args[*]} >>"$LOG_FILE" 2>&1
else
  exec "$app_bin" "${electron_args[@]}" --disable-gpu ${credential_args[*]} >>"$LOG_FILE" 2>&1
fi
