#!/bin/sh
# Canonical launcher for the harness LIVE demo (see harness_live_demo.exs).
#
# Two pre-BEAM locks, both field-validated on a real macOS terminal
# (V's report: with these set, ^C reaches the exit gate as byte 0x03):
#
#   1. `stty -f /dev/tty -isig` BEFORE the BEAM starts: the kernel stops
#      turning ^C into SIGINT from the first instant, so even the boot
#      window (before InlineDriver claims the tty and its own guard
#      takes over) cannot paint the BREAK menu over the screen.
#   2. ELIXIR_ERL_OPTIONS="+Bi": the VM backstop. If ISIG ever flips
#      back on mid-session (prim_tty re-owning the termios) in the gap
#      before the per-keypress guard re-asserts, a signal-path ^C is
#      IGNORED instead of painting the C-level BREAK menu -- the armed
#      "ctrl-c again to exit" notice is this app's only exit dialog.
#
# The exit trap restores the terminal even if the BEAM dies without
# running InlineDriver's teardown (kill -9, a crashed boot).
#
# Usage (from anywhere):
#   packages/raxol_agent/examples/harness-live-demo.sh
#   packages/raxol_agent/examples/harness-live-demo.sh --prompt "hello"
#   DEBUG_WEB=true packages/raxol_agent/examples/harness-live-demo.sh

set -u

cd "$(dirname "$0")/.." || exit 1

# BSD/macOS stty takes -f, GNU takes -F; try both quietly.
tty_flag() {
  if stty -f /dev/tty -a >/dev/null 2>&1; then
    echo "-f"
  else
    echo "-F"
  fi
}

FLAG="$(tty_flag)"

stty "$FLAG" /dev/tty -isig 2>/dev/null

restore_tty() {
  stty "$FLAG" /dev/tty sane 2>/dev/null
}
trap restore_tty EXIT INT TERM

ELIXIR_ERL_OPTIONS="+Bi ${ELIXIR_ERL_OPTIONS:-}" \
  mix run --no-start examples/harness_live_demo.exs "$@"
status=$?

exit "$status"
