#!/usr/bin/env bash
# T0-P-02 — native scrollback feed (claim C-2). THE KEYSTONE MEASUREMENT.
#
# Streams 100 numbered lines into a top-anchored region that is shorter than
# the payload (guaranteeing overflow past the top of the region). The runner
# then recovers scrollback (native get-text API / `tmux capture-pane -S`) and
# checks LINE-0001..LINE-0100 are all present, in order, un-duplicated.
#
# This script only EMITS bytes — it does not itself judge C-2 (the runner
# does, via whatever capture method the terminal/cell supports; see
# 01-t0-matrix.md §2's capture-capability table).
#
# Usage: p02_scrollback_feed.sh [HEIGHT] [FOOTER_ROWS] [LINE_COUNT]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
count="${3:-100}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_set_region 1 "$region_bottom"
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: streaming" "PROMPT>"
t0_cursor_to "$region_bottom" 1
t0_stream_numbered_lines "$count"

# Ring B device-control capture window (no-op unless T0_HOLD_SECONDS set).
t0_hold
