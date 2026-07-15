#!/usr/bin/env bash
# T0-P-04 — long-lived vs transient region algorithm (claim C-8).
#
# Two DECSTBM disciplines, compared per-terminal by running this script
# once with each ALGORITHM and diffing the P-02/C-1 results between runs:
#   long_lived — region set once at start, held for the whole session.
#   transient  — region set/scroll/reset PER APPEND (Bubble-Tea's
#                insertTop style): set -> insert one line -> reset.
#
# Usage: p04_region_algorithm.sh ALGORITHM [HEIGHT] [FOOTER_ROWS] [LINE_COUNT]
#   ALGORITHM: long_lived | transient
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

algorithm="${1:?usage: p04_region_algorithm.sh long_lived|transient [height] [footer_rows] [count]}"
height="${2:-24}"
footer_rows="${3:-3}"
count="${4:-100}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_paint_footer "$footer_top" "---STRIP---" "STATUS: streaming ($algorithm)" "PROMPT>"

case "$algorithm" in
  long_lived)
    t0_set_region 1 "$region_bottom"
    t0_cursor_to "$region_bottom" 1
    t0_stream_numbered_lines "$count"
    ;;
  transient)
    for ((i = 1; i <= count; i++)); do
      t0_set_region 1 "$region_bottom"
      t0_cursor_to "$region_bottom" 1
      printf 'LINE-%04d\r\n' "$i"
      t0_reset_region
      # Re-park the cursor in the footer between appends, as a transient
      # implementation must (it just gave up the region entirely).
      t0_cursor_to "$footer_top" 1
    done
    ;;
  *)
    echo "unknown algorithm: $algorithm" >&2
    exit 2
    ;;
esac
