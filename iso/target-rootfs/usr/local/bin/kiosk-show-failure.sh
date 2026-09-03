#!/bin/bash
# =============================================================================
# kiosk-show-failure.sh — displays full kiosk failure diagnostics on tty1.
#
# Triggered by kiosk-failure.service (OnFailure= from kiosk.service) after the
# kiosk exhausts its restart limit.  Runs as ROOT so it can write to /dev/tty1
# and read all log files regardless of ownership.
# =============================================================================
KIOSK_LOG=/home/appuser/.cache/kiosk.log
INSTALLER_LOG=/var/log/kiosk-installer.log
TTY=/dev/tty1
KIOSK_VERSION=$(cat /etc/kiosk-version 2>/dev/null || echo 'unknown')

exec 1>"$TTY" 2>"$TTY"
clear 2>/dev/null || printf '\033[2J\033[H'

echo "============================================================"
echo "  Offline Kiosk — Kiosk Failed"
echo "  Version: $KIOSK_VERSION"
echo "  The kiosk could not start after multiple attempts."
echo "  Diagnostics are below. No login required."
echo "============================================================"
echo ""

echo "--- systemctl status kiosk.service ---"
systemctl status kiosk.service --no-pager 2>&1 || true
echo ""

echo "--- journalctl -u kiosk.service (last 80 lines) ---"
journalctl -u kiosk.service -n 80 --no-pager 2>&1 || echo "(no journal entries)"
echo ""

echo "--- Kiosk application log ($KIOSK_LOG) ---"
if [ -f "$KIOSK_LOG" ] && [ -s "$KIOSK_LOG" ]; then
    tail -80 "$KIOSK_LOG" 2>&1
else
    echo "(log file empty or missing — launch-electron.sh never reached the app exec)"
fi
echo ""

echo "--- Xorg log (latest) ---"
XORG_LOG=$(ls -t /var/log/Xorg.*.log 2>/dev/null | head -1)
if [ -n "$XORG_LOG" ] && [ -s "$XORG_LOG" ]; then
    echo "File: $XORG_LOG"
    tail -50 "$XORG_LOG" 2>&1
else
    echo "(no Xorg log found — Xorg may not have started)"
fi
echo ""

echo "--- Binary existence checks ---"
printf "  startx:           "
command -v startx >/dev/null 2>&1 && echo "YES ($(command -v startx))" || echo "NO — install xorg-xinit"
printf "  dbus-run-session: "
command -v dbus-run-session >/dev/null 2>&1 && echo "YES ($(command -v dbus-run-session))" || echo "NO — dbus package may be missing"
printf "  Xorg:             "
command -v Xorg >/dev/null 2>&1 && echo "YES ($(command -v Xorg))" || echo "NO — install xorg-server"
printf "  xrandr:           "
command -v xrandr >/dev/null 2>&1 && echo "YES" || echo "NO — install xrandr"
echo ""

echo "--- File existence checks ---"
printf "  /etc/kiosk.env:  "
[ -f /etc/kiosk.env ] && echo "YES" || echo "NO — kiosk.service cannot start without this!"
printf "  /home/appuser/.Xauthority:  "
if [ -f /home/appuser/.Xauthority ]; then
    ls -la /home/appuser/.Xauthority 2>&1
else
    echo "MISSING"
fi
printf "  /run/kiosk:      "
if [ -d /run/kiosk ]; then
    ls -ld /run/kiosk 2>&1
else
    echo "MISSING — RuntimeDirectory= did not create it"
fi
echo ""

echo "--- Electron app bundle (/opt/electron-app) ---"
if [ -d /opt/electron-app ]; then
    echo "  Directory exists."
    echo "  Contents (top level):"
    ls -la /opt/electron-app/ 2>&1 | head -20
    echo ""
    APP_EXEC=$(find /opt/electron-app -maxdepth 2 -type f -perm /111 \
        ! -name 'lib*.so' ! -name 'lib*.so.*' \
        ! -name 'chrome-sandbox' ! -name 'chrome_crashpad_handler' -print -quit 2>/dev/null)
    if [ -n "$APP_EXEC" ]; then
        echo "  Found executable: $APP_EXEC"
        file "$APP_EXEC" 2>&1
    else
        echo "  NO EXECUTABLE FOUND — the app bundle has no runnable binary"
    fi
else
    echo "  /opt/electron-app does not exist — app was not installed"
fi
echo ""

echo "--- appuser account ---"
id appuser 2>&1 || echo "appuser does not exist"
echo ""

echo "--- D-Bus system daemon ---"
systemctl is-active dbus 2>&1 || true
echo ""

echo "--- Display / GPU devices ---"
if [ -d /dev/dri ]; then
    ls -la /dev/dri/ 2>&1
else
    echo "  /dev/dri does not exist — no GPU devices (software rendering will be used)"
fi
echo ""

echo "============================================================"
echo "  End of diagnostics."
echo "  Press Ctrl+Alt+Del to reboot."
echo "============================================================"
