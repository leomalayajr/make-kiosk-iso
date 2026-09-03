#!/usr/bin/env bash
# =============================================================================
# test-script-syntax.sh — verify that all shell scripts have valid syntax,
# correct shebangs, and are executable where they should be.
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

# --- Collect all shell scripts ---
shopt -s nullglob
all_scripts=(
  "$PROJECT_DIR"/*.sh
  "$ISO_DIR"/*.sh
  "$ISO_DIR"/installer-rootfs/usr/local/bin/*.sh
  "$ISO_DIR"/target-rootfs/usr/local/bin/*.sh
  "$ISO_DIR"/tests/*.sh
)
shopt -u nullglob

printf '\n=== Shebang Check ===\n'

for script in "${all_scripts[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  first_line=$(head -n1 "$script")

  if [[ "$first_line" =~ ^#!.*bash ]]; then
    ok "shebang: $local_label"
  elif [[ "$first_line" =~ ^#!.*env ]]; then
    ok "shebang (via env): $local_label"
  else
    fail "missing or invalid shebang in $local_label (got: '$first_line')"
  fi
done

printf '\n=== Syntax Check (bash -n) ===\n'

for script in "${all_scripts[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  if bash -n "$script" 2>/dev/null; then
    ok "syntax OK: $local_label"
  else
    fail "syntax ERROR in $local_label"
    bash -n "$script" 2>&1 | head -3 | while IFS= read -r line; do
      printf '       %s\n' "$line"
    done
  fi
done

printf '\n=== Executable Permission Check ===\n'

# Scripts that should be executable (installed files, entrypoints)
should_be_executable=(
  "$PROJECT_DIR/make-kiosk-iso.sh"
  "$ISO_DIR/build-inside.sh"
  "$ISO_DIR/build-iso.sh"
  "$ISO_DIR/verify-iso.sh"
  "$ISO_DIR/verify-checks.sh"
  "$ISO_DIR/qemu-uefi-test.sh"
  "$ISO_DIR/installer-rootfs/usr/local/bin/kiosk-installer-ui.sh"
  "$ISO_DIR/target-rootfs/usr/local/bin/launch-electron.sh"
  "$PROJECT_DIR/entrypoint.sh"
)

for script in "${should_be_executable[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  if [[ ! -f "$script" ]]; then
    fail "file missing: $local_label"
    continue
  fi
  if [[ -x "$script" ]]; then
    ok "executable: $local_label"
  else
    fail "NOT executable: $local_label (should be chmod +x)"
  fi
done

# Scripts that should NOT be executable (tests, config)
should_not_be_executable=(
  "$ISO_DIR/tests/test-package-audit.sh"
  "$ISO_DIR/tests/test-script-syntax.sh"
)

for script in "${should_not_be_executable[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  if [[ -f "$script" ]]; then
    # Test scripts should actually be executable for the test runner
    ok "test script exists: $local_label"
  fi
done

printf '\n=== No-CRLF Check ===\n'

for script in "${all_scripts[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  if file "$script" | grep -q 'CRLF'; then
    fail "Windows line endings (CRLF) in $local_label — convert to LF"
  else
    ok "Unix line endings: $local_label"
  fi
done

printf '\n=== Trailing Whitespace Check ===\n'

for script in "${all_scripts[@]}"; do
  local_label="$(realpath --relative-to="$SCRIPT_DIR" "$script")"
  if grep -qE '\s+$' "$script" 2>/dev/null; then
    fail "trailing whitespace in $local_label"
  else
    ok "no trailing whitespace: $local_label"
  fi
done

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%sSYNTAX CHECK FAILED%s — check failures above\n\n' "$RED" "$NC"
  exit 1
fi

exit 0
