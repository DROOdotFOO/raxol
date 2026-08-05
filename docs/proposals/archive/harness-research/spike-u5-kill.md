# Spike U5: Staged Supervised Kill of a Running Turn/Tool

**Type:** throwaway de-risking spike. Pure Elixir/OTP stdlib, no event bus, no
SessionStreamer, no raxol runtime. Script:
`scratchpad/spike_u5_kill.exs` (elixir 1.20.2 / OTP 29, macOS arm64).

**Question:** can we kill a running shell tool (a `Port`) cleanly and fast from
OTP, and what process topology is required? Reviewers flagged: Port-linked
shells don't die cleanly, exit signals through Ports are subtle, `#Port`
messages arrive post-kill, orphaned OS processes are a risk, and the
bounded-wait timeout is empirical not derivable.

---

## What was tried

A `TurnServer` GenServer owns a `Port` opened with
`Port.open({:spawn_executable, "/bin/bash"}, [:binary, :exit_status, args: ["-c", cmd]])`
(process-per-turn: the turn owns the Port directly, no dedicated Port child).

Two tools:
- **rogue**: `trap '' TERM INT; echo MARKER; sleep 300 & child=$!; wait $child`
  bash ignores SIGTERM/SIGINT; the `sleep 300` is a long-lived **grandchild**
  (orphan bait).
- **nice**: `echo MARKER; sleep 300`: dies on the default SIGTERM.

Staged kill = (1) cooperative SIGTERM, (2) bounded wait for the OS pid to go
away, (3) hard kill. Six hard-kill strategies were raced; OS-level liveness was
the ground truth (`ps -p`, child enumeration via `ps -o ppid`, and a
command-line marker sweep), not BEAM's view of the Port.

---

## Empirical numbers (two consistent runs)

| Strategy | coop lands | time-to-death | main pid dead | orphaned grandchild | `#Port` closed | `:exit_status` delivered |
|---|---|---|---|---|---|---|
| nice / SIGTERM to **os_pid** | yes, ~4-11ms | ~11ms | yes | **YES (leak)** | port still open | no |
| nice / SIGTERM to **-pgid** | yes, ~10ms | ~10ms | yes | none | yes | yes (143) |
| rogue / `Port.close` only | no (times out) | **NEVER** (>5s) | **NO** | **YES** | yes | no |
| rogue / `Process.exit(owner, :kill)` | no | **NEVER** (>5s) | **NO** | **YES** | yes | no |
| rogue / `kill -9 os_pid` only | no | ~305ms | yes | **YES (leak)** | port still open | no |
| rogue / `kill -9 -pgid` | no | ~305ms | yes | none | yes | yes (137) |
| rogue / `kill -9 os_pid` + child sweep | no | ~309ms | yes | none | yes | yes (137) |

Notes on the numbers:
- `time-to-death` includes the **300 ms bounded wait** we deliberately sat
  through before hard-killing. The *actual* SIGKILL→gone latency is
  `time_to_death − bounded_wait ≈ 2-4 ms`. The kill is effectively instant; the
  wait dominates and is a policy knob.
