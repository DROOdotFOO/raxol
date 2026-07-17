# 03 — Lifecycle / Teardown Test Design (T2d, T2a, T25)

Date: 2026-07-15 · Area: **inline driver profile · scroll-region manager ·
$EDITOR-suspend/resume**. Counterpart to the roadmap units T2d/T2a/T25 in
`../harness-ui-roadmap.md`. Grounded in real code:
`packages/raxol_terminal/lib/raxol/terminal/driver.ex` (init `\e[?1049h…`),
`.../driver/termbox_lifecycle.ex` (`cleanup_terminal/1` — **emits no `\e[r`**),
`.../driver/stty.ex`, `.../driver/sigwinch_handler.ex` (the signal-handler
pattern to mirror for SIGTERM), `test/test_helper.exs` (`SKIP_TERMBOX2_TESTS`
gating).

The whole point of this suite: **teardown correctness is currently untested at
the byte level** — `initialization_test.exs` only asserts the process
terminates (`{:DOWN, …, :shutdown}`), never what bytes hit the tty. Every risk
in this area is a byte-sequence or a terminal-state fact, so the suite is built
on two oracles that make those facts assertable in CI without real termbox.

---

## 0. The four risks this suite pins down

1. **Stuck terminal state after a crash path** — scroll region (DECSTBM), raw
   mode, or input modes left set. Today `cleanup_terminal/1` resets modes +
   alt-screen but **never emits `\e[r`** (it never set a region; T2a will, so
   teardown must too). Regression guard LC-N-REG makes the current miss a
   failing test that flips green after T2a.
2. **Inline profile accidentally entering alt-screen / termbox ownership** —
   today's driver writes `\e[?1049h` at init and termbox owns the tty. T2d must
   emit **no `1049h`** and own no screen. Byte-assert both directions.
3. **$EDITOR / SIGTSTP handoff corrupting region + modes** — inline (non-alt)
   apps must *release* raw mode + region on handoff and *restore* on return.
4. **Teardown promises specific signals can't keep** — SIGKILL and hard
   `System.halt` run nothing. The honest move is to test the *documented
   residual* and the *documented recovery one-liner*, so "it's stuck, here's the
   fix" is a tested fact, not a hope.

---

## 1. Harness design

### 1.1 Two oracles, three tiers

No pty/tty dependency exists in the repo (`grep` for ExPTY/erlexec/:exec →
none). We do **not** add one; the harness is built from two oracles already
available plus a ~70-line vendored python pty wrapper.

**Oracle A — the byte-stream capture.** The inline driver profile (T2d) writes
via an **injected output device** (default `:stdio`; tests pass a capturing
device — a `StringIO` or a collector pid). This is the single most important
testability change the design asks of T2d: *the output sink is a parameter.*
With it, ~70% of the suite is pure, fast, and CI-native — no pty, no termbox.
Assertions are byte-substring / byte-order / byte-absence over the captured
iodata.

**Oracle B — the emulator replay.** Raxol ships a full VT emulator
(`Raxol.Terminal.Emulator` + `ScreenBuffer`) that parses DECSTBM, alt-screen,
DECAWM, cursor visibility. Feed the *captured byte stream* into a fresh
`Emulator` and assert **semantic** post-mortem state: scroll-region top/bottom,
alt-screen flag, cursor row/visibility. This turns "teardown is complete" from
a brittle byte-grep into a state fact — and it is the only way to observe
emulator-level residual (DECSTBM) that a bare kernel pty cannot represent.

**Tier A (pure, always-CI):** Oracle A + Oracle B. Byte sequence, ordering,
1049-symmetry, idempotency, $EDITOR/SIGTSTP *state-transition logic* with the
signal step stubbed. No pty, no termbox. Runs under `SKIP_TERMBOX2_TESTS=true`.

