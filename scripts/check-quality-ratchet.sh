#!/usr/bin/env bash
#
# Quality ratchet. Compares current gate counts against the checked-in
# baseline in priv/quality_baseline.json and fails when a count has
# INCREASED. Lowering a count is always allowed; run with --update to record
# the improvement.
#
# Why a ratchet and not a pass/fail bar: the gates are not clean, and pinning
# them to zero would mean either a permanently red pipeline or the `|| true`
# suppression this script exists to replace. A ratchet makes the trend
# enforceable without a big-bang cleanup.
#
# Why the counts live here and not in prose: a number in prose has nothing
# validating it. This file is machine-owned and machine-updated.
#
# ---------------------------------------------------------------------------
# MEASUREMENT INTEGRITY
# ---------------------------------------------------------------------------
# A ratchet is only as good as its ability to tell "the tool ran and found N"
# apart from "the tool did not run". Getting that wrong makes the gate PASS on
# a broken build, which is strictly worse than no gate. Three separate bugs of
# exactly that shape were found in earlier revisions of this script:
#
#   1. `mix dialyzer ... 2>/dev/null | grep -c` -- dialyxir writes findings to
#      STDERR, so the count was always 0 and every run read as a perfect score.
#   2. Baselining dialyxir's "Total errors:" line, which is the count BEFORE
#      .dialyzer_ignore.exs is applied, so a landed suppression was invisible.
#   3. `grep -c` emits "0" and exits 1 when nothing matches. With no `set -e`,
#      a crashed/OOM/compile-failed tool produced count=0 -> "IMPROVED" ->
#      exit 0 on a blocking gate.
#
# The rule that prevents all three: EVERY gate must extract its count from a
# COMPLETION MARKER that only a finished run can produce, and must abort if
# that marker is absent. Never infer a count from the absence of output.
#
#   * credo    -> `--format json`; the marker is a parseable document with an
#                 `.issues` array. Count = array length. A crash yields
#                 unparseable output, not an empty array.
#   * dialyzer -> the "Total errors: N, Skipped: M" summary line. Count =
#                 N - M, which equals the findings actually emitted after the
#                 ignore file (verified: 127-5=122, 111-5=106, 113-16=97).
#                 Absence of the line means the run did not finish.
#
# Runtime: credo takes ~60 min repo-wide. `mix credo <path>` analyzes nothing
# against the root .credo.exs (verified: exit 0, zero findings, for `lib`,
# `lib/` and `packages/raxol_core/lib/`), so the scan cannot be sharded by
# path and must run as one pass. Run it nightly, not per-PR. Per-PR sharding
# needs a `.credo.exs` inside each package so `cd packages/<pkg> && mix credo`
# uses that package's own config; only raxol_agent_client_protocol has one.
set -uo pipefail

BASELINE=priv/quality_baseline.json
# Records the packages/ content hash the PLT was built against. See
# ensure_fresh_plt below for why mtime cannot be used.
PLT_STAMP=priv/plts/.packages-content-hash

UPDATE=0
ALLOW_REGRESSION=0
GATES=""
TMPDIR_SELF=""

cleanup() {
  [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"
}
trap cleanup EXIT INT TERM

usage() {
  cat >&2 <<'USAGE'
usage: check-quality-ratchet.sh [--gate credo|dialyzer] [--update] [--allow-regression]

  --gate G            run only gate G (default: all gates)
  --update            record the measured counts as the new baseline
  --allow-regression  permit --update to RAISE a count; refused otherwise
USAGE
  exit 2
}

die() {
  echo "FATAL: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1; shift ;;
    --allow-regression) ALLOW_REGRESSION=1; shift ;;
    --gate)
      [ $# -ge 2 ] || die "--gate needs a value"
      GATES="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

case "$GATES" in
  ""|credo|dialyzer) ;;
  *) die "unknown gate '$GATES' (expected credo or dialyzer)" ;;
esac

# Preflight. A missing tool must abort, never silently degrade: without jq,
# `baseline_of` returned the empty string, `[ "$count" -gt "" ]` errored, and
# the comparison chain fell through to the "OK" branch -- another false pass.
for tool in jq mix; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not on PATH"
done
[ -f "$BASELINE" ] || die "missing $BASELINE"
jq -e '.gates' "$BASELINE" >/dev/null 2>&1 || die "$BASELINE is not valid JSON"

TMPDIR_SELF=$(mktemp -d) || die "could not create a temp dir"

want() {
  [ -z "$GATES" ] && return 0
  [ "$GATES" = "$1" ]
}

baseline_of() {
  jq -r --arg g "$1" '.gates[$g].count // "null"' "$BASELINE"
}

# Hash of every packages/*/lib source that can enter the PLT. Portable across
# macOS (shasum) and Linux CI (sha256sum).
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