- exit codes: 137 = 128+9 (SIGKILL), 143 = 128+15 (SIGTERM): arrive **only**
  when the whole group dies (see gotcha #3).
- Two runs, byte-identical outcomes. No flakiness.

---

## The killer gotchas (all reproduced)

1. **BEAM teardown does NOT kill a signal-ignoring child.**
   Both `Port.close(port)` and `Process.exit(turn_owner, :kill)` closed the
   `#Port` on the BEAM side (`Port.info → nil`) but left the rogue OS process
   **alive forever** (>5s, still running at test end). BEAM closes the pipe fds;
   it does not SIGKILL a program that isn't blocked writing to a closed stdout.
   **Killing the Elixir process that owns the Port buys you nothing** against a
   hostile tool. This is the single most important finding: OTP supervision
   topology is *orthogonal* to actually terminating the OS process.

2. **`kill -9 <os_pid>` orphans grandchildren.**
   Killing just the shell pid left the `sleep 300` grandchild running (leak),
   and, because that grandchild still held the stdout pipe open, BEAM never
   observed EOF, so the port stayed "open" and **no `:exit_status` was
   delivered**. You think it's dead; it isn't.

3. **`:exit_status` is only delivered when *every* holder of the port's stdout
   pipe is gone.** A surviving grandchild suppresses it. So you **cannot** treat
   "received `:exit_status`" as your only death signal, and you cannot treat its
   *absence* as "still running" either. Confirm death out-of-band (OS check) or,
   better, kill the whole group so the pipe fully closes and 137 arrives.

4. **Signaling the top pid doesn't cascade: even for well-behaved tools.**
   `nice / SIGTERM to os_pid` killed bash cleanly but orphaned its `sleep`
   child. Cooperative stop must also target the group, or a polite tool still
   leaks its subprocesses.

5. **Post-kill mailbox is noisy but not surprising.** Draining after kill showed
   only: the tool's own `{port, {:data, …}}`, the expected
   `{:turn_exit_status, 137|143}` in the group-kill cases, and (because the turn
   owner traps exits) a flood of `{:EXIT, #Port<…>, :normal}`: **these are from
   our own `System.cmd` calls for `ps`/`kill`, not the tool.** No late `{:DOWN}`,
   no stray `{port, {:exit_status, _}}` from the killed tool. Takeaway: a
   `trap_exit` turn owner will see unrelated port churn; filter by the *specific*
   port ref, don't pattern-match `{_port, {:exit_status, _}}` loosely.

---

## The one thing that made it work: process-group SIGKILL

macOS has **no `setsid`**, but we don't need it. BEAM's `erl_child_setup`
already spawns each port program as its **own process-group leader**: in every
run `pgid == os_pid`. So the negative-pid kill targets the whole subtree for
free:

```
kill -TERM -<os_pid>   # cooperative, whole group
kill -9    -<os_pid>   # hard, whole group  (== kill -9 -<pgid>)
```

No `setsid`, no manual `setpgid`, no wrapper. Capture `os_pid` at spawn
(`Port.info(port, :os_pid)`) and you can group-kill even after the `#Port` is
gone. (An explicit `kill -9 os_pid` + enumerate-and-kill-children sweep is
equivalent but strictly more work and racier: prefer the group kill.)

---

## Minimal required topology

The kill mechanism is independent of BEAM supervision. One GenServer is enough:

```
TurnServer (GenServer, owns the Port)
  ├─ init:   port = Port.open({:spawn_executable,"/bin/bash"},
  │                            [:binary, :exit_status, args: ["-c", cmd]])
  │          os_pid = Port.info(port, :os_pid)     # capture & keep
  │          (pgid == os_pid, courtesy of BEAM's setpgid)
  └─ interrupt/2 (staged):
       1. kill -TERM -os_pid          # cooperative, whole group
       2. wait ≤ GRACE ms for exit_status OR ps-confirmed death
       3. kill -9   -os_pid           # hard, whole group
       4. confirm death out-of-band (ps), do NOT trust exit_status alone
```

You do **not** need a `DynamicSupervisor` or a dedicated Port-child *for the
kill to work*: `Process.exit` on any BEAM process does not touch the hostile
OS process. Supervision is still worth having for **restart/cleanup ergonomics**
(auto-reap on turn crash via `terminate/2` doing the group SIGKILL, bounded
restart), but it is not what terminates the tool. The load-bearing state is just
`os_pid`.

---

## Timeout finding

The bounded wait cleanly separates the two regimes with a huge margin:

- **nice** tool exits **~4-11 ms** after SIGTERM.
- **rogue** tool **never** exits (waited 5 s, still alive).

A grace window anywhere from ~50 ms to ~500 ms distinguishes them robustly;
there is no ambiguous middle. It is empirical, not derivable, but the gap is
orders of magnitude so the exact value is not delicate. Recommend **~300 ms**
default (headroom for a real tool to flush/cleanup on SIGTERM) then group
SIGKILL. Make it a per-tool parameter.

---

## Bottom line: sizing

**U5 is size M: a single leaf unit: provided the interrupt is built as an
OS-process-group staged kill, not a BEAM-supervision dance.**

The spike collapsed the scary parts:
- "Port-linked shells don't die cleanly" → true for BEAM teardown, but **group
  SIGKILL kills them in ~2-4 ms, deterministically, zero orphans, zero leaks.**
- "exit signals through Ports are subtle" → real (gotcha #3), but sidestepped
  entirely by group-killing + OS-level death confirmation instead of trusting
  `:exit_status`.
- "orphaned OS processes" → happens with pid-only kill; **eliminated** by the
  group kill.
- "topology unknown" → answered: **one GenServer that captures `os_pid`.** No
  DynamicSupervisor required for correctness.
- "timeout not derivable" → true but the regime gap is huge; a fixed ~300 ms
  parameter is safe.

There is **no architectural fork** here: the kill mechanism and the "interrupt
protocol" are the same three lines of code operating on one piece of state
(`os_pid`). Splitting into U5a (process isolation) + U5b (interrupt protocol)
would be splitting a thing that has no seam: process isolation via BEAM
supervision is precisely the approach the spike proved *insufficient*, so U5a as
conceived would be busywork that doesn't advance the kill.

**Recommendation: keep U5 as one size-M unit.** Scope = "TurnServer owns a Port,
captures os_pid, exposes `interrupt/2` = staged group SIGTERM → bounded wait →
group SIGKILL → OS-confirmed death." The only thing that could push it to L is
if turns must run **many concurrent tools** or tools **fork their own daemons
that escape the group** (double-fork / re-setsid), neither is in the current
design; if they appear, revisit with a reaper, not a topology split.
