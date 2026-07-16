#!/usr/bin/env bash
# T0-P-01 — region orientation & footer pin (claim C-1).
#
# Sets a top-anchored DECSTBM region (rows 1..H-N), paints an N-row footer
# below it, streams K > (H-N) lines into the region, and repaints the footer
# once more so a byte-diff of the two footer paints proves the strip was
# never touched by the scroll.
#
# Usage: p01_region_footer.sh [HEIGHT] [FOOTER_ROWS] [LINES]
# Default: 24-row terminal, 3-row footer (rows 22-24), 40 lines streamed
# into a 21-row region (guarantees overflow/scroll).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
lines="${3:-40}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_set_region 1 "$region_bottom"
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: idle" "PROMPT> hello"

# Move into the region (save the footer/cursor position first) and stream.
t0_cursor_save
t0_cursor_to "$region_bottom" 1
t0_stream_numbered_lines "$lines"
t0_cursor_restore

# Repaint the footer identically — a real T2c would not need to do this
# (the strip is never touched), but doing it here gives the capture a
# byte-identical "expected" footer to diff the first paint against.
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: idle" "PROMPT> hello"

# Ring B device-control capture window (no-op unless T0_HOLD_SECONDS set).
t0_hold
