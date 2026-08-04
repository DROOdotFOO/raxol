"use strict";
// Snapshot the controlling terminal's line settings before running a child that
// may switch the tty to raw mode, and restore them unconditionally when the
// child exits -- for ANY cause: a clean exit, a signal, or a crash/segfault of
// the child. Without this a BEAM child that dies while the tty is raw leaves the
// parent shell wedged (no echo, no line editing) until the user blindly types
// `reset`. This restore lives in the parent process, so it survives a child
// SIGSEGV that no in-VM handler could. It cannot cover the parent itself being
// SIGKILL'd -- that is uncatchable, and nothing in-process can help.
const { execFileSync } = require("node:child_process");
const { openSync } = require("node:fs");

function openControllingTty() {
  // A real tty on stdin means we're interactive and have settings worth saving.
  // Open /dev/tty directly so we still target the terminal if stdin/stdout are
  // redirected.
  if (process.stdin.isTTY !== true) return null;
  try {
    return openSync("/dev/tty", "r+");
  } catch {
    return null;
  }
}

function snapshot(fd) {
  try {
    // `stty -g` prints all settings as a single token, portable across Linux
    // (colon-hex) and BSD/macOS. Feed /dev/tty as stdin so stty targets the
    // terminal without the non-portable -F/-f device flag.
    return execFileSync("stty", ["-g"], {
      stdio: [fd, "pipe", "ignore"],
      encoding: "utf8",
    }).trim();
  } catch {
    return null;
  }
}

function restore(fd, saved) {
  if (fd == null || !saved) return;
  try {
    execFileSync("stty", [saved], { stdio: [fd, "ignore", "ignore"] });
  } catch {
    // Best effort: a failed restore must never mask the child's exit status.
  }
}

// Run `child()` (which spawns and returns the sync result) with the terminal
// snapshotted first and restored no matter how the child exits. The `finally`
// covers the normal return; the `exit` backstop covers an internal
// `process.exit` or a late signal. `restore` is idempotent, so running twice is
// harmless. The /dev/tty fd is intentionally left open -- the process is exiting
// imminently, and keeping it lets the backstop restore too.
function withTerminalRestore(child) {
  const fd = openControllingTty();
  const saved = fd == null ? null : snapshot(fd);

  process.once("exit", () => restore(fd, saved));

  try {
    return child();
  } finally {
    restore(fd, saved);
  }
}

module.exports = { withTerminalRestore };
