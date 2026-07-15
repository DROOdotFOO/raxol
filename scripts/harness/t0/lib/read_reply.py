#!/usr/bin/env python3
"""T0 — raw terminal-reply capture.

Puts the controlling tty (stdin) into raw mode, reads whatever bytes arrive
within a fixed window, restores the tty, and prints the captured bytes as
lowercase hex (no separators) — the exact `reply_hex` shape the capability
capture schema (docs/proposals/in-flight/harness-ui-testing/04-capability.md
§2) expects. Used by probes that emit a query (e.g. DECRQM `CSI ? 2026 $ p`)
and need the raw reply for T1's fixture bank; also usable standalone by a
human running Ring B on a real terminal.

Usage: read_reply.py TIMEOUT_SECONDS [MAX_BYTES]
Reads from fd 0, writes hex to fd 1. Never raises on timeout — prints
whatever arrived (possibly empty).
"""
import sys
import os
import select

try:
    import termios
    import tty
except ImportError:  # pragma: no cover - non-POSIX platform
    termios = None
    tty = None


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: read_reply.py TIMEOUT_SECONDS [MAX_BYTES]", file=sys.stderr)
        return 2

    timeout = float(sys.argv[1])
    max_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else 4096

    fd = sys.stdin.fileno()
    is_tty = os.isatty(fd)
    old_settings = termios.tcgetattr(fd) if (is_tty and termios) else None

    try:
        if is_tty and tty:
            tty.setraw(fd)

        deadline = timeout
        collected = b""
        while len(collected) < max_bytes:
            ready, _, _ = select.select([fd], [], [], deadline)
            if not ready:
                break
            chunk = os.read(fd, max_bytes - len(collected))
            if not chunk:
                break
            collected += chunk
            # Once we've received the first byte, give the rest of a
            # multi-byte reply a short grace window instead of the full
            # original timeout (mirrors Probe's extend-deadline shape).
            deadline = 0.2

        sys.stdout.write(collected.hex())
        sys.stdout.flush()
        return 0
    finally:
        if old_settings is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


if __name__ == "__main__":
    raise SystemExit(main())
