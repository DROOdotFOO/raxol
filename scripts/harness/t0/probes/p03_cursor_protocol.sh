#!/usr/bin/env bash
# T0-P-03 — print-above cursor protocol (claim C-3).
#
# The shared T2b<->T2c cursor-ownership protocol: save (DECSC) -> position
# into the region -> emit sealed block lines -> restore (DECRC) -> repaint
# footer only. Runs the cycle twice (once for the initial stream, once for
# a single isolated "ABOVE-MARK" line) so the runner can assert: (a) the
# footer/composer content is undisturbed, (b) the cursor ends exactly where
# DECRC should put it (col 14 of the composer row, right after "hello").
#
# Usage: p03_cursor_protocol.sh [HEIGHT] [FOOTER_ROWS]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))
composer_row=$((footer_top + 2))

t0_set_region 1 "$region_bottom"
# Composer shows "PROMPT> hello" with the logical cursor after "hello"
# (13 chars -> column 14, 1-based, matches the roadmap's P-03 acceptance).
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: idle" "PROMPT> hello"

# Cycle 1: seal a small batch of history.
t0_cursor_save
t0_cursor_to "$region_bottom" 1
t0_stream_numbered_lines 5
t0_cursor_restore

# Cycle 2: seal one more line in isolation (isolates a single print-above
# round-trip for the assertion).
t0_cursor_save
t0_cursor_to "$region_bottom" 1
printf 'ABOVE-MARK\r\n'
t0_cursor_restore

# No further writes: the cursor must now sit at (composer_row, 14).
: "$composer_row" # referenced for readers; position asserted by the runner.
