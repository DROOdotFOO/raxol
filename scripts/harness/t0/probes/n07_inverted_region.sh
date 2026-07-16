#!/usr/bin/env bash
# T0-N-07 — region orientation inverted (trigger `footer_not_pinned`).
#
# Deliberately sets the region to the BOTTOM N rows instead of the top
# (the orientation the roadmap says T0 must NOT ship, v1's bug). Streaming
# then scrolls the "footer" rows away. This is the negative-control half of
# T0-P-01/C-1: run the detector against this script and it MUST fire; run
# it against p01_region_footer.sh and it MUST NOT (no false positive).
#
# Usage: n07_inverted_region.sh [HEIGHT] [FOOTER_ROWS] [LINE_COUNT]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
count="${3:-40}"
inverted_top=$((height - footer_rows + 1))

# INVERTED: region = the last N rows (should be the footer's home).
t0_set_region "$inverted_top" "$height"
t0_paint_footer 1 "---STRIP---" "STATUS: idle" "PROMPT>"
t0_cursor_to "$height" 1
t0_stream_numbered_lines "$count"

# Ring B device-control capture window (no-op unless T0_HOLD_SECONDS set).
t0_hold