packages_content_hash() {
  find packages/*/lib -name '*.ex' -type f -print0 2>/dev/null \
    | sort -z \
    | xargs -0 cat 2>/dev/null \
    | sha \
    | cut -d' ' -f1
}

# dialyxir keys its deps PLT off the DEPS HASH, which a path dependency does
# not move: editing or adding a module under packages/ leaves the PLT
# describing the old code, and dialyzer then reports against stale types. That
# produced two false readings -- a fix removing 16 callback_type_mismatch
# errors read as a no-op across two full runs, and a newly added raxol_core
# module was reported as "unknown_function ... does not exist".
#
# An earlier revision detected this by comparing mtimes. That is wrong in CI:
# actions/checkout writes every source file with mtime=now while actions/cache
# restores the PLT with its archived (older) mtime, so the check fired on
# EVERY warm-cache run and turned a blocking gate into an unconditional
# failure. Content hashing is order- and clock-independent, so it behaves the
# same locally and in CI.
#
# On mismatch we DISCARD the deps PLT and let the analysis run rebuild it. We
# deliberately do NOT call `mix dialyzer --plt` ourselves: doing so produced a
# deps PLT byte-for-byte the size of core.plt (1.98 MB vs the 11.8 MB of a
# populated one), and dialyxir then reported "PLT is up to date!" forever
# after because it keys freshness off a 20-byte `.plt.hash`. Analysing against
# that PLT yielded 2055 findings, 1845 of them `unknown_function` -- a
# fabricated regression from a broken cache, not from the code.
invalidate_stale_plt() {
  local current recorded env
  current=$(packages_content_hash)
  [ -n "$current" ] || die "could not hash packages/*/lib sources"

  recorded=""
  [ -f "$PLT_STAMP" ] && recorded=$(cat "$PLT_STAMP")

  if [ "$current" = "$recorded" ]; then
    echo "    PLT stamp matches packages/ content hash" >&2
    return 0
  fi

  if [ -n "$recorded" ]; then
    echo "    packages/ changed since the PLT was stamped; discarding it" >&2
  else
    echo "    no PLT content stamp; discarding the deps PLT to be safe" >&2
  fi

  env="${MIX_ENV:-dev}"
  rm -f "priv/plts/local.plt/"*"_deps-${env}.plt" \
        "priv/plts/local.plt/"*"_deps-${env}.plt.hash"
  rm -f "$PLT_STAMP"
}

# Written only after a measurement that passed the integrity checks, so a
# stamp always describes a PLT that produced a trustworthy count.
stamp_plt() {
  mkdir -p "$(dirname "$PLT_STAMP")"
  packages_content_hash > "$PLT_STAMP"
}

measure_credo() {
  local raw="$TMPDIR_SELF/credo.raw" out="$TMPDIR_SELF/credo.json"

  echo "==> credo --strict (repo-wide)" >&2
  # Exit status is deliberately ignored: credo exits nonzero BECAUSE it found
  # issues, which is the normal case here. The parseable document is the
  # completion marker instead.
  mix credo --strict --format json >"$raw" 2>"$TMPDIR_SELF/credo.err"

  # `--format json` is not pure JSON on stdout: mix compile lines ("==>
  # raxol_terminal", "make: Nothing to be done") and credo's own
  # "info: Some source files could not be parsed correctly" notice precede
  # the document. Take everything from the first line that is a bare `{`.
  sed -n '/^{/,$p' "$raw" > "$out"

  jq -e '.issues | type == "array"' "$out" >/dev/null 2>&1 || {
    echo "  credo produced no parseable JSON document -- the run did not" >&2
    echo "  complete. Last stdout/stderr lines:" >&2
    tail -5 "$raw" >&2
    tail -5 "$TMPDIR_SELF/credo.err" >&2
    die "refusing to report a credo count from an incomplete run"
  }

  jq '.issues | length' "$out"
}

measure_dialyzer() {
  local out="$TMPDIR_SELF/dialyzer.txt" clean="$TMPDIR_SELF/dialyzer.clean"
  local summary total skipped count unknown

  invalidate_stale_plt

  echo "==> dialyzer (rebuilds the PLT when it was discarded; ~1h cold)" >&2
  # 2>&1: dialyxir writes findings AND the summary to stderr. Exit status is
  # nonzero whenever findings exist, so it cannot distinguish failure.
  mix dialyzer --format short >"$out" 2>&1
  sed -E 's/\x1b\[[0-9;]*m//g' "$out" > "$clean"

  summary=$(grep -E '^Total errors: [0-9]+, Skipped: [0-9]+' "$clean" | tail -1)

  [ -n "$summary" ] || {
    echo "  dialyzer emitted no 'Total errors:' summary -- the run did not" >&2
    echo "  complete. Last output lines:" >&2
    tail -5 "$clean" >&2
    die "refusing to report a dialyzer count from an incomplete run"
  }

  total=$(echo "$summary" | sed -E 's/^Total errors: ([0-9]+).*/\1/')
  skipped=$(echo "$summary" | sed -E 's/.*Skipped: ([0-9]+).*/\1/')

  # Total is the count BEFORE .dialyzer_ignore.exs; Total - Skipped is what
  # dialyzer actually reports, which is what the baseline tracks.
  count=$(( total - skipped ))

  # A deps PLT that is present but under-populated is the nastiest failure
  # mode here: dialyzer completes, prints a summary, and reports a huge
  # fabricated regression because it cannot see the dependencies. Observed:
  # 2055 findings of which 1845 were `unknown_function`, against a true count
  # of 97. A healthy run has a handful at most, so a large share of them means
  # the PLT is broken, not the code.
  unknown=$(grep -cE ':unknown_function' "$clean" || true)
  if [ "$count" -gt 20 ] && [ $(( unknown * 4 )) -gt "$count" ]; then
    echo "  $unknown of $count findings are 'unknown_function'." >&2
    echo "  That means the deps PLT is present but under-populated, so this" >&2
    echo "  count is fabricated. Remove it and let a full run rebuild it:" >&2
    echo "    rm -f priv/plts/local.plt/*_deps-*.plt*" >&2
    die "refusing to report a dialyzer count from an under-populated PLT"
  fi

  stamp_plt
  echo "$count"
}

