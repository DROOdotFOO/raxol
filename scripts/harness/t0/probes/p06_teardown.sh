#!/usr/bin/env bash
# T0-P-06 / T0-N-05 — teardown resets the region (claim C-6).
#
# Sets a region + footer, then sleeps holding it open so the runner can
# exercise one of four exit paths against the SAME running process:
#   clean   — this script exits normally (its own EXIT trap tears down).
#   sigterm — runner sends SIGTERM; a trap runs teardown then exits.
#   crash   — this script traps ERR (simulated failure) and tears down
#             before re-raising (the "trapped crash" acceptance path).
#   sigkill — NOT handled here (SIGKILL cannot be trapped by definition,
#             T0-N-05's documented residual). The runner sends kill -9
#             directly and asserts the region is left stuck (the honest
#             expected result), never runs this script's SIGKILL branch.
#
# Usage: p06_teardown.sh MODE [HEIGHT] [FOOTER_ROWS]
#   MODE: clean | sigterm | crash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

mode="${1:?usage: p06_teardown.sh clean|sigterm|crash [height] [footer_rows]}"
height="${2:-24}"
footer_rows="${3:-3}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

teardown_ran=0
teardown() {
  [ "$teardown_ran" -eq 1 ] && return
  teardown_ran=1
  t0_teardown_bytes
}
trap teardown EXIT

t0_set_region 1 "$region_bottom"
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: running ($mode)" "PROMPT>"
t0_cursor_to "$region_bottom" 1
t0_stream_numbered_lines 10

case "$mode" in
  clean)
    exit 0
    ;;
  sigterm)
    trap 'exit 143' TERM  # 128+15; EXIT trap above still fires on exit.
    sleep 30 &
    wait $!
    ;;
  crash)
    # Simulate a caught application crash: the "trapped crash" acceptance
    # path is that OUR code notices the failure and tears down before
    # exiting — deliberately not relying on bash's `set -e`/ERR-trap
    # semantics, which vary in subshells and across bash versions.
    if ! false; then
      teardown
      exit 70 # EX_SOFTWARE
    fi
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac
