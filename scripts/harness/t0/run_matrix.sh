#!/usr/bin/env bash
# T0 — matrix runner (01-t0-matrix.md §8.2's `mix t0.matrix`, as a shell
# driver rather than a mix task per the unit's write-set).
#
# Runs every cell this environment can automate NOW:
#   - the tmux proxy cell (all of C1/C2/C3/C6(x4)/C7/C8(x2)/N06/N07), IF
#     `tmux` is on PATH -- if not, each of those cells gets an explicit
#     "unavailable" row instead of being silently skipped.
#   - the emulator cell (C1/C2(n/a)/C3/C6/N06 structural), via
#     `MIX_ENV=test mix run` from the repo root.
#
# Then it appends PLANNED rows for every real-terminal cell this sandboxed
# environment cannot run (kitty, iTerm2, WezTerm, Ghostty, Alacritty, VTE,
# Apple Terminal x {plain,tmux} x {local,ssh}) -- see t0-runbook.md for the
# exact human commands that fill these in. A planned row is NOT a guess:
# verdict is `null` and automation is "human"/"scripted-pending".
#
# Output: scripts/harness/t0/t0-verdict.json (schema: t0-verdict-schema.md,
# mirrors 01-t0-matrix.md §7). Idempotent and re-runnable.
#
# Usage: run_matrix.sh [--skip-tmux] [--skip-emu]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

skip_tmux=0
skip_emu=0
for arg in "$@"; do
  case "$arg" in
    --skip-tmux) skip_tmux=1 ;;
    --skip-emu) skip_emu=1 ;;
  esac
done

ROWS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE"' EXIT

TMUX_CELLS=(c1 c2 c3 c5 c6-clean c6-sigterm c6-crash c6-sigkill c7 c8-long_lived c8-transient n06 n07)

if [ "$skip_tmux" -eq 0 ] && command -v tmux >/dev/null 2>&1; then
  echo "== tmux $(tmux -V) proxy cell ==" >&2
  for cell in "${TMUX_CELLS[@]}"; do
    echo "-- running tmux/run_cell.sh $cell" >&2
    if ! bash "$HERE/tmux/run_cell.sh" "$cell" >> "$ROWS_FILE"; then
      echo "   FAILED: $cell (see stderr above)" >&2
    fi
  done
else
  echo "== tmux unavailable or --skip-tmux: recording 'unavailable' rows ==" >&2
  for cell in "${TMUX_CELLS[@]}"; do
    claim="$(echo "$cell" | tr '[:lower:]' '[:upper:]' | sed -E 's/^C([0-9]+).*/C\1/; s/^N([0-9]+).*/N\1/')"
    jq -n --arg claim "$claim" --arg cell "$cell" '{
      terminal: "tmux", context: "plain", transport: "local",
      claim: $claim, observable: null, capture: "tmux_capture",
      automation: "unavailable", evidence: "n/a", verdict: null,
      notes: ("tmux not found on PATH in this environment for cell " + $cell + "; install tmux and re-run run_matrix.sh")
    }' >> "$ROWS_FILE"
  done
fi

if [ "$skip_emu" -eq 0 ]; then
  echo "== emulator cell (MIX_ENV=test mix run) ==" >&2
  emu_out="$(cd "$REPO_ROOT" && MIX_ENV=test mix run "$HERE/emulator/t0_emulator_cell.exs" 2>/dev/null)"
  echo "$emu_out" | grep '^{' >> "$ROWS_FILE" || echo "   FAILED: emulator cell produced no JSON rows" >&2
else
  echo "== --skip-emu: skipping emulator cell ==" >&2
fi

# --- Planned Ring-B rows for the real GUI terminal matrix (01-t0-matrix.md
# §2): this sandboxed environment has no kitty/iTerm2/WezTerm/Ghostty/
# Alacritty/VTE/Apple Terminal to drive. Recorded explicitly as "planned"
# so the matrix always shows the FULL cohort, not just what ran here.
REAL_TERMINALS=(kitty iterm2 wezterm ghostty alacritty vte apple)
CONTEXTS=(plain tmux)
TRANSPORTS=(local ssh)
CLAIMS=(C1 C2 C3 C4 C5 C6 C7 C8)

for term in "${REAL_TERMINALS[@]}"; do
  for ctx in "${CONTEXTS[@]}"; do
    for transport in "${TRANSPORTS[@]}"; do
      for claim in "${CLAIMS[@]}"; do
        jq -n --arg t "$term" --arg c "$ctx" --arg tr "$transport" --arg cl "$claim" '{
          terminal: $t, context: $c, transport: $tr, claim: $cl,
          observable: null, capture: "planned", automation: "human",
          evidence: "n/a", verdict: null,
          notes: "Ring B not yet run in this environment -- see t0-runbook.md for the exact command"
        }' >> "$ROWS_FILE"
      done
    done
  done
done

OUT="$HERE/t0-verdict.json"
jq -s '{
  schema: "raxol.t0.verdict/1",
  generated_at: (now | todate),
  matrix: .
}' "$ROWS_FILE" > "$OUT"

echo "Wrote $OUT ($(jq '.matrix | length' "$OUT") rows)" >&2
