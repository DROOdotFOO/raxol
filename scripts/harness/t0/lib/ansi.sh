#!/usr/bin/env bash
# T0 keystone prototype — shared raw-ANSI byte builders.
#
# Deliberately NOT the Raxol render pipeline: these are hand-rolled escape
# sequences so the probe scripts measure what a *real terminal* does with
# the exact bytes T2* would emit, independent of anything our own code does.
#
# Sourced by scripts/harness/t0/probes/*.sh. Every function writes to stdout;
# callers redirect into a pty/tmux pane as needed.
set -uo pipefail

ESC=$'\x1b'

# --- region (DECSTBM) -------------------------------------------------

# t0_set_region TOP BOTTOM — CSI Pt ; Pb r  (1-based, inclusive)
t0_set_region() {
  local top="$1" bottom="$2"
  printf '%s[%s;%sr' "$ESC" "$top" "$bottom"
}

# t0_reset_region — CSI r (full-height region; canonical teardown step)
t0_reset_region() {
  printf '%s[r' "$ESC"
}

# --- cursor ------------------------------------------------------------

t0_cursor_to() {
  local row="$1" col="$2"
  printf '%s[%s;%sH' "$ESC" "$row" "$col"
}

t0_cursor_save() { printf '%s7' "$ESC"; }   # DECSC
t0_cursor_restore() { printf '%s8' "$ESC"; } # DECRC
t0_cursor_hide() { printf '%s[?25l' "$ESC"; }
t0_cursor_show() { printf '%s[?25h' "$ESC"; }

# --- mode 2026 (synchronized output) -----------------------------------

t0_sync_begin() { printf '%s[?2026h' "$ESC"; }
t0_sync_end() { printf '%s[?2026l' "$ESC"; }
t0_decrqm_2026() { printf '%s[?2026$p' "$ESC"; }

# --- keyframe / full clear (the thing T2c must forbid) -----------------

t0_clear_screen() { printf '%s[2J' "$ESC"; }

# --- OSC 133 / 777 block marks ------------------------------------------

t0_osc133_prompt_start() { printf '%s]133;A%s\\' "$ESC" "$ESC"; }
t0_osc133_output_start() { printf '%s]133;C%s\\' "$ESC" "$ESC"; }
t0_osc133_output_end() {
  local exit_code="${1:-0}"
  printf '%s]133;D;%s%s\\' "$ESC" "$exit_code" "$ESC"
}

# --- alt-screen (the thing T2d must NOT emit) ---------------------------

t0_alt_screen_enter() { printf '%s[?1049h' "$ESC"; }
t0_alt_screen_leave() { printf '%s[?1049l' "$ESC"; }

# --- teardown (canonical order per roadmap T2d) -------------------------
# modes-off -> CSI r -> autowrap+cursor -> move+newline -> stty (caller's job)
t0_teardown_bytes() {
  printf '%s[?25h'   "$ESC"   # cursor visible
  t0_reset_region
  printf '%s[?7h'    "$ESC"   # autowrap on
  printf '\r\n'
}

# --- streaming payloads --------------------------------------------------

# t0_stream_numbered_lines N — LINE-0001\r\n .. LINE-000N\r\n
t0_stream_numbered_lines() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    printf 'LINE-%04d\r\n' "$i"
  done
}

# t0_paint_footer TOP N_ROWS LABEL... — paints N_ROWS lines starting at TOP,
# one label per row, WITHOUT touching the scroll region.
t0_paint_footer() {
  local top="$1"; shift
  local row="$top"
  for label in "$@"; do
    t0_cursor_to "$row" 1
    printf '%s[2K%s' "$ESC" "$label"   # EL (erase line) then paint
    row=$((row + 1))
  done
}
