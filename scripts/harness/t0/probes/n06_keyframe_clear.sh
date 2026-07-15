#!/usr/bin/env bash
# T0-N-06 — full-screen clear wipes sealed history (trigger
# `keyframe_clear_leak`). Reproduces the CURRENT `build_terminal_frame`
# keyframe path (verified in backends.ex: emits `\e[2J` on resize/
# force_repaint) so the runner can see the corruption directly: after N
# sealed lines, a keyframe wipe should NEVER be forbidden — proving the
# invariant T2c must add ("`\e[2J` is forbidden on the :inline_log path").
#
# This is the fixture for the Ring-A regression guard (SequenceScanner:
# zero `\e[2J` bytes on the inline path) as well as a real-terminal Ring-B
# demonstration of the leak.
#
# Usage: n06_keyframe_clear.sh [HEIGHT] [FOOTER_ROWS] [LINE_COUNT]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
count="${3:-20}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_set_region 1 "$region_bottom"
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: pre-keyframe" "PROMPT>"
t0_cursor_to "$region_bottom" 1
t0_stream_numbered_lines "$count"

# The bug under test: a "keyframe" (today's resize/force_repaint path)
# clearing the WHOLE screen, not just the footer region.
t0_clear_screen
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: post-keyframe" "PROMPT>"
