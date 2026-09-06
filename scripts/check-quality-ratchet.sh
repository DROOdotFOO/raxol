#!/usr/bin/env bash
#
# Quality ratchet. Compares current gate counts against the checked-in
# baseline in priv/quality_baseline.json and fails only when a count has
# INCREASED. Lowering a count is always allowed; run with --update to record
# the improvement.
#
# Why a ratchet and not a pass/fail bar: the gates are not clean, and pinning
# them to zero would mean either a permanently red pipeline or the `|| true`
# suppression this script exists to replace. A ratchet makes the trend
# enforceable without a big-bang cleanup.
#
# Why the counts live here and not in AGENTS.md: a number in prose has nothing
# validating it. The previous AGENTS.md claimed "Credo strict: 0 issues,
# Dialyzer clean" while credo reported 1187 and dialyzer 127, because CI had
# `continue-on-error: true` AND `|| true` on both, and the status gate never
# read either result. This file is machine-owned and machine-updated.
#
# Runtime warning: `credo` takes ~60 min repo-wide, because a single pass is
# the only option -- `mix credo <path>` silently analyzes nothing against the
# root config (verified: exit 0, zero findings, for `lib`, `lib/`, and
# `packages/raxol_core/lib/`), so the scan cannot be sharded by path from here.
# Run this nightly, not per-PR. Per-PR sharding needs a `.credo.exs` inside
# each package so `cd packages/<pkg> && mix credo` uses that package's own
# config; only raxol_agent_client_protocol has one today.
set -uo pipefail

BASELINE=priv/quality_baseline.json
UPDATE=0
GATES=""

usage() {
  echo "usage: $0 [--update] [--gate credo|dialyzer]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1; shift ;;
    --gate) GATES="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ -f "$BASELINE" ] || { echo "missing $BASELINE" >&2; exit 1; }

want() {
  [ -z "$GATES" ] && return 0
  [ "$GATES" = "$1" ]
}

baseline_of() {
  jq -r --arg g "$1" '.gates[$g].count' "$BASELINE"
}

fail=0
declare -a results=()

if want credo; then
  echo "==> credo --strict (repo-wide, ~60 min)" >&2
  count=$(mix credo --strict --format flycheck 2>/dev/null \
            | grep -cE ':[0-9]+.*: [FRWDC]: ')
  results+=("credo:$count")
fi

if want dialyzer; then
  # Refuse to report a dialyzer count against a PLT older than the
  # packages/ sources. dialyxir keys its deps PLT off the deps hash, which a
  # path-dependency change does not move, so editing or ADDING a module under
  # packages/ leaves the PLT describing the old code. Observed twice: a fix
  # removing 16 callback_type_mismatch errors read as a no-op across two full
  # runs, and a newly added raxol_core module was reported as
  # `unknown_function ... does not exist`. Both were PLT artifacts, not code
  # defects, and both would have been silently trusted.
  plt=$(find priv/plts -name '*_deps-dev.plt' -print -quit 2>/dev/null)
  if [ -n "$plt" ]; then
    # Only packages/*/lib -- those are the beams that enter the PLT. Test
    # fixtures and test support under packages/*/test do not.
    stale=$(find packages/*/lib -name '*.ex' -newer "$plt" -print -quit 2>/dev/null)
    if [ -n "$stale" ]; then
      echo "FAIL dialyzer: PLT $plt is older than $stale" >&2
      echo "  dialyxir will not rebuild it -- the deps hash has not moved." >&2
      echo "  rm priv/plts/local.plt/*_deps-dev.plt*  then re-run." >&2
      exit 1
    fi
  fi

  echo "==> dialyzer" >&2
  # Count the findings dialyzer actually emits, NOT its "Total errors:" line.
  # That line is the raw count BEFORE .dialyzer_ignore.exs is applied: adding
  # 11 documented suppressions moved "Skipped: 5" to "Skipped: 16" and left
  # "Total errors: 113" unchanged, so a ratchet reading it cannot see a
  # suppression land and would compare pre-filter numbers against a
  # post-filter baseline.
  #
  # Strip ANSI first: dialyxir colorizes findings even when stdout is not a
  # tty, so the leading path would otherwise be preceded by escape codes.
  # 2>&1, not 2>/dev/null: dialyxir writes its findings to STDERR. Discarding
  # stderr yields a count of zero, which the ratchet would read as a perfect
  # score. Compile noise is also on stderr but its file references are
  # indented ("  └─ lib/foo.ex:12: ..."), so the anchored pattern skips them.
  count=$(mix dialyzer --format short 2>&1 \
            | sed -E 's/\x1b\[[0-9;]*m//g' \
            | grep -cE '^(lib|packages|web)/.*\.ex:')
  [ -n "$count" ] || { echo "could not count dialyzer findings" >&2; exit 1; }
  results+=("dialyzer:$count")
fi

[ ${#results[@]} -gt 0 ] || { echo "no gates selected" >&2; usage; }

for r in "${results[@]}"; do
  gate=${r%%:*}
  count=${r##*:}
  base=$(baseline_of "$gate")

  if [ "$base" = "null" ]; then
    echo "FAIL $gate: no baseline recorded; run --update to seed it" >&2
    fail=1
  elif [ "$count" -gt "$base" ]; then
    echo "FAIL $gate: $count > baseline $base (+$((count - base)))" >&2
    fail=1
  elif [ "$count" -lt "$base" ]; then
    echo "IMPROVED $gate: $count < baseline $base (-$((base - count)))" >&2
    echo "         run '$0 --update' to lock in the improvement" >&2
  else
    echo "OK $gate: $count (baseline $base)" >&2
  fi
done

if [ "$UPDATE" = 1 ]; then
  tmp=$(mktemp)
  cp "$BASELINE" "$tmp"
  for r in "${results[@]}"; do
    gate=${r%%:*}
    count=${r##*:}
    jq --arg g "$gate" --argjson c "$count" \
       --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg sha "$(git rev-parse --short HEAD)" \
       '.gates[$g].count = $c
        | .gates[$g].measured_at = $d
        | .gates[$g].measured_at_sha = $sha' "$tmp" > "$tmp.next"
    mv "$tmp.next" "$tmp"
  done
  mv "$tmp" "$BASELINE"
  echo "updated $BASELINE" >&2
  exit 0
fi

exit $fail
