#!/usr/bin/env bash
# T0 — tmux proxy-cell session helpers.
#
# tmux capture-pane is the one capture method that works for EVERY terminal
# in the matrix (01-t0-matrix.md §2) but it measures tmux's own terminal
# emulation, not the host's — so this cell is recorded as terminal="tmux"
# (a real, independent data point: does DECSTBM/print-above/scrollback-feed
# survive tmux's own vte, under its default `allow-passthrough off` policy),
# never mislabeled as one of the 7 named GUI terminals.
set -uo pipefail

T0_TMUX_W="${T0_TMUX_W:-80}"
T0_TMUX_H="${T0_TMUX_H:-24}"

# t0_tmux_start SESSION CMD... — detached session running CMD as the pane's
# direct process (no interactive shell prompt in the way of capture).
t0_tmux_start() {
  local session="$1"; shift
  tmux kill-session -t "$session" >/dev/null 2>&1 || true
  tmux new-session -d -s "$session" -x "$T0_TMUX_W" -y "$T0_TMUX_H" "$*"
}

t0_tmux_alive() {
  tmux has-session -t "$1" >/dev/null 2>&1
}

# t0_tmux_pane_pid SESSION — pid of the pane's direct child process.
t0_tmux_pane_pid() {
  tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1
}

# t0_tmux_wait SESSION MAX_SECONDS — poll until the pane's process exits or
# timeout; returns 0 if it exited on its own, 1 on timeout (still running).
t0_tmux_wait() {
  local session="$1" max="${2:-5}" waited=0
  while t0_tmux_alive "$session"; do
    local pid
    pid=$(t0_tmux_pane_pid "$session")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
    waited=$(awk -v w="$waited" 'BEGIN{print w+0.2}')
    if awk -v w="$waited" -v m="$max" 'BEGIN{exit !(w>=m)}'; then
      return 1
    fi
  done
  return 0
}

# t0_tmux_capture_visible SESSION — visible pane text only.
t0_tmux_capture_visible() {
  tmux capture-pane -p -t "$1" 2>/dev/null
}

# t0_tmux_capture_scrollback SESSION LINES — visible + LINES of history.
t0_tmux_capture_scrollback() {
  local session="$1" lines="${2:-200}"
  tmux capture-pane -p -S "-$lines" -t "$session" 2>/dev/null
}

# t0_tmux_cursor SESSION — "row,col" (0-based, per tmux convention).
t0_tmux_cursor() {
  tmux display-message -p -t "$1" '#{cursor_y},#{cursor_x}' 2>/dev/null
}

t0_tmux_stop() {
  tmux kill-session -t "$1" >/dev/null 2>&1 || true
}