declare -a results=()

# The measure_* functions run inside a command substitution, which is a
# SUBSHELL: a `die` in there exits only the subshell. An earlier revision did
# `results+=("dialyzer:$(measure_dialyzer)")`, so an aborted measurement left
# an empty count, the comparison below errored with "integer expression
# expected", fell through to the OK branch, and the gate exited 0 -- the same
# false pass the completion markers exist to prevent, reintroduced by the
# call shape. Capture, then check the status and the value in the parent.
run_gate() {
  local gate="$1" count status

  case "$gate" in
    credo) count=$(measure_credo) ;;
    dialyzer) count=$(measure_dialyzer) ;;
    *) die "run_gate: unknown gate '$gate'" ;;
  esac
  status=$?

  [ "$status" -eq 0 ] || die "$gate: measurement aborted (exit $status)"

  case "$count" in
    '') die "$gate: measurement produced no count" ;;
    *[!0-9]*) die "$gate: measurement produced a non-numeric count '$count'" ;;
  esac

  results+=("$gate:$count")
}

want credo && run_gate credo
want dialyzer && run_gate dialyzer

[ ${#results[@]} -gt 0 ] || die "no gates selected"

fail=0
regressed=0

for r in "${results[@]}"; do
  gate=${r%%:*}
  count=${r##*:}
  base=$(baseline_of "$gate")

  case "$base" in
    ''|null) die "$gate: no baseline recorded; seed it with --update" ;;
    *[!0-9]*) die "$gate: baseline '$base' is not a number" ;;
  esac

  if [ "$count" -gt "$base" ]; then
    echo "FAIL $gate: $count > baseline $base (+$((count - base)))" >&2
    fail=1
    regressed=1
  elif [ "$count" -lt "$base" ]; then
    echo "IMPROVED $gate: $count < baseline $base (-$((base - count)))" >&2
    [ "$UPDATE" = 1 ] || echo "         run with --update to lock it in" >&2
  else
    echo "OK $gate: $count (baseline $base)" >&2
  fi
done

if [ "$UPDATE" = 1 ]; then
  # A ratchet whose --update silently raises the bar is not a ratchet. An
  # earlier revision printed FAIL and then wrote the regressed count anyway,
  # exiting 0.
  if [ "$regressed" = 1 ] && [ "$ALLOW_REGRESSION" != 1 ]; then
    echo >&2
    echo "REFUSING to update: a count regressed." >&2
    echo "  Fix the regression, or re-run with --allow-regression if the" >&2
    echo "  increase is genuinely accepted (and say why in the commit)." >&2
    exit 1
  fi

  staged="$TMPDIR_SELF/baseline.json"
  cp "$BASELINE" "$staged"

  # `breakdown`, `by_tree` and `runtime_seconds` are DERIVED from a specific
  # run and are not recomputed here, so carrying them forward would leave them
  # describing an earlier commit -- a maintainer diffing `by_tree` to locate a
  # regression would get an answer from the wrong sha. This file's own
  # `_comment` forbids restating gate numbers in prose because "prose has
  # nothing validating it"; the same applies inside the file. Deleted rather
  # than recomputed: absent beats stale, and the authoritative number is
  # `count`.
  for r in "${results[@]}"; do
    gate=${r%%:*}
    count=${r##*:}
    jq --arg g "$gate" --argjson c "$count" \
       --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg sha "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
       '.gates[$g].count = $c
        | .gates[$g].measured_at = $d
        | .gates[$g].measured_at_sha = $sha
        | del(.gates[$g].breakdown, .gates[$g].by_tree, .gates[$g].runtime_seconds)' \
       "$staged" > "$staged.next" || die "jq failed to update $gate"
    mv "$staged.next" "$staged"
  done

  mv "$staged" "$BASELINE"
  echo "updated $BASELINE" >&2
  exit 0
fi

exit $fail
