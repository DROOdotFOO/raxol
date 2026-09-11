#!/usr/bin/env bash
set -euo pipefail

# Post-deploy smoke test for raxol.io
HOST="${1:-https://raxol.io}"

pass=0
fail=0

check() {
  local path="$1"
  local expect="${2:-200}"
  local url="${HOST}${path}"
  local status

  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

  if [ "$status" = "$expect" ]; then
    printf "  [ok]   %s -> %s\n" "$path" "$status"
    pass=$((pass + 1))
  else
    printf "  [FAIL] %s -> %s (expected %s)\n" "$path" "$status" "$expect"
    fail=$((fail + 1))
  fi
}

printf "Smoke testing %s\n\n" "$HOST"

check "/health"
check "/"
check "/playground"
check "/demos" "301"
check "/gallery"

printf "\nResults: %d passed, %d failed\n" "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
