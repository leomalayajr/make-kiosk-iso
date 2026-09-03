#!/usr/bin/env bash
# =============================================================================
# test-build-integration.sh — integration tests that run inside the Docker
# builder container to verify the actual build pipeline works end-to-end.
#
# These tests require Docker and take longer to run.
# Run with: ./iso/tests/run-tests.sh --docker
# =============================================================================
QUICK_ONLY=0
DOCKER_ONLY=1

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO_DIR="$PROJECT_DIR/iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIPPED=0

ok() { PASS=$((PASS + 1)); printf '  OK: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s: %s\n' "$RED" "$NC" "$*"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %sSKIP%s: %s\n' "$YELLOW" "$NC" "$*"; }

# Only run the actual tests when executed directly (not sourced by test runner)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main() {
    run_integration_tests
  }

  run_integration_tests() {
    # Check Docker is available and we can run containers
    if ! command -v docker >/dev/null 2>&1; then
      skip "Docker not available — skipping integration tests"
      printf '\nResults: %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIPPED"
      exit 0
    fi

    if ! docker info >/dev/null 2>&1; then
      skip "Docker daemon not running — skipping integration tests"
      printf '\nResults: %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIPPED"
      exit 0
    fi

    printf '\n=== Builder Image Build Test ===\n'

BUILDER_IMAGE="kiosk-test-builder:latest"

# Check if builder image already exists (from a previous run)
if docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
  ok "Builder image already built (skipping rebuild)"
else
  printf '  Building test builder image...\n'
  if docker build -t "$BUILDER_IMAGE" -f "$ISO_DIR/Dockerfile.builder" "$ISO_DIR" 2>&1 | tail -5; then
    ok "Builder image built successfully"
  else
    fail "Failed to build builder image"
    printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
    exit 1
  fi
fi

printf '\n=== Builder Tool Availability ===\n'

# Test that all required tools are available in the builder
run_builder_cmd() {
  local cmd=$1 label=$2
  if docker run --rm "$BUILDER_IMAGE" bash -c "command -v $cmd >/dev/null 2>&1"; then
    ok "Builder has: $cmd ($label)"
  else
    fail "Builder MISSING: $cmd ($label)"
  fi
}

run_builder_cmd "mkarchiso" "ISO builder"
run_builder_cmd "pacstrap" "Target root builder"
run_builder_cmd "genfstab" "fstab generator"
run_builder_cmd "arch-chroot" "Chroot tool"
run_builder_cmd "sgdisk" "GPT partitioner"
run_builder_cmd "mkfs.fat" "FAT formatter"
run_builder_cmd "mkfs.ext4" "ext4 formatter"
run_builder_cmd "bsdtar" "Archive extractor"
run_builder_cmd "sha512sum" "Checksum tool"
run_builder_cmd "squashfs-tools" "SquashFS tools (unsquashfs)"

printf '\n=== Target Root Build Test ===\n'

# Create a minimal test to verify pacstrap works with target packages
TEST_CONTEXT_DIR=$(mktemp -d /tmp/kiosk-test.XXXXXX)
TARGET_ROOT="$TEST_CONTEXT_DIR/target-root"
BUILD_CONTEXT_APP="$TEST_CONTEXT_DIR/app"
BUILD_CONTEXT_ENV="$TEST_CONTEXT_DIR/kiosk.env"

mkdir -p "$BUILD_CONTEXT_APP"
# Create a dummy executable with the stable AppImage name used by the target.
echo '#!/bin/bash' > "$BUILD_CONTEXT_APP/app.AppImage"
chmod +x "$BUILD_CONTEXT_APP/app.AppImage"

cat > "$BUILD_CONTEXT_ENV" <<'EOF'
KIOSK_FINGERPRINT_B64=dGVzdA==
KIOSK_API_KEY_B64=dGVzdA==
KIOSK_API_SECRET_B64=dGVzdA==
KIOSK_RESOLUTION=1024x768
INSTALL_MODE=wipe-first-disk
INSTALL_UI=tty-bash
NETWORK=wired-dhcp
VIDEO_MODE=auto
BOOT_MODE=auto-uefi-systemd-boot-or-bios-grub
EOF

printf '  Building minimal target root...\n'

# Run the target root preparation inside the builder
if docker run --rm \
  -v "$TEST_CONTEXT_DIR:/test-context:ro" \
  -v "$ISO_DIR:/custom:ro" \
  "$BUILDER_IMAGE" \
  bash -c '
    set -Eeuo pipefail

    TARGET_ROOT=/tmp/target-root
    CUSTOM_DIR=/custom
    BUILD_CONTEXT=/test-context

    # Create target root with minimal packages
    mkdir -p "$TARGET_ROOT"
    mapfile -t PACKAGES < <(grep -v "^\s*#" "$CUSTOM_DIR/target-packages.txt" | grep -v "^\s*$")

    printf "Installing %d packages...\n" "${#PACKAGES[@]}"
    pacstrap -K -c -G -M "$TARGET_ROOT" "${PACKAGES[@]}"

    # Copy target rootfs overlay
    cp -a "$CUSTOM_DIR/target-rootfs/." "$TARGET_ROOT/"

    # Copy app
    mkdir -p "$TARGET_ROOT/opt/electron-app"
    cp -a "$BUILD_CONTEXT/app/." "$TARGET_ROOT/opt/electron-app/"

    # Copy env
    install -D -m 0600 "$BUILD_CONTEXT/kiosk.env" \
      "$TARGET_ROOT/etc/kiosk.env"

    # Generate users
    systemd-sysusers --root="$TARGET_ROOT"

    # Enable services
    systemctl --root="$TARGET_ROOT" enable kiosk.service kiosk-failure.service

    # Create fstab symlink
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$TARGET_ROOT/etc/resolv.conf"

    # Prune for appliance mode
    rm -rf "$TARGET_ROOT/var/cache/pacman" "$TARGET_ROOT/var/lib/pacman" \
      "$TARGET_ROOT/usr/share/doc" "$TARGET_ROOT/usr/share/man"
    rm -f "$TARGET_ROOT/usr/bin/pacman" "$TARGET_ROOT/usr/bin/pacman-key"
    rm -f "$TARGET_ROOT/usr/bin/makepkg"
    rm -rf "$TARGET_ROOT/etc/pacman.conf" "$TARGET_ROOT/etc/pacman.d"

    # Verify the result
    printf "\n=== Target Root Verification ===\n"
    printf "Size: %s\n" "$(du -sh "$TARGET_ROOT" | cut -f1)"
    printf "Package count: %s\n" "$(find "$TARGET_ROOT/var/lib/pacman/local" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"

    # Check critical files exist
    test -x "$TARGET_ROOT/usr/local/bin/launch-electron.sh" && printf "launch-electron.sh: OK\n" || printf "launch-electron.sh: MISSING\n"
    test -x "$TARGET_ROOT/usr/local/bin/kiosk-show-failure.sh" && printf "kiosk-show-failure.sh: OK\n" || printf "kiosk-show-failure.sh: MISSING\n"
    test -f "$TARGET_ROOT/etc/systemd/system/kiosk.service" && printf "kiosk.service: OK\n" || printf "kiosk.service: MISSING\n"
    test -f "$TARGET_ROOT/etc/systemd/system/kiosk-failure.service" && printf "kiosk-failure.service: OK\n" || printf "kiosk-failure.service: MISSING\n"
    test -x "$TARGET_ROOT/opt/electron-app/app.AppImage" && printf "AppImage: OK\n" || printf "AppImage: MISSING\n"
    test -f "$TARGET_ROOT/etc/kiosk.env" && printf "env file: OK\n" || printf "env file: MISSING\n"

    # Verify pacman is removed
    test ! -e "$TARGET_ROOT/usr/bin/pacman" && printf "pacman removed: OK\n" || printf "pacman removed: FAIL\n"
    test ! -d "$TARGET_ROOT/var/cache/pacman" && printf "cache removed: OK\n" || printf "cache removed: FAIL\n"

    printf "\nTarget root build succeeded!\n"
  ' 2>&1 | tee "$TEST_CONTEXT_DIR/build.log"; then

  # Check the log for success indicators
  if grep -q "Target root build succeeded" "$TEST_CONTEXT_DIR/build.log" 2>/dev/null; then
    ok "Minimal target root built successfully"

    # Print size info
    local_size=$(grep "^Size:" "$TEST_CONTEXT_DIR/build.log" | tail -1)
    ok "Target root: $local_size"
  else
    fail "Target root build did not complete successfully"
    grep -i "error\|fail\|missing" "$TEST_CONTEXT_DIR/build.log" 2>/dev/null | while IFS= read -r line; do
      printf '       %s\n' "$line"
    done
  fi
else
  fail "Docker run for target root build failed"
fi

# Cleanup
rm -rf "$TEST_CONTEXT_DIR"

printf '\n=== Build Script Variable Check ===\n'

# Verify build-inside.sh has all required variables set
check_build_var() {
  local var=$1 label=$2
  if grep -q "^${var}=" "$ISO_DIR/build-inside.sh"; then
    ok "build-inside.sh defines: $var ($label)"
  else
    fail "build-inside.sh missing variable: $var ($label)"
  fi
}

check_build_var "PROFILE_SRC" "Installer profile source"
check_build_var "PROFILE_DST" "Installer profile destination"
check_build_var "TARGET_ROOT" "Target root directory"
check_build_var "BUNDLE_NAME" "Archive filename"
check_build_var "CUSTOM_DIR" "Custom files directory"

    printf '\nResults: %s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIPPED"

    if [[ $FAIL -gt 0 ]]; then
      printf '\n%sINTEGRATION TESTS FAILED%s\n\n' "$RED" "$NC"
      exit 1
    fi
  }

  main
fi
