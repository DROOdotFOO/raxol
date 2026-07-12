#!/usr/bin/env bash
#
# CI guard: fail if any new file registers `name: __MODULE__` for a
# GenServer/Agent/Supervisor without being in the allowlist.
#
# See docs/core/SINGLETONS.md for the policy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/.singletons-allowlist"

if [[ ! -f "$ALLOWLIST" ]]; then
  printf 'allowlist not found at %s\n' "$ALLOWLIST" >&2
  exit 2
fi

# Match real start_link calls. The call must be at line start modulo whitespace,
# with an optional `case ` or `{...} =`/`{...} <-` binding prefix so idempotent
# wrappers still register -- this skips comment lines like
# "# Usage: ... start_link(name: __MODULE__)".
pattern='^[[:space:]]*(case[[:space:]]+|\{[^}]*\}[[:space:]]*[=<-]+[[:space:]]*)?(GenServer|Agent|Supervisor|DynamicSupervisor)\.start_link.*name: __MODULE__'

# First-party paths only -- skip vendored deps and _build.
roots=(
  lib
  packages/raxol_core/lib
  packages/raxol_terminal/lib
  packages/raxol_agent/lib
  packages/raxol_mcp/lib
  packages/raxol_liveview/lib
  packages/raxol_plugin/lib
  packages/raxol_speech/lib
  packages/raxol_telegram/lib
  packages/raxol_watch/lib
  packages/raxol_payments/lib
  packages/raxol_sensor/lib
  packages/raxol_symphony/lib
)

# Discover current registrations (file paths, deduped, sorted) into a tmpfile.
found_file=$(mktemp)
allowed_file=$(mktemp)
trap 'rm -f "$found_file" "$allowed_file"' EXIT

cd "$REPO_ROOT"
for root in "${roots[@]}"; do
  [[ -d "$root" ]] || continue
  grep -rlE "$pattern" "$root" 2>/dev/null || true
done | sort -u >"$found_file"

grep -vE '^\s*(#|$)' "$ALLOWLIST" | sort -u >"$allowed_file"

# Lines in found not in allowed -- new unauthorized registrations.
unexpected=$(comm -23 "$found_file" "$allowed_file")

if [[ -n "$unexpected" ]]; then
  printf 'ERROR: new singleton-registering files not in allowlist:\n\n' >&2
  printf '%s\n' "$unexpected" >&2
  printf '\nIf intentional, add the path to %s and document the reasoning\n' "$ALLOWLIST" >&2
  printf 'in docs/core/SINGLETONS.md. If the process is per-instance, accept\n' >&2
  printf '[name: nil] from the caller instead of hardcoding name: __MODULE__.\n' >&2
  exit 1
fi

# Lines in allowed not in found -- stale entries (file deleted/renamed).
stale=$(comm -13 "$found_file" "$allowed_file")

if [[ -n "$stale" ]]; then
  printf 'WARNING: allowlist entries no longer match any source file:\n\n' >&2
  printf '%s\n' "$stale" >&2
  printf '\nRemove these from %s and update docs/core/SINGLETONS.md.\n' "$ALLOWLIST" >&2
  exit 1
fi

count=$(wc -l <"$found_file" | tr -d ' ')
printf 'singletons: %s allowed registrations, all accounted for.\n' "$count"
