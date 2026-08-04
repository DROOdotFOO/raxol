#!/usr/bin/env bash
# Terminal-Bench launcher for the headless raxol-p Burrito binary.
#
# The harness drives raxol-p inside a tmux PTY. If the BEAM child leaves the tty
# in raw mode -- or dies abnormally mid-run (crash, SIGSEGV, kill) -- the pane is
# wedged for every later command in that task, silently failing the run. Snapshot
# the tty here and restore it unconditionally when the child exits, for any cause.
#
# This restore lives in the parent shell, so it survives a child SIGSEGV that no
# in-VM handler could reach. It cannot cover this launcher itself being SIGKILL'd
# (uncatchable) -- nothing in the same process can.
#
# The T-Bench adapter's install step points the agent command at this script
# instead of the raw binary. Override the binary with RAXOL_P_BIN.
set -u

readonly BIN="${RAXOL_P_BIN:-raxol-p}"

# `stty -g` prints all settings as a single token (portable Linux/BSD); read the
# controlling terminal directly so a redirected stdin doesn't hide it. Empty when
# there is no tty (piped/CI) -- then restore is a no-op and the child runs plain.
saved=""
if [[ -r /dev/tty ]]; then
  saved="$(stty -g </dev/tty 2>/dev/null || true)"
fi

# shellcheck disable=SC2329  # invoked indirectly via the traps below
restore() {
  [[ -n "$saved" ]] && stty "$saved" </dev/tty 2>/dev/null || true
}

# EXIT covers the child returning (any status); the signal traps cover this
# launcher being interrupted while the child runs. restore is idempotent.
trap restore EXIT
trap 'restore; exit 130' INT
trap 'restore; exit 143' TERM
trap 'restore; exit 129' HUP

status=0
"$BIN" "$@" || status=$?
exit "$status"
