#!/usr/bin/env bash
# =============================================================================
# test-dockerfile-builder.sh — verify the Docker builder image configuration
# is correct and complete.
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

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s: %s\n' "$RED" "$NC" "$*"; }

builder_dockerfile="$ISO_DIR/Dockerfile.builder"

if [[ ! -f "$builder_dockerfile" ]]; then
  fail "Dockerfile.builder not found"
  printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
  exit 1
fi

printf '\n=== Dockerfile Structure ===\n'

# Must use a recent Arch Linux base
if grep -qE '^FROM archlinux:' "$builder_dockerfile"; then
  ok "Uses archlinux base image"
else
  fail "Missing or incorrect FROM archlinux: directive"
fi

# Must initialize pacman keyring
if grep -q 'pacman-key --init' "$builder_dockerfile"; then
  ok "Initializes pacman keyring"
else
  fail "Missing pacman-key --init (build will fail on fresh systems)"
fi

# Must populate Arch Linux signing keys
if grep -q 'pacman-key --populate archlinux' "$builder_dockerfile"; then
  ok "Populates Arch Linux signing keys"
else
  fail "Missing pacman-key --populate archlinux"
fi

# Must update system before installing packages
if grep -q 'pacman -Syu' "$builder_dockerfile"; then
  ok "Updates system before installing packages"
else
  warn "No 'pacman -Syu' — may install outdated package versions"
fi

printf '\n=== Required Build Tools ===\n'

required_tools=(
  "archiso:ISO build tooling"
  "arch-install-scripts:pacstrap, genfstab, arch-chroot"
  "gptfdisk:sgdisk for GPT partitioning"
  "dosfstools:mkfs.fat for ESP formatting"
  "e2fsprogs:mkfs.ext4 for root filesystem"
  "zstd:compression for target archive"
  "squashfs-tools:for ISO squashfs layers"
  "libisoburn:for ISO9660 generation"
  "mtools:for ISO MS-DOS label support"
  "file:for file type detection"
  "libarchive:bsdtar for archive extraction"
)

for entry in "${required_tools[@]}"; do
  pkg="${entry%%:*}"
  desc="${entry#*:}"
  if grep -q "$pkg" "$builder_dockerfile"; then
    ok "Has $pkg ($desc)"
  else
    fail "Missing $pkg — needed for: $desc"
  fi
done

printf '\n=== Security & Cleanup ===\n'

# Should use --noconfirm for non-interactive builds
if grep -qF -- '--noconfirm' "$builder_dockerfile"; then
  ok "Uses --noconfirm for non-interactive pacman"
else
  fail "Missing --noconfirm — build will hang waiting for input"
fi

# Should clean package cache to save space
if grep -q 'pacman -Sc' "$builder_dockerfile"; then
  ok "Cleans pacman package cache after install"
else
  warn "No 'pacman -Sc' — builder image may be larger than needed"
fi

# Must set entrypoint
if grep -q 'ENTRYPOINT' "$builder_dockerfile"; then
  ok "Has ENTRYPOINT defined"
else
  fail "Missing ENTRYPOINT — container won't run the build script"
fi

# Must COPY and chmod the build script
if grep -q 'COPY build-inside.sh' "$builder_dockerfile"; then
  ok "Copies build-inside.sh into image"
else
  fail "Missing COPY build-inside.sh"
fi

if grep -q 'chmod.*build-inside.sh' "$builder_dockerfile"; then
  ok "Makes build-inside.sh executable"
else
  fail "Missing chmod for build-inside.sh"
fi

printf '\n=== Docker Compose Checks ===\n'

compose_file="$PROJECT_DIR/docker-compose.yml"
if [[ -f "$compose_file" ]]; then
  if grep -q 'xhost' "$compose_file" || grep -q '/tmp/.X11-unix' "$compose_file"; then
    ok "Docker Compose has X11 socket mounting"
  else
    warn "Docker Compose may not support GUI passthrough"
  fi

  if grep -q '/dev/dri' "$compose_file"; then
    ok "Docker Compose has GPU device passthrough"
  else
    warn "Docker Compose missing /dev/dri passthrough"
  fi
else
  fail "docker-compose.yml not found"
fi

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sDOCKERFILE CHECK FAILED%s\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
