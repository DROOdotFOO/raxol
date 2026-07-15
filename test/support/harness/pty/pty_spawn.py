#!/usr/bin/env python3
"""Vendored pty spawn/control wrapper for Raxol's Tier B lifecycle tests.

Stdlib only (pty/os/signal/termios/fcntl/subprocess) -- no third-party deps,
so it runs on any CI image with python3 and nothing else.

Usage:
    python3 pty_spawn.py --capture PATH [--winsize ROWSxCOLS] [--cwd DIR]
                         [--env KEY=VAL ...] -- CMD [ARG ...]

Spawns CMD under a fresh pty (child becomes session leader + controlling-tty
owner, mirroring `os.login_tty`), tees everything the child writes to PATH,
and then speaks a one-command-per-line protocol on its own stdin/stdout.

Options:
    --winsize ROWSxCOLS  pty window size, set via TIOCSWINSZ before exec
                         (default 24x80 -- never the kernel's 0x0 default,
                         which breaks anything that consults `stty size`).
    --cwd DIR            child working directory (chdir after fork).
    --env KEY=VAL        extra child environment (repeatable; merged over
                         the inherited environment).

Protocol:

    SIG <term|int|kill|tstp|stop|cont|hup|usr1|usr2>
        Deliver the named signal to the child's *process group* (not just
        the child pid, so a `sh -c` subshell chain is covered). NOTE: the
        spawned child is a session leader whose process group is ORPHANED
        (its parent lives in another session), and POSIX discards
        default-action job-control stop signals (SIGTSTP/SIGTTIN/SIGTTOU)
        sent to orphaned process groups -- so `SIG tstp` only stops a child
        that HANDLES the signal (as real inline apps do, per the
        03-lifecycle design). `SIG stop` (SIGSTOP) cannot be caught or
        discarded and always stops.
        -> "OK SIG <name>" | "ERR <reason>"

    WRITE <hexbytes>
        Write raw bytes (hex-encoded on the wire) to the pty master, i.e.
        inject them as if typed (e.g. "03" for Ctrl-C, "1a" for Ctrl-Z).
        -> "OK WRITE <n>" | "ERR <reason>"

    STTY
        Run `stty -a` against the pty *slave* (kernel line-discipline
        probe, independent of anything the child itself has done to fd 0).
        -> "STTY <base64>" | "ERR <reason>"

    RECOVER
        The documented kill-9 recovery one-liner: write `ESC [ r` (reset
        scroll region) to the slave, then `stty sane` against it.
        -> "OK RECOVER" | "ERR <reason>"

    WAIT <timeout_ms>
        Block (bounded by timeout_ms) until the child changes state. Uses
        WUNTRACED, so a SIGTSTP-stopped child reports as STOPPED (once per
        stop -- the child is NOT reaped, so a later WAIT can still observe
        the eventual exit after SIGCONT).

        DRAIN BARRIER: when the state change is an exit (EXIT/SIGNALED,
        not STOPPED), the wrapper joins the capture pump thread -- draining
        the pty master to EOF and closing the capture file -- BEFORE
        replying. A successful WAIT therefore guarantees the capture file
        is complete; without this, a reply racing the last pump write
        could make truncation tests (LC-P-SIGTERM) flaky. The join is
        bounded (5s): if an orphaned grandchild keeps the slave open the
        master never EOFs, and WAIT replies anyway after the bound.
        -> "EXIT <code>" | "SIGNALED <signum>" | "STOPPED <signum>"
           | "TIMEOUT" | "ERR <reason>"

On EOF of its own stdin (the Elixir side closing the port), the wrapper
best-effort SIGKILLs the child's process group so nothing is left running,
then exits.

The very first line written to stdout, before the command loop starts, is
either "SPAWNED <pid>" or "ERR <reason>" (spawn failure).
"""

import base64
import fcntl
import os
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

_SIGNAL_MAP = {
    "term": signal.SIGTERM,
    "int": signal.SIGINT,
    "kill": signal.SIGKILL,
    "tstp": signal.SIGTSTP,
    "stop": signal.SIGSTOP,
    "cont": signal.SIGCONT,
    "hup": signal.SIGHUP,
    "usr1": signal.SIGUSR1,
    "usr2": signal.SIGUSR2,
}


