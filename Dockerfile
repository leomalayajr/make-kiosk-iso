# =============================================================================
# arch-linux-kiosk
# A single Arch Linux image that boots straight into an Electron.js app.
#   - Real Arch Linux base (NOT Ubuntu/Debian)
#   - Minimal keyboard / mouse / monitor support (Xorg + libinput)
#   - Runs an exported / packaged Electron app automatically on container start
#   - Internet access (default Docker bridge network + full DNS)
# =============================================================================

FROM archlinux:latest

LABEL org.opencontainers.image.title="arch-linux-kiosk" \
      org.opencontainers.image.description="Arch Linux image that auto-launches an Electron.js export" \
      org.opencontainers.image.source="https://github.com/"

# -----------------------------------------------------------------------------
# 1) Refresh the whole system and install only what we need.
#    Grouped + commented so you can trim it later.
#
#    Display / monitor (very minimal):
#      xorg-server         -> the X display server
#      xorg-xinit          -> startx (handy for real-monitor mode)
#      xorg-server-xvfb    -> virtual framebuffer (a "fake monitor" when no
#                             real screen is attached -> works everywhere)
#      xorg-xrandr         -> set resolution
#
#    Keyboard / mouse:
#      xf86-input-libinput -> single modern driver for keyboard, mouse,
#                             touchpad, touchscreen (replaces the old split
#                             -keyboard/-mouse drivers)
#      xorg-xinput         -> list / test input devices
#
#    Fonts (so text actually renders):
#      ttf-dejavu
#
#    Graphics stack Electron needs:
#      mesa libdrm glu
#
#    Remote viewing (so you can SEE the virtual screen from Windows when the
#    host is headless, e.g. an Ubuntu Server VM under VMware Player):
#      x11vnc              -> VNC server that shares the Xvfb virtual screen
#      xorg-xauth          -> X authorization for VNC connections
#
#    Electron / Chromium runtime libraries:
#      nss at-spi2-core libcups libxcomposite libxdamage
#      libxrandr libxfixes libxkbcommon libxss libxtst pango cairo
#      gdk-pixbuf2 alsa-lib
#    (Note: Arch merged the old `atk` and `at-spi2-atk` packages into
#     `at-spi2-core`; `libxscrnsaver` is now `libxss`.)
#
#    System / internet plumbing:
#      dbus ca-certificates openssh sudo bash coreutils which findutils
#      procps-ng iproute2 iputils
#
#    pacman -Scc wipes the package cache so the image stays small.
# -----------------------------------------------------------------------------
# Initialize the pacman keyring FIRST. The archlinux:latest image sometimes
# ships with an uninitialized keyring, which makes `pacman -Syu` fail with:
#   "There is no secret key available to sign with."
# `pacman-key --init` + `--populate archlinux` generates the signing key and
# loads the official Arch Linux keys before we touch any package.
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
      xorg-server xorg-xinit xorg-server-xvfb xorg-xrandr \
      xf86-input-libinput xorg-xinput \
      ttf-dejavu \
      mesa libdrm glu \
      x11vnc xorg-xauth \
      nss at-spi2-core \
      libcups libxcomposite libxdamage \
      libxrandr libxfixes libxkbcommon \
      libxss libxtst \
      pango cairo gdk-pixbuf2 \
      alsa-lib \
      dbus \
      ca-certificates openssh \
      sudo bash coreutils which findutils procps-ng \
      iproute2 iputils \
    && pacman -Scc --noconfirm

# -----------------------------------------------------------------------------
# 2) Create a non-root user.
#    Electron/Chromium refuses to run as root without --no-sandbox and it is
#    bad practice anyway. We add the user to video/input/render groups so it
#    can reach the GPU and input devices when you pass them through.
# -----------------------------------------------------------------------------
RUN useradd -m -G video,input,render,wheel -s /bin/bash appuser && \
    # Passwordless sudo for appuser (handy in a throwaway container, e.g. to
    # `sudo pacman -S` extra packages at runtime). Safe because the container
    # is ephemeral; remove this line for stricter setups.
    echo "appuser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# /app is where you mount (or COPY) your exported Electron app.
WORKDIR /home/appuser/app

# -----------------------------------------------------------------------------
# 3) Entrypoint: detects a real display vs. none, then launches the app.
# -----------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER appuser
ENV HOME=/home/appuser \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    # Default: empty -> the entrypoint will spin up a virtual framebuffer.
    # To use your REAL monitor instead, pass -e DISPLAY=$DISPLAY when running
    # and mount the host X socket (see GUIDE.md).
    DISPLAY= \
    # Path/flag overrides (see entrypoint.sh). Leave empty for auto-detect.
    APP_EXEC= \
    APP_ARGS= \
    RESOLUTION=1280x720x24 \
    # VNC off by default; set ENABLE_VNC=1 to view the virtual screen remotely
    # (e.g. from a VNC viewer on Windows when the host is a headless server).
    ENABLE_VNC=0 \
    VNC_PORT=5900 \
    VNC_PASSWORD=

# VNC port (only used when ENABLE_VNC=1). With --network host this is just
# documentation; with bridge networking Docker maps it via -p 5900:5900.
EXPOSE 5900

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
