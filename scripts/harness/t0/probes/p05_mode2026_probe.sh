#!/usr/bin/env bash
# T0-P-05 — mode-2026 (synchronized output) composition (claim C-5).
#
# Sends a DECRQM probe for mode 2026 and captures the raw reply via
# read_reply.py (this is exactly the capture the capability-capture writer
# records, per 04-capability.md §2 — reply bytes as hex, no interpretation
# here; T1's ReplyScanner/Classifier owns interpretation). Then wraps a
# 3-row footer repaint in a synchronized-output bracket so a Ring-C human
# pass can watch for tearing, and so Ring A can assert the brackets balance
# and the bytes between them touch only footer rows.
#
# Usage: p05_mode2026_probe.sh [REPLY_TIMEOUT_SECONDS] [HEIGHT] [FOOTER_ROWS]
# Prints the reply hex to fd 2 (stderr) prefixed "REPLY_HEX=" so callers can
# separate it from the fd-1 byte stream driving the terminal.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ansi.sh
source "$HERE/../lib/ansi.sh"

timeout="${1:-1.0}"
height="${2:-24}"
footer_rows="${3:-3}"
region_bottom=$((height - footer_rows))
footer_top=$((region_bottom + 1))

t0_decrqm_2026
reply_hex="$(python3 "$HERE/../lib/read_reply.py" "$timeout" 2>/dev/null || true)"
echo "REPLY_HEX=$reply_hex" >&2

t0_sync_begin
t0_paint_footer "$footer_top" "---STRIP---" "STATUS: 2026-framed" "PROMPT>"
t0_sync_end
