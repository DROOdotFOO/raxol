#!/usr/bin/env bash
# Proves the scoreboard catches regressions. Each file in
# bench/scoreboard_canaries/ is a deliberate regression: a patch, preceded by
#
#   Regression: what it breaks (continuation lines indented)
#   Expect-worse: METRIC...          the comparison must call each one worse
#   Expect-refused: TEXT             or the scoreboard must refuse to measure,
#                                    with TEXT in its error
#
# This measures the checkout once, then for each canary applies the patch,
# measures again, reverts, and checks the verdict against the baseline with
# the same classification the pull request comment uses
# (`.github/scripts/scoreboard.mjs classify`).
#
#   MIX_ENV=test scripts/scoreboard-canaries.sh [NAME...]
#
# Prints a markdown table (also to $GITHUB_STEP_SUMMARY when set) and exits 1
# when any canary is not caught, including one that no longer applies.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
dir=bench/scoreboard_canaries
defs=priv/scoreboard/metrics.json
mjs=.github/scripts/scoreboard.mjs

# Patches are applied to and reverted from this tree.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "scoreboard-canaries: commit or stash changes to tracked files first" >&2
  exit 2
fi

if [ "$#" -gt 0 ]; then
  names=("$@")
else
  names=()
  for patch in "$dir"/*.patch; do names+=("$(basename "$patch" .patch)"); done
fi

tmp=$(mktemp -d)
applied=""
cleanup() {
  if [ -n "$applied" ]; then git apply -R "$applied"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# Buffer gate memory rows plus the scoreboard, as CI records them. The gate
# exits 1 on a breached budget and still writes its rows.
measure() {
  local out=$1 log=$2 gate_rc=0
  mix run --no-start bench/core/buffer_gate.exs --json "$tmp/gate.json" > "$log" 2>&1 || gate_rc=$?
  if [ "$gate_rc" -gt 1 ]; then return 1; fi
  mix raxol.scoreboard --include "$tmp/gate.json" --output "$out" >> "$log" 2>&1
}

header() { sed -n "s/^$2: //p" "$1" | head -1; }

echo "Measuring the baseline" >&2
if ! measure "$tmp/base.json" "$tmp/base.log"; then
  cat "$tmp/base.log" >&2
  echo "scoreboard-canaries: the baseline does not measure" >&2
  exit 1
fi

rows=()
missed=0
for name in "${names[@]}"; do
  patch="$dir/$name.patch"
  echo "Canary $name" >&2
  worse=$(header "$patch" Expect-worse)
  refused=$(header "$patch" Expect-refused)

  if [ -z "$worse" ] && [ -z "$refused" ]; then
    rows+=("| \`$name\` | **invalid** | no Expect-worse or Expect-refused line |")
    missed=$((missed + 1))
    continue
  fi
  if ! git apply --check "$patch" 2> "$tmp/apply.log"; then
    rows+=("| \`$name\` | **stale** | no longer applies; regenerate it against today's code |")
    missed=$((missed + 1))
    continue
  fi

  git apply "$patch"
  applied=$patch
  ran=0
  if measure "$tmp/head.json" "$tmp/$name.log"; then ran=1; fi
  git apply -R "$patch"
  applied=""

  if [ -n "$refused" ]; then
    if [ "$ran" -eq 0 ] && grep -qF -- "$refused" "$tmp/$name.log"; then
      rows+=("| \`$name\` | caught | refused to measure: $refused |")
    elif [ "$ran" -eq 1 ]; then
      rows+=("| \`$name\` | **missed** | measured without complaint |")
      missed=$((missed + 1))
    else
      rows+=("| \`$name\` | **error** | failed, but not with \"$refused\": $(grep -m1 -E '^\*\* ' "$tmp/$name.log" || tail -1 "$tmp/$name.log") |")
      missed=$((missed + 1))
    fi
    continue
  fi

  if [ "$ran" -eq 0 ]; then
    rows+=("| \`$name\` | **error** | did not measure: $(grep -m1 -E '^\*\* ' "$tmp/$name.log" || tail -1 "$tmp/$name.log") |")
    missed=$((missed + 1))
    continue
  fi

  node "$mjs" classify --defs "$defs" --base "$tmp/base.json" --head "$tmp/head.json" > "$tmp/$name.verdict"
  not_worse=()
  for id in $worse; do
    if ! grep -qx "$id worse .*" "$tmp/$name.verdict"; then not_worse+=("$id"); fi
  done
  # Every metric that moved, so a side effect (a ratio that improves because
  # its denominator got worse) is visible too.
  moved=$(awk '$2 == "worse" || $2 == "better" {
    rel = ($3 == "-") ? "from 0" : sprintf("%+.2f%%", $3 * 100)
    printf "%s`%s` %s %s", sep, $1, rel, $2; sep = ", "
  }' "$tmp/$name.verdict")
  if [ "${#not_worse[@]}" -eq 0 ]; then
    rows+=("| \`$name\` | caught | $moved |")
  else
    rows+=("| \`$name\` | **missed** | not worse: ${not_worse[*]}; moved: ${moved:-nothing} |")
    missed=$((missed + 1))
  fi
done

{
  echo "### Scoreboard canaries"
  echo
  echo "| Canary | Result | Detail |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$missed" -gt 0 ]; then
  echo "scoreboard-canaries: $missed of ${#names[@]} canaries not caught" >&2
  exit 1
fi
