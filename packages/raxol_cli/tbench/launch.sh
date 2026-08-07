#!/usr/bin/env bash
# Terminal-Bench launcher for the headless raxol-p Burrito binary.
#
# Two jobs, both about surviving the harness's failure modes:
#
# 1. tty restore. The harness drives raxol-p inside a tmux PTY. If the BEAM
#    child leaves the tty in raw mode -- or dies abnormally mid-run (crash,
#    SIGSEGV, kill) -- the pane is wedged for every later command in that
#    task, silently failing the run. Snapshot the tty here and restore it
#    unconditionally when the child exits, for any cause.
#
# 2. signal forwarding. Burrito's zig launcher spawns the BEAM and waits; it
#    does NOT forward signals (verified against burrito 1.6: a SIGTERM kills
#    the launcher raw, orphaning the BEAM, and the in-VM flush -- final
#    event, trajectory, exit 143 -- never runs). When the harness TERMs this
#    launcher on timeout, we find the BEAM under the Burrito wrapper and
#    signal IT, so the run flushes its journal/trajectory and exits 143 by
#    its own hand. The child-pid walk uses /proc directly: task containers
#    need not ship procps.
#
# Restore lives in the parent shell, so it survives a child SIGSEGV that no
# in-VM handler could reach. Nothing here can cover this launcher itself
# being SIGKILL'd (uncatchable).
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

child=""

# First process whose parent is $1, via /proc (works without procps).
# shellcheck disable=SC2329  # invoked via forward() from the traps below
first_child_of() {
  local status ppid
  for status in /proc/[0-9]*/status; do
    ppid="$(awk '/^PPid:/ {print $2}' "$status" 2>/dev/null)" || continue
    if [[ "$ppid" == "$1" ]]; then
      basename "$(dirname "$status")"
      return 0
    fi
  done
  return 1
}

# shellcheck disable=SC2329  # invoked indirectly via the traps below
forward() {
  local sig="$1" target=""
  if [[ -n "$child" ]]; then
    # The Burrito launcher's child is erlexec, which execs the BEAM in
    # place -- one hop down is the VM itself.
    target="$(first_child_of "$child" || true)"
    kill -s "$sig" "${target:-$child}" 2>/dev/null || true
  fi
}

trap restore EXIT
trap 'forward TERM' TERM
trap 'forward INT' INT
trap 'forward HUP' HUP

"$BIN" "$@" &
child=$!

# A trap firing interrupts `wait` (returns 128+sig) without the child being
# done; loop until the child has actually exited so we report ITS status --
# after a forwarded TERM that is the BEAM's own flushed exit 143.
status=0
while :; do
  if wait "$child"; then
    status=0
  else
    status=$?
  fi
  kill -0 "$child" 2>/dev/null || break
done

restore
exit "$status"
