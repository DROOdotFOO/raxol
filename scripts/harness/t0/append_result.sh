#!/usr/bin/env bash
# T0 — append/upsert one real CellResult into t0-verdict.json.
#
# Removes any existing PLANNED placeholder row for the same
# (terminal, context, transport, claim) and appends the real row in its
# place -- idempotent (running the same command twice just replaces the
# row again), so a human re-running a Ring B cell after a terminal update
# safely overwrites the old evidence.
#
# Usage:
#   append_result.sh TERMINAL CONTEXT TRANSPORT CLAIM VERDICT OBSERVABLE \
#                     CAPTURE_METHOD AUTOMATION EVIDENCE_PATH [NOTES]
#
#   TERMINAL:   kitty | iterm2 | wezterm | ghostty | alacritty | vte | apple
#               | tmux | emu
#   CONTEXT:    plain | tmux
#   TRANSPORT:  local | ssh
#   CLAIM:      C1 | C2 | C3 | C4 | C5 | C6 | C7 | C8 | N06 | N07 | ...
#   VERDICT:    pass | fail | fed | lost | partial | n/a | ... (free text,
#               matches the claim's observable-type table in
#               01-t0-matrix.md §4)
#   OBSERVABLE: same as VERDICT unless the claim needs a JSON object
#               (pass it as a JSON string, e.g. '{"decrqm":1,"torn":false}';
#               non-JSON input is wrapped as a plain string automatically)
#   CAPTURE_METHOD: native_gettext | tmux_capture | pty_tee | human_eye
#   AUTOMATION: ci | scripted | human
#   EVIDENCE_PATH: path (relative to repo root) to the .cast/screenshot/
#                  capture-pane dump backing this row
#
# Example (kitty, plain, local, C2, native get-text):
#   ./append_result.sh kitty plain local C2 fed fed native_gettext scripted \
#     scripts/harness/t0/capture/evidence/kitty-plain-local-c2.txt \
#     "kitten @ get-text --extent=all: LINE-0001..0100 all present, in order"
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_FILE="$HERE/t0-verdict.json"

terminal="${1:?terminal required}"
context="${2:?context required}"
transport="${3:?transport required}"
claim="${4:?claim required}"

# Terminal allowlist (matches the matrix in 01-t0-matrix.md §2 + the two
# automated cells). A typo'd terminal name would create a row no consumer
# (resolver, T1 fixture loader) ever reads -- fail loud instead.
case "$terminal" in
  kitty|iterm2|wezterm|ghostty|alacritty|vte|apple|tmux|emu) ;;
  *)
    echo "unknown terminal '$terminal' -- allowed: kitty iterm2 wezterm ghostty alacritty vte apple tmux emu" >&2
    exit 1
    ;;
esac
case "$context" in
  plain|tmux) ;;
  *) echo "unknown context '$context' -- allowed: plain tmux" >&2; exit 1 ;;
esac
case "$transport" in
  local|ssh) ;;
  *) echo "unknown transport '$transport' -- allowed: local ssh" >&2; exit 1 ;;
esac
verdict="${5:?verdict required}"
observable="${6:?observable required}"
capture="${7:?capture method required}"
automation="${8:?automation required}"
evidence="${9:?evidence path required}"
notes="${10:-}"

[ -f "$VERDICT_FILE" ] || { echo "no $VERDICT_FILE yet -- run run_matrix.sh first" >&2; exit 1; }

# observable may be a JSON literal (object/bool/number) or a bare string.
observable_json="$(printf '%s' "$observable" | jq -c . 2>/dev/null || printf '%s' "$observable" | jq -Rc .)"

new_row="$(jq -n \
  --arg terminal "$terminal" --arg context "$context" --arg transport "$transport" \
  --arg claim "$claim" --arg verdict "$verdict" --argjson observable "$observable_json" \
  --arg capture "$capture" --arg automation "$automation" --arg evidence "$evidence" \
  --arg notes "$notes" \
  '{terminal:$terminal, context:$context, transport:$transport, claim:$claim,
    observable:$observable, capture:$capture, automation:$automation,
    evidence:$evidence, verdict:$verdict} +
   (if $notes != "" then {notes:$notes} else {} end)')"

tmp="$(mktemp)"
jq --argjson row "$new_row" \
   --arg terminal "$terminal" --arg context "$context" --arg transport "$transport" --arg claim "$claim" \
  '.matrix = ([.matrix[] | select(
      .terminal != $terminal or .context != $context or
      .transport != $transport or .claim != $claim
    )] + [$row]) | .generated_at = (now | todate)' \
  "$VERDICT_FILE" > "$tmp"
mv "$tmp" "$VERDICT_FILE"

echo "upserted {$terminal, $context, $transport, $claim} -> $verdict into $VERDICT_FILE" >&2