**Tier B (pty-scripted, CI-capable):** a real kernel pty via
`test/support/pty/pty_spawn.py` (python3 is universally present on the CI
image; **no termbox**, because the inline profile is plain `IO.write`). Used
only for facts that need a real controlling tty: real signal delivery to the
BEAM, kernel line-discipline residual (`stty -a`), the kill-9 recovery
one-liner, and job-control (SIGTSTP/SIGCONT) round-trips. Tagged
`@tag :pty` — excluded on Windows (`@tag :unix_only`) and skippable via a
`RAXOL_SKIP_PTY_TESTS` guard for images without python3, but **not** gated by
`SKIP_TERMBOX2_TESTS` (it needs no termbox).

**Tier C (real emulator matrix, never CI):** the human-eye / real-terminal
matrix owned by T0. Tagged `@tag :skip_on_ci` + `@tag :docker` → excluded under
`SKIP_TERMBOX2_TESTS`. Out of scope for this suite except as the provenance of
the token constants below.

### 1.2 The pty wrapper (`pty_spawn.py`)

Vendored at `test/support/pty/pty_spawn.py`. Responsibilities:

- `openpty()`, fork; child `setsid()` + `TIOCSCTTY` so it owns a controlling
  tty, then `execvp` the command (a `mix run` of a mock inline app).
- Parent relays master→a raw capture file (`--capture PATH`) and speaks a tiny
  line protocol on its own stdin: `SIG term|int|kill|tstp|cont` (delivers to the
  child **process group**), `WRITE <hexbytes>` (inject input, e.g. `03` for
  Ctrl-C / `1a` for Ctrl-Z), `STTY` (run `stty -a` against the *slave* fd and
  print it — kernel line-discipline probe), `RECOVER` (`printf '\e[r'` + `stty
  sane` to the slave — the documented one-liner), `WAIT` (reap child, print exit
  status).
- The mock inline app emits a `READY\n` sentinel to a side fd after it has set
  region + raw mode, so the harness knows the "armed" moment precisely (no
  sleeps).

Elixir side: `Raxol.Test.Pty` (in `test/support/`) opens the wrapper as a
`Port`, exposes `sig/2`, `write/2`, `stty/1`, `recover/1`, `await/1`,
`capture/1`. Kill-9 residual/recovery, SIGTERM completeness, and Ctrl-Z/fg all
drive through this.

### 1.3 Signal delivery to the BEAM (design dependency on T2d)

