#!/usr/bin/env bash
# T0-P-07 — tmux happy path (claim C-7): region + scrollback load plus OSC
# 133 A/B/C/D block marks around one simulated "turn" and one "tool call".
# Meant to be run *inside* tmux (see tmux/session.sh); the runner checks:
#   - capture-pane -S shows the fed scrollback (C-2 via tmux, R-04 §D)
#   - whether OSC 133 reached the outer terminal is a SEPARATE, Ring-B,
#     host-side check this script cannot make from inside the pane —
#     documented in the runbook as a human step on a real terminal hosting
#     tmux (R-04 §D expects `:inert` — marks emitted but consumed by tmux).
#
# Usage: p07_tmux_marks.sh [HEIGHT] [FOOTER_ROWS]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

height="${1:-24}"
footer_rows="${2:-3}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_set_region 1 "$region_bottom"
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: turn 1" "PROMPT>"
t0_cursor_to "$region_bottom" 1

t0_osc133_prompt_start
t0_stream_numbered_lines 5
t0_osc133_output_start
printf 'tool: echo hi\r\nhi\r\n'
t0_osc133_output_end 0
