#!/bin/bash
# =============================================================================
# entrypoint.sh - runs when the container starts ("on boot").
#   1. Get a display: use the host's real monitor if DISPLAY is set,
#      otherwise start a virtual framebuffer (Xvfb) so the app always has a
#      "monitor".
#   2. Find and launch the exported Electron app.
# =============================================================================
set -e

APP_DIR="${APP_DIR:-/home/appuser/app}"
RESOLUTION="${RESOLUTION:-1280x720x24}"
APP_ARGS="${APP_ARGS:-}"
# VNC is OFF by default. Set ENABLE_VNC=1 to share the virtual screen so you
# can view it from another machine (e.g. a VNC viewer on Windows when the
# Docker host is a headless Ubuntu Server VM).
ENABLE_VNC="${ENABLE_VNC:-0}"
VNC_PORT="${VNC_PORT:-5900}"
VNC_PASSWORD="${VNC_PASSWORD:-}"

echo "=========================================================="
echo " arch-linux-kiosk"
echo "   app dir : $APP_DIR"
echo "   user    : $(whoami)"
echo "=========================================================="

# -----------------------------------------------------------------------------
# Step 1: obtain a display (monitor)
# -----------------------------------------------------------------------------
if [ -n "$DISPLAY" ]; then
  # A display was provided (e.g. -e DISPLAY=$DISPLAY from the host).
  # This means the window will appear on your REAL monitor via X11 forwarding.
  echo "[display] using provided DISPLAY=$DISPLAY (host monitor / X11 forward)"
else
  # No display -> create a virtual one with Xvfb.
  export DISPLAY=":99"
  echo "[display] no DISPLAY set -> starting virtual framebuffer on $DISPLAY ($RESOLUTION)"
  Xvfb "$DISPLAY" -screen 0 "$RESOLUTION" -nolisten tcp +extension RANDR &
  XVFB_PID=$!
  # give the fake screen a moment to come up
  for i in $(seq 1 10); do
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
    sleep 0.3
  done

  # -----------------------------------------------------------------
  # Optional VNC server: lets you SEE the virtual framebuffer from
  # another machine (e.g. a VNC viewer on your Windows host when this
  # container runs inside a headless Ubuntu Server VM).
  # -----------------------------------------------------------------
  if [ "$ENABLE_VNC" = "1" ]; then
    [ -n "$VNC_PASSWORD" ] || { echo '[vnc] VNC_PASSWORD must be set when ENABLE_VNC=1' >&2; exit 1; }
    echo "[vnc] ENABLE_VNC=1 -> starting x11vnc on port $VNC_PORT"
    echo '[vnc]   password : configured'
    echo "[vnc]   connect  : <this-host-ip>:$VNC_PORT"
    # -forever     keep serving after the first client disconnects
    # -shared      allow multiple viewers
    # -rfbport     TCP port to listen on
    # -passwd      simple password auth
    x11vnc -display "$DISPLAY" -forever -shared -noxdamage \
           -rfbport "$VNC_PORT" -passwd "$VNC_PASSWORD" \
           -bg -o /tmp/x11vnc.log -quiet
  fi
fi

# Quick input device report (keyboard/mouse via libinput).
echo "[input] detected input devices:"
xinput list 2>/dev/null || echo "  (xinput not available or no devices listed)"

# -----------------------------------------------------------------------------
# Step 2: locate the Electron app executable
# -----------------------------------------------------------------------------
find_exec() {
  # If the user told us exactly what to run, trust them.
  if [ -n "$APP_EXEC" ] && [ -x "$APP_EXEC" ]; then
    echo "$APP_EXEC"
    return
  fi

  # Prefer the user-supplied APP_EXEC even if it needs a chmod.
  if [ -n "$APP_EXEC" ] && [ -f "$APP_EXEC" ]; then
    chmod +x "$APP_EXEC" 2>/dev/null || true
    echo "$APP_EXEC"
    return
  fi

  # Auto-detect across common Electron export layouts:
  local candidates=(
    # 1. A single AppImage in the app folder
    "$APP_DIR"/*.AppImage
    # 2. electron-builder "linux-unpacked/<AppName>" binary
    "$APP_DIR"/linux-unpacked/*
    # 3. A folder whose name matches an executable inside it
    "$APP_DIR"/*/*
    # 4. Anything executable directly in the app folder
    "$APP_DIR"/*
  )

  for pattern in "${candidates[@]}"; do
    for cand in $pattern; do
      [ -e "$cand" ] || continue
      if [ -f "$cand" ] && [ ! -d "$cand" ]; then
        # make sure it is executable
        chmod +x "$cand" 2>/dev/null || true
        if [ -x "$cand" ]; then
          echo "$cand"
          return
        fi
      fi
    done
  done
}

APP_BIN="$(find_exec)"

# -----------------------------------------------------------------------------
# Step 3: launch (or wait, if nothing was found)
# -----------------------------------------------------------------------------
launch_app() {
  local target="$1"
  # AppImages need extracting inside a container (no /dev/fuse by default).
  if [[ "$target" == *.AppImage ]]; then
    echo "[launch] AppImage detected -> using --appimage-extract-and-run"
    exec "$target" --appimage-extract-and-run --no-sandbox --disable-gpu $APP_ARGS "$@"
  else
    exec "$target" --no-sandbox --disable-gpu $APP_ARGS "$@"
  fi
}

if [ -n "$APP_BIN" ]; then
  echo "[launch] starting Electron app: $APP_BIN"
  launch_app "$APP_BIN"
else
  cat <<EOF
[launch] No executable Electron app was found in: $APP_DIR

  How to fix:
    * Mount your exported app into the container, e.g.:
        -v /path/to/your-electron-export:/home/appuser/app
    * OR set APP_EXEC to the exact binary, e.g.:
        -e APP_EXEC=/home/appuser/app/my-app

  Keeping the container alive so you can inspect it:
      docker exec -it <container> bash
EOF
  # Stay alive so you can `docker exec` in and look around.
  exec sleep infinity
fi