- **SIGTERM.** OTP's `erl_signal_server` already defaults SIGTERM → graceful
  `init:stop()`, which unwinds the supervision tree and runs `terminate/2`. T2d
  must therefore keep the inline Driver/Lifecycle **supervised** so teardown is
  reached — and must defeat the race the code already documents (driver.ex ~494:
  "terminate/2's cleanup write can race supervisor shutdown and take stdio down
  before the terminal is restored"). The pty capture is what proves the byte
  stream is *complete*, not truncated by that race. Highest-value test.
- **Ctrl-C / Ctrl-Z in inline raw mode are NOT signals.** `stty raw … -isig`
  (stty.ex `raw!`) disables ISIG, so `0x03`/`0x1a` arrive as *input bytes*, not
  SIGINT/SIGTSTP. The "SIGINT / Ctrl-C" exit class in inline mode = the app
  reads `0x03` and chooses to quit → normal graceful shutdown → teardown. The
  OS-signal SIGINT path (cooked mode, e.g. during $EDITOR handoff) is a separate
  row and lands on the BEAM break handler — documented, not app teardown.
- **SIGTSTP** for job control must be app-initiated (raise to own pgid) *after*
  releasing raw+region — mirror the SigwinchHandler pattern
  (`:os.set_signal(:sigtstp, :handle)` + gen_event handler) so an externally
  delivered TSTP (cooked windows, or from a parent) also routes through the
  same save path rather than freezing mid-region.

---

## 2. The canonical inline teardown sequence

The suite asserts against one **canonical token order** (T2d owns it; T2a adds
the `\e[r`). Ordering is load-bearing — the negative suite proves each swap
strands the cursor or echoes escapes.

| # | Step | Bytes | Why this position |
|---|------|-------|-------------------|
| 1 | input modes off | `\e[?2004l\e[?1004l\e[?1003l\e[?1006l\e[?1000l` | while raw still on, so not echoed |
| 2 | **release scroll region** | `\e[r` | **before** any absolute move, else move clamps into region |
| 3 | autowrap + cursor restore | `\e[?7h\e[?25h` | before prompt handoff |
| 4 | cursor to real bottom + fresh line | `\e[<rows>;1H\r\n` | region gone, so move is unclamped |
| 5 | stty restore (LAST) | `stty <saved>` / `stty sane` | after all escapes, else cooked mode line-processes them |

**Invariants (each is a negative test):**

- **INV-1** `\e[r` precedes any `\e[<row>;<col>H` targeting a row below the old
  region. Violation ⇒ oracle cursor clamps inside old region (stranded).
- **INV-2** `\e[?25h` + `\e[?7h` precede the final `\r\n`.
- **INV-3** stty restore is the final action, after all escape writes.
- **INV-4** inline emits **no `\e[?1049h`** at init ⇒ **no `\e[?1049l`** at
  teardown. Alt-screen bytes absent both directions (symmetry).

"Teardown complete" = tokens 1–5 all present, in order, AND Oracle-B post-state:
region default, alt-screen false, cursor visible, autowrap on.

---

## 3. Test inventory

### 3.1 POSITIVE — `test/harness/lifecycle/teardown_positive_test.exs`

Exit-class matrix. Each row: drive the class, capture bytes (Oracle A), replay
into emulator (Oracle B), assert teardown complete + INV-1..4.

| ID | Exit class | Tier | Asserts |
|----|-----------|------|---------|
| **LC-P-CLEAN** | graceful stop (`Lifecycle.stop` / normal) | A | tokens 1–5 in order; Oracle-B region default, no alt, cursor shown |
| **LC-P-SIGTERM** | real SIGTERM to BEAM pgid | **B** | capture **complete** (not truncated by shutdown/stdio race); tokens 1–5 present before exit; exit status clean |
| **LC-P-CTRLC** | `0x03` byte in raw mode → app quit | A (+B smoke) | 0x03 handled as input, not signal; normal teardown emitted |
| **LC-P-CRASH** | `raise` inside `update/2` (trapped) | A | terminate/2 still emits tokens 1–5; region released even on crash path |
| **LC-P-VMSTOP** | graceful VM stop (`:init.stop`) | B | teardown runs before VM exit; capture complete |
| **LC-P-CSIR** | T2a acceptance / **regression anchor** | A | teardown **contains `\e[r`** — *fails on current master* (cleanup_terminal emits none), *passes after T2a* |
| **LC-P-NOALT** | T2d init byte-assert | A | init capture contains **no `\e[?1049h`**; teardown contains no `\e[?1049l` (INV-4) |
| **LC-P-EDIT-RELEASE** | $EDITOR handoff, outbound | A | before handoff: `\e[r` + modes-off + `\e[?25h` emitted; region/raw released; **no footer paint** after release |
| **LC-P-EDIT-RESTORE** | $EDITOR return | A | on return: raw re-entered, region re-set, footer **repainted**; history region bytes untouched |
| **LC-P-EDIT-INPUT** | input flow after $EDITOR | B | keystroke after restore reaches dispatcher (event flows) |
| **LC-P-TSTP-SUSPEND** | Ctrl-Z / SIGTSTP, outbound | B | releases region+raw, emits `\e[r`+`\e[?25h`, then suspends; shell prompt usable while suspended |
| **LC-P-CONT-RESUME** | `fg` / SIGCONT | B | re-enters raw+region, repaints footer; history untouched; input flows after resume |

### 3.2 NEGATIVE — `test/harness/lifecycle/teardown_negative_test.exs`

| ID | What it pins | Tier | Asserts |
|----|--------------|------|---------|
| **LC-N-KILL9-RESIDUAL** | honest SIGKILL fact | **B** | after `kill -9` post-READY: capture has **no** teardown tokens; kernel `stty -a` still raw/-echo; Oracle-B fed init-only bytes → region **still set**. Residual is a *tested fact*. |
| **LC-N-KILL9-RECOVER** | documented one-liner works | **B** | run `printf '\e[r'; stty sane` on the slave → `stty -a` sane/echo on; Oracle-B fed `\e[r` → region reset. Recovery is a *passing test*. |
| **LC-N-HALT-RESIDUAL** | `System.halt` skips terminate | B | hard halt emits no teardown (sibling of kill-9); guards anyone wiring the quit path through `halt/0` instead of graceful stop |
| **LC-N-ORDER-REGION** | INV-1 ordering | A | feed *region-reset-AFTER-cursor-move* stream into Oracle-B → cursor clamped inside old region (stranded). Proves ordering matters. |
| **LC-N-ORDER-STTY** | INV-3 ordering | A | stty-restore-before-escapes ⇒ escape bytes appear in cooked/echoed stream (garbage on prompt) |
| **LC-N-DOUBLE** | double-teardown idempotency | A | `cleanup` invoked twice (signal handler + supervisor) → second emission empty-or-identical; no double `\e[r` that repositions; no stty error |
| **LC-N-REG** | current cleanup misses `\e[r` | A | asserts **absence** of `\e[r` in *today's* `cleanup_terminal/1` output — documents the master-state residual; the inverse of LC-P-CSIR (one flips as the other passes) |
| **LC-N-CRASH-IN-EDITOR** | crash while $EDITOR owns tty | A | app crashes mid-handoff: terminate/2 must **not** paint footer/region into the editor's screen (editor owns it); may only restore raw/stty so shell is usable *after* editor exits. Pins the "who restores?" contract. |

### 3.3 Harness self-tests — `test/support/pty/pty_test.exs`

`PTY-SELF-1` wrapper delivers each signal to the child pgid; `PTY-SELF-2`
`STTY` probe distinguishes raw vs sane; `PTY-SELF-3` `RECOVER` resets a
deliberately-stuck slave. Guards the honest tests against a lying harness.

---

## 4. CI posture

- Tier A + Oracle B: **run in CI** under `SKIP_TERMBOX2_TESTS=true`. Pure
  Elixir; no termbox because the inline profile is plain `IO.write` into an
  injected device.
- Tier B (pty): `@tag :pty` + `@tag :unix_only`; runs in CI where python3 is
  present (skips cleanly via `RAXOL_SKIP_PTY_TESTS` otherwise). **Independent of
  `SKIP_TERMBOX2_TESTS`** — needs a real tty, not termbox.
- Tier C: `@tag :skip_on_ci`/`@tag :docker` → excluded under
  `SKIP_TERMBOX2_TESTS`. Manual matrix, owned by T0.

The design's one hard ask of the implementation: **T2d must expose its output
device and its teardown as injectable/callable seams** (an `emit_teardown(device,
state)` function, output device a parameter). Without that, Tier A collapses and
everything falls to slow, flaky pty scripting.

---

## 5. Open questions for the orchestrator

1. **"BEAM halt" is two classes.** `:init.stop`/`System.stop` runs terminate
   (LC-P-VMSTOP, positive); `System.halt` does not (LC-N-HALT-RESIDUAL,
   residual). The roadmap listed "BEAM halt" as a positive teardown class — it
   is only positive for the graceful variant. Recommend the inline quit path be
   contractually graceful-stop, and `halt/0` be documented residual.
2. **Crash-during-$EDITOR ownership (LC-N-CRASH-IN-EDITOR).** Genuine design
   fork: when the app crashes while the editor owns the tty, who restores the
   scroll region? Recommended contract: the app restores **only** kernel line
   discipline (so the shell is sane once the editor exits) and does **not** emit
   region/footer paint into the editor's screen. Needs a T2d/T25 decision to
   pin the test's expectation.
3. **SIGTERM completeness vs the stdio race.** driver.ex already flags that
   terminate's cleanup write can race supervisor shutdown. If T2d cannot
   guarantee a complete flush before VM exit, LC-P-SIGTERM needs either a
   synchronous pre-stop teardown hook or an explicit "best-effort, may truncate"
   downgrade — which then makes SIGTERM a partial-residual class, not a clean
   one. Flagging early because it changes the matrix.
4. **Ctrl-C semantics split.** Confirm the product wants `0x03` as app input
   (T12 keybind) in inline raw mode (assumed here) vs OS SIGINT. The two need
   different tests; the suite currently assumes input-byte semantics.
