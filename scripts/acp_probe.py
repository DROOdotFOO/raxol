#!/usr/bin/env python3
"""Drive an ACP agent over stdio and record the wire transcript.

A minimal ACP CLIENT: spawns the agent, runs initialize -> session/new ->
session/prompt, answers agent-initiated requests (session/request_permission
included), and records every frame in both directions.

Two uses. It smoke-tests our own ACP surface end to end the way a real editor
would -- catching things no unit test sees, such as non-JSON leaking onto
stdout before frame one. And it is the whole surface an ACP host has to
implement, so it doubles as the reference to hand a prospective integrator.

Dependency-free and language-neutral on purpose: it knows nothing about
Elixir, and should stay that way.

    scripts/acp_probe.py bin/raxol-acp --backend mock
    scripts/acp_probe.py packages/raxol_cli/burrito_out/raxol_cli_macos acp

Writes `acp_transcript.json` (every frame) and `acp_stderr.log` (the agent's
stderr) to the current directory. Run it from a scratch directory.

Environment:
    PROBE_CWD      the cwd sent in session/new (default: this process's cwd)
    PROBE_PROMPT   the prompt text (default: a trivial reply-only prompt)

A `__NON_JSON_STDOUT__` entry in the transcript is a WIRE DEFECT, not a probe
quirk: a strict NDJSON client would fail on that line.

Caveat worth knowing before drawing conclusions from a run: the native-CLI
backends (`--backend claude_native` and friends) run their own tool loop, so
raxol's Actions, cwd scoping and permission gating are not exercised at all.
`raxol acp` warns about this on stderr at boot. Use an API-key backend when
testing those paths.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time

TRANSCRIPT: list[tuple[str, dict]] = []


def record(direction: str, msg: dict) -> None:
    TRANSCRIPT.append((direction, msg))
    tag = "-->" if direction == "out" else "<--"
    print(f"{tag} {json.dumps(msg)}", flush=True)


def reader(stdout, inbox: queue.Queue) -> None:
    for line in stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            record("in", {"__NON_JSON_STDOUT__": line.decode(errors="replace")
                          if isinstance(line, bytes) else line})
            continue
        record("in", msg)
        inbox.put(msg)


USAGE = """usage: acp_probe.py <agent command> [args...]

Drives an ACP agent over stdio and records the wire transcript.

  acp_probe.py bin/raxol-acp --backend mock
  acp_probe.py packages/raxol_cli/burrito_out/raxol_cli_macos acp

Every argument is passed through to the agent verbatim, so the agent's own
flags (--backend, --model, ...) are written after the command. This script
takes no options of its own beyond -h/--help.

Writes acp_transcript.json and acp_stderr.log to the current directory.
Configure with PROBE_CWD and PROBE_PROMPT."""


def main() -> int:
    cmd = sys.argv[1:]
    # -h is answered here rather than forwarded. Forwarding it spawned "--help"
    # as if it were the agent and died with a FileNotFoundError naming a flag,
    # which reads like a probe bug in the agent.
    if not cmd or cmd[0] in ("-h", "--help"):
        print(USAGE, file=sys.stderr)
        return 0 if cmd else 64

    stderr_log = open("acp_stderr.log", "w")
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_log,
            text=True,
            bufsize=1,
        )
    except OSError as err:
        stderr_log.close()
        print(f"acp_probe.py: cannot spawn {cmd[0]!r}: {err}", file=sys.stderr)
        return 127

    inbox: queue.Queue = queue.Queue()
    threading.Thread(target=reader, args=(proc.stdout, inbox), daemon=True).start()

    next_id = [0]

    def send(method: str, params: dict, notify: bool = False) -> int | None:
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        rid = None
        if not notify:
            next_id[0] += 1
            rid = next_id[0]
            msg["id"] = rid
        record("out", msg)
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        return rid

    def reply(rid, result: dict) -> None:
        msg = {"jsonrpc": "2.0", "id": rid, "result": result}
        record("out", msg)
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def await_result(rid: int, timeout: float = 120.0) -> dict:
        """Pump until our reply lands, answering agent-initiated requests."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = inbox.get(timeout=1.0)
            except queue.Empty:
                if proc.poll() is not None:
                    raise SystemExit(f"agent exited with {proc.returncode}")
                continue
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                return msg
            # An agent-initiated request. This is the seam a host UI hangs
            # approve/deny off of.
            if "method" in msg and "id" in msg:
                handle_agent_request(msg, reply)
        raise SystemExit(f"timeout waiting for id={rid}")

    def handle_agent_request(msg: dict, reply_fn) -> None:
        if msg["method"] == "session/request_permission":
            opts = msg["params"].get("options", [])
            allow = next(
                (o for o in opts if o.get("kind", "").startswith("allow")),
                opts[0] if opts else None,
            )
            reply_fn(msg["id"], {"outcome": {
                "outcome": "selected",
                "optionId": allow["optionId"],
            }} if allow else {"outcome": {"outcome": "cancelled"}})
        else:
            reply_fn(msg["id"], {})

    try:
        rid = send("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False,
                                          "writeTextFile": False}},
            "clientInfo": {"name": "acp-probe", "version": "0.1.0"},
        })
        init = await_result(rid, timeout=180.0)

        rid = send("session/new", {"cwd": os.environ.get("PROBE_CWD", os.getcwd()),
                                   "mcpServers": []})
        new = await_result(rid)
        sid = new.get("result", {}).get("sessionId")

        if sid:
            rid = send("session/prompt", {
                "sessionId": sid,
                "prompt": [{"type": "text", "text": os.environ.get(
                    "PROBE_PROMPT", "Reply with exactly: hob-probe-ok")}],
            })
            await_result(rid, timeout=300.0)

        return 0
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        stderr_log.close()
        with open("acp_transcript.json", "w") as fh:
            json.dump([{"dir": d, "msg": m} for d, m in TRANSCRIPT], fh, indent=2)
        print(f"\n[probe] agent exit={proc.returncode} "
              f"frames={len(TRANSCRIPT)}", file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