class PtyChild:
    """Owns the forked child + its pty pair and answers control commands."""

    def __init__(self, capture_path, argv, winsize=(24, 80), cwd=None, env=None):
        self.capture_path = capture_path
        self.argv = argv
        self.winsize = winsize
        self.cwd = cwd
        self.env_overrides = env or {}
        self.pid = None
        self.master_fd = None
        self.slave_name = None
        self._reaped_status = None  # (kind, value) once WAIT has reaped it
        self._capture_lock = threading.Lock()
        self._capture_file = None
        self._pump_thread = None

    def spawn(self):
        master_fd, slave_fd = os.openpty()
        slave_name = os.ttyname(slave_fd)

        rows, cols = self.winsize
        fcntl.ioctl(
            slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0)
        )

        child_env = dict(os.environ)
        child_env.update(self.env_overrides)

        pid = os.fork()
        if pid == 0:
            # --- child ---
            try:
                os.close(master_fd)
                os.setsid()
                fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
                os.dup2(slave_fd, 0)
                os.dup2(slave_fd, 1)
                os.dup2(slave_fd, 2)
                if slave_fd > 2:
                    os.close(slave_fd)
                if self.cwd is not None:
                    os.chdir(self.cwd)
                os.execvpe(self.argv[0], self.argv, child_env)
            except Exception:
                os._exit(127)
            os._exit(127)  # unreachable; guards against execvpe fallthrough

        # --- parent ---
        os.close(slave_fd)
        self.pid = pid
        self.master_fd = master_fd
        self.slave_name = slave_name
        self._capture_file = open(self.capture_path, "wb", buffering=0)

        self._pump_thread = threading.Thread(
            target=self._pump_capture, daemon=True
        )
        self._pump_thread.start()

    def _pump_capture(self):
        while True:
            try:
                chunk = os.read(self.master_fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            with self._capture_lock:
                if self._capture_file is not None:
                    self._capture_file.write(chunk)
                    self._capture_file.flush()
        with self._capture_lock:
            if self._capture_file is not None:
                self._capture_file.close()
                self._capture_file = None

    # -- commands --

    def do_sig(self, name):
        signum = _SIGNAL_MAP.get(name)
        if signum is None:
            return "ERR unknown signal: {}".format(name)
        try:
            os.killpg(self.pid, signum)
        except ProcessLookupError:
            return "ERR no such process"
        except PermissionError as exc:
            return "ERR permission denied: {}".format(exc)
        return "OK SIG {}".format(name)

    def do_write(self, hex_bytes):
        try:
            data = bytes.fromhex(hex_bytes)
        except ValueError as exc:
            return "ERR bad hex: {}".format(exc)
        # os.write can short-write on a pty; loop until fully drained so
        # the reported count always equals len(data) on success.
        total = 0
        try:
            while total < len(data):
                total += os.write(self.master_fd, data[total:])
        except OSError as exc:
            return "ERR write failed after {} bytes: {}".format(total, exc)
        return "OK WRITE {}".format(total)

    def do_stty(self):
        try:
            fd = os.open(self.slave_name, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            return "ERR open slave failed: {}".format(exc)
        try:
            result = subprocess.run(
                ["stty", "-a"],
                stdin=fd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=5,
            )
            if result.returncode != 0:
                return "ERR stty exited {}: {}".format(
                    result.returncode,
                    result.stdout.decode("utf-8", "replace").strip(),
                )
            payload = base64.b64encode(result.stdout).decode("ascii")
            return "STTY {}".format(payload)
        except (OSError, subprocess.SubprocessError) as exc:
            return "ERR stty failed: {}".format(exc)
        finally:
            os.close(fd)

    def do_recover(self):
        try:
            fd = os.open(self.slave_name, os.O_RDWR | os.O_NOCTTY)
        except OSError as exc:
            return "ERR open slave failed: {}".format(exc)
        try:
            os.write(fd, b"\x1b[r")
            subprocess.run(["stty", "sane"], stdin=fd, timeout=5, check=False)
            return "OK RECOVER"
        except (OSError, subprocess.SubprocessError) as exc:
            return "ERR recover failed: {}".format(exc)
        finally:
            os.close(fd)

    def do_wait(self, timeout_ms_str):
        try:
            timeout_ms = int(timeout_ms_str)
        except ValueError:
            return "ERR bad timeout: {}".format(timeout_ms_str)

        if self._reaped_status is not None:
            return self._format_status(self._reaped_status)

        deadline = time.monotonic() + (timeout_ms / 1000.0)
        while True:
            try:
                wpid, status = os.waitpid(self.pid, os.WNOHANG | os.WUNTRACED)
            except ChildProcessError:
                return "ERR already reaped elsewhere"
            if wpid == self.pid:
                decoded = self._decode_status(status)
                if decoded[0] == "stopped":
                    # A stopped child is NOT reaped: don't cache, so a later
                    # WAIT still observes the eventual exit after SIGCONT.
                    # (The kernel reports each stop transition once; a WAIT
                    # issued while the child stays stopped returns TIMEOUT.)
                    return self._format_status(decoded)
                self._reaped_status = decoded
                # DRAIN BARRIER: the child is dead, so the pty master will
                # hit EOF once buffered output is drained. Join the pump
                # thread (which drains + closes the capture file) BEFORE
                # replying, so a successful WAIT guarantees the capture is
                # complete -- no reply/last-write race.
                self._drain_capture()
                return self._format_status(decoded)
            if time.monotonic() >= deadline:
                return "TIMEOUT"
            time.sleep(0.01)

    @staticmethod
    def _decode_status(status):
        if os.WIFSTOPPED(status):
            return ("stopped", os.WSTOPSIG(status))
        if os.WIFEXITED(status):
            return ("exit", os.WEXITSTATUS(status))
        if os.WIFSIGNALED(status):
            return ("signaled", os.WTERMSIG(status))
        return ("exit", -1)

    @staticmethod
    def _format_status(decoded):
        kind, value = decoded
        if kind == "exit":
            return "EXIT {}".format(value)
        if kind == "stopped":
            return "STOPPED {}".format(value)
        return "SIGNALED {}".format(value)

    def _drain_capture(self, timeout=5.0):
        # Bounded: if an orphaned grandchild still holds the slave open the
        # master never EOFs; reply anyway after the bound rather than hang.
        t = self._pump_thread
        if t is not None and t.is_alive():
            t.join(timeout=timeout)
        with self._capture_lock:
            if self._capture_file is not None:
                self._capture_file.flush()

    def shutdown(self):
        try:
            os.killpg(self.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        # Reap until gone (bounded) so no zombie outlives the wrapper.
        if self._reaped_status is None:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                try:
                    wpid, status = os.waitpid(
                        self.pid, os.WNOHANG | os.WUNTRACED
                    )
                except ChildProcessError:
                    break
                if wpid == self.pid and not os.WIFSTOPPED(status):
                    self._reaped_status = self._decode_status(status)
                    break
                time.sleep(0.01)
        # Close the master so the pump thread hits EBADF/EOF and terminates
        # deterministically even if a grandchild kept the slave open.
        try:
            os.close(self.master_fd)
        except OSError:
            pass
        self._drain_capture(timeout=2.0)


_USAGE = (
    "usage: pty_spawn.py --capture PATH [--winsize ROWSxCOLS] [--cwd DIR] "
    "[--env KEY=VAL ...] -- CMD [ARG ...]"
)


def _parse_args(argv):
    capture_path = None
    winsize = (24, 80)
    cwd = None
    env = {}
    child_argv = None

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            child_argv = argv[i + 1 :]
            break
        if arg == "--capture" and i + 1 < len(argv):
            capture_path = argv[i + 1]
            i += 2
        elif arg == "--winsize" and i + 1 < len(argv):
            try:
                rows_s, cols_s = argv[i + 1].split("x", 1)
                winsize = (int(rows_s), int(cols_s))
            except ValueError:
                raise SystemExit("bad --winsize (want ROWSxCOLS): {}".format(argv[i + 1]))
            i += 2
        elif arg == "--cwd" and i + 1 < len(argv):
            cwd = argv[i + 1]
            i += 2
        elif arg == "--env" and i + 1 < len(argv):
            key, sep, val = argv[i + 1].partition("=")
            if not sep or not key:
                raise SystemExit("bad --env (want KEY=VAL): {}".format(argv[i + 1]))
            env[key] = val
            i += 2
        else:
            raise SystemExit(_USAGE)

    if capture_path is None or not child_argv:
        raise SystemExit(_USAGE)
    return capture_path, child_argv, winsize, cwd, env


def main():
    out = sys.stdout
    try:
        capture_path, child_argv, winsize, cwd, env = _parse_args(sys.argv[1:])
    except SystemExit as exc:
        out.write("ERR {}\n".format(exc))
        out.flush()
        return 2

    child = PtyChild(capture_path, child_argv, winsize=winsize, cwd=cwd, env=env)
    try:
        child.spawn()
    except OSError as exc:
        out.write("ERR spawn failed: {}\n".format(exc))
        out.flush()
        return 1

    out.write("SPAWNED {}\n".format(child.pid))
    out.flush()

    try:
        for raw_line in sys.stdin:
            line = raw_line.rstrip("\n")
            if not line:
                continue
            parts = line.split(" ", 1)
            cmd = parts[0]
            rest = parts[1] if len(parts) > 1 else ""

            if cmd == "SIG":
                reply = child.do_sig(rest.strip())
            elif cmd == "WRITE":
                reply = child.do_write(rest.strip())
            elif cmd == "STTY":
                reply = child.do_stty()
            elif cmd == "RECOVER":
                reply = child.do_recover()
            elif cmd == "WAIT":
                reply = child.do_wait(rest.strip())
            else:
                reply = "ERR unknown command: {}".format(cmd)

            out.write(reply + "\n")
            out.flush()
    finally:
        child.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
