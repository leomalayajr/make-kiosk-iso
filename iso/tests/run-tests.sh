#!/usr/bin/env bash
# =============================================================================
# run-tests.sh — entry point for the Offline Kiosk test suite.
#
# Usage:
#   ./iso/tests/run-tests.sh              # run all tests
#   ./iso/tests/run-tests.sh --quick      # run only quick (non-Docker) tests
#   ./iso/tests/run-tests.sh --docker     # run Docker-dependent tests
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
QUICK_ONLY=0
DOCKER_ONLY=0

run_one_test() {
  local test_file=$1
  local label
  label=$(basename "$test_file" .sh)
  TOTAL=$((TOTAL + 1))

  # Source test file to read QUICK_ONLY / DOCKER_ONLY flags
  local file_docker=0
  (
    QUICK_ONLY=0
    DOCKER_ONLY=0
    source "$test_file" || {
      FAILED=$((FAILED + 1))
      printf '  %sFAIL%s [%s] — script error\n' "$RED" "$NC" "$label"
      return
    }
    printf '%s\n' "$DOCKER_ONLY"
  ) > /tmp/kiosk-test-flags.$$ 2>/dev/null
  read -r file_docker < /tmp/kiosk-test-flags.$$
  rm -f /tmp/kiosk-test-flags.$$

  if [[ $file_docker -eq 1 && $QUICK_ONLY -eq 1 ]]; then
    # Docker-dependent test, skipped in --quick mode
    SKIPPED=$((SKIPPED + 1))
    printf '  %sSKIP%s [%s] (skipped with --quick)\n' "$YELLOW" "$NC" "$label"
    return
  fi

  if [[ $file_docker -eq 1 ]]; then
    # Docker test — check if Docker is available
    if ! command -v docker >/dev/null 2>&1; then
      SKIPPED=$((SKIPPED + 1))
      printf '  %sSKIP%s [%s] (no Docker)\n' "$YELLOW" "$NC" "$label"
      return
    fi
  fi

  # Run the actual test file with bash
  if declare -f run_test >/dev/null 2>&1 || [[ $file_docker -eq 0 ]]; then
    local start_time
    start_time=$(date +%s)
    if bash "$test_file"; then
      local elapsed=$(( $(date +%s) - start_time ))
      PASSED=$((PASSED + 1))
      printf '  %sPASS%s [%s] (%ds)\n' "$GREEN" "$NC" "$label" "$elapsed"
    else
      local elapsed=$(( $(date +%s) - start_time ))
      FAILED=$((FAILED + 1))
      printf '  %sFAIL%s [%s] (%ds)\n' "$RED" "$NC" "$label" "$elapsed"
    fi
  fi
}

# Parse args
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK_ONLY=1 ;;
    --docker) DOCKER_ONLY=1 ;;
    --help|-h)
      echo "Usage: $0 [--quick|--docker]"
      echo "  --quick   Run only quick (non-Docker) tests"
      echo "  --docker  Run Docker-dependent tests"
      exit 0
      ;;
  esac
done

printf '\n%sOffline Kiosk Test Suite%s\n' "$CYAN" "$NC"
printf 'Project: %s\n' "$PROJECT_DIR"
printf 'Date:    %s\n' "$(date -Is)"
printf '%s\n' "----------------------------------------"

# Collect test files
shopt -s nullglob
test_files=("$TESTS_DIR"/test-*.sh)
shopt -u nullglob

if [[ ${#test_files[@]} -eq 0 ]]; then
  printf '\n%sNo test files found in %s%s\n' "$RED" "$TESTS_DIR" "$NC"
  exit 1
fi

for tf in "${test_files[@]}"; do
  run_one_test "$tf"
done

printf '%s\n' "----------------------------------------"
printf 'Results: %s/%s passed, %s failed, %s skipped\n' "$PASSED" "$TOTAL" "$FAILED" "$SKIPPED"

if [[ $FAILED -gt 0 ]]; then
  printf '\n%sSOME TESTS FAILED%s\n\n' "$RED" "$NC"
  exit 1
elif [[ $SKIPPED -gt 0 && $PASSED -eq 0 ]]; then
  printf '\n%sALL TESTS SKIPPED (no Docker?)%s\n\n' "$YELLOW" "$NC"
  exit 1
else
  printf '\n%sALL TESTS PASSED%s\n\n' "$GREEN" "$NC"
  exit 0
fi
