# T0 — Inline-Hybrid Keystone: Test Matrix & Verdict Protocol

Date: 2026-07-15 · Status: test design · Owner unit: **T0** (roadmap §2),
gates **D-PA** (roadmap §0), the **T2d** driver profile, the **T3** ladder
tiers, and every downstream unit that paints (T2b/T4/T8/T9/T15/T17).

This document is the *test spec* for T0. T0's deliverable is a **verdict doc**
(schema in §7) produced by running these suites. Until the verdict lands,
nothing in T2\* commits (roadmap §3). The verdict is a data structure, not a
vibe: each matrix cell yields typed observables (§4) that mechanically resolve
D-PA (§7.2) and emit named fallback triggers (§7.3).

---

## 0. What T0 is actually betting, restated as falsifiable claims

The inline-hybrid thesis is a conjunction of terminal behaviors. T0 must
*measure* each, per terminal, not assume it. The claims (C-1..C-8) are the
columns of the matrix; every test proves or refutes one.

| ID | Claim under test | If false → |
|----|------------------|-----------|
| **C-1** | A top-anchored DECSTBM region (`CSI 1;(H-N) r`) scrolls rows 1..H-N; the footer rows H-N+1..H sit **outside** and never scroll away. | region orientation wrong / footer unusable → `:flat` |
| **C-2** | Content that scrolls off the **top** of that region **feeds native scrollback** (recoverable by the terminal's own scroll/copy/find). | scrollback loss → history-in-app fallback, degraded |
| **C-3** | Print-above (position into region, emit, restore) does not disturb the footer or the cursor's logical home. | cursor/footer corruption → `:flat` |
| **C-4** | On resize (SIGWINCH / width change), above-region history does something *survivable* (reflow, or clean freeze at old width) — not the duplicate-frame flood / ghost-column corruption of R-04 §E. | resize corruption → seal at fixed width + gutter, or `:flat` |
| **C-5** | DECSTBM composes with synchronized-output mode 2026 (`?2026h/l`): region repaints bracket cleanly, no torn frame, DECRQM reply is truthful. | Alacritty stuck `Pm=2` → conservative emit / no probe |
| **C-6** | Clean exit / SIGTERM / trapped crash restores a usable shell (modes + `CSI r` reset). | teardown gap → T2a/T2d bug, documented `reset` one-liner |
| **C-7** | Inside tmux 3.x the region survives the pane; OSC 133 marks and DECRQM passthrough behave per a known policy (not silent corruption). | tmux breakage → `:tmux_conservative` tier when `$TMUX` |
| **C-8** | Long-lived region (set once, hold for session) vs Bubble-Tea transient (set→insert→reset per append) — one of the two is corruption-free per terminal. | both fail → `:flat`; one works → T2a picks the algorithm per-terminal |

**D-PA is decided almost entirely by C-2 + C-4.** They answer the only question
D-PA cares about: *how many rows of sealed history remain addressable, and for
how long?* (§7.2). No terminal lets you rewrite rows that have already scrolled
into scrollback — that is a hard invariant across the whole cohort (R-04 §E).
So D-PA is never "(B) rewrite all history freely"; the live question is whether
the **visible tail** (sealed rows still on-screen, above the footer, before
native scroll consumes them) is addressable — that is the only window (B) can
ever own.

---

## 1. Suite shape

Three concentric rings, cheapest/most-automated innermost:

```
 ┌───────────────────────────────────────────────────────────────┐
 │ RING A — CI headless (emitter invariants)                      │
 │   app bytes ─▶ AnsiReplayer ─▶ Emulator grid ─▶ asserts        │
 │   Proves: what we EMIT is well-formed. Runs on every PR.       │
 │   Cannot prove C-2 scrollback-feed (see §3 oracle honesty).    │
 ├───────────────────────────────────────────────────────────────┤
 │ RING B — scripted real-terminal capture (per-cell matrix)      │
 │   spawn app in real terminal ─▶ programmatic get-text ─▶       │
 │   grid + scrollback capture ─▶ per-cell verdict row            │
 │   Proves: C-1..C-8 on the actual emulator. Self-hosted runner  │
 │   or dev machine; NOT public CI (needs GPU/GUI terminals).     │
 ├───────────────────────────────────────────────────────────────┤
 │ RING C — human-eye (perceptual residue only)                   │
 │   flicker, tearing, "does it feel native." One documented pass │
 │   per tier-1 terminal. Never a CI gate; recorded in verdict.   │
 └───────────────────────────────────────────────────────────────┘
```

The discipline: **push every claim as far inward as it will honestly go.**
Byte-shape claims (no `1049h`, no `2J` on resize, region-only repaint bytes,
2026 bracketing, cursor save/restore pairing) are Ring A — provable in CI
against the emulator. Scrollback-feed and resize-reflow are *physical terminal
behaviors the emulator does not model* (§3) and must be Ring B. Flicker is
Ring C.

---

## 2. The matrix

**Terminals (rows):** kitty, iTerm2, WezTerm, Ghostty, Alacritty, VTE
(GNOME Terminal / any libvte), Apple Terminal. Plus **`emu`** = our own
`Raxol.Terminal.Emulator` as the CI reference cell (§3).

**Context × transport (columns):** {plain, tmux 3.x} × {local, SSH}. 4 columns.

7 real terminals × 4 = **28 real cells + 1 emu cell = 29**. Not all 29 run every
test; §5/§6 tag each test with the cells it needs.

**Tier assignment** (drives fallback triggers, §7.3):

- **Tier-1** (must pass C-1/C-2/C-3 for `:inline_log` to be the *default* mode):
  kitty, iTerm2, WezTerm, Ghostty.
- **Tier-2** (must at least *degrade cleanly* — pass C-1/C-3 or fail to `:flat`
  without corruption): VTE, Apple Terminal.
- **Special:** Alacritty — carries the known stuck-DECRQM `Pm=2` quirk (C-5);
  its verdict feeds T1's quirk table specifically.

**Capture capability per terminal** (this is what makes Ring B automatable —
see §3.2):

| Terminal | Programmatic grid+scrollback capture | Automation |
|----------|--------------------------------------|-----------|
| kitty | `kitten @ get-text --extent=all` (incl. scrollback) | scripted |
| WezTerm | `wezterm cli get-text --start-line -N` | scripted |
| iTerm2 | Python API (`session.async_get_screen_contents`) | scripted |
| tmux (any host) | `tmux capture-pane -p -S -N` (captures scrollback) | scripted |
| Ghostty | no stable get-text API (as of 2026) → run *inside tmux*, capture-pane | scripted-via-tmux |
| Alacritty | none → run inside tmux, or `script` PTY tee + human screenshot | scripted-via-tmux / human |
| VTE | none native → inside tmux, capture-pane | scripted-via-tmux |
| Apple Terminal | AppleScript `contents of` (visible only, no scrollback) | scripted-partial / human |

Consequence: **every cell is capturable via `tmux capture-pane`** — but
capture-pane measures *tmux's* emulator, not the host's. So the plain-context
scrollback-feed claim (C-2) on Ghostty/Alacritty/VTE/Apple can only be measured
by native APIs where they exist, and by human screenshot where they don't. This
is called out per-test in §5.

---

## 3. Can raxol_terminal's emulator be the oracle? (design question b)

**Partly — and the boundary is the whole point.** Existing infra already does
this pattern: `test/support/cross_terminal/{ansi_replayer,render_oracle,
sequence_scanner}.ex` feed emitted bytes through `Raxol.Terminal.Emulator` and
assert on the resulting grid (built for R1 incremental render). We reuse it
directly.

### 3.1 What the emu cell CAN be

1. **The Ring-A reference for emitter invariants.** Replay the harness's byte
   stream through `Emulator` and assert grid-level properties: footer rows
   unchanged while history streams (C-3 structural half), region-only bytes,
   no `\e[2J`, 2026 brackets balanced, DECSC/DECRC paired. `Emulator` *does*
   implement DECSTBM (`csi_handler.ex` `top_margin`/`bottom_margin`,
   `commands/scrolling.ex` region-aware `scroll_up`/`scroll_down`), so region
   arithmetic is testable in CI.
2. **One honest matrix cell (`emu`).** Its behavior is a real data point:
   "here is what a from-scratch VT implementation does with our sequences."
   Useful as the always-green baseline and as a regression net for our *own*
   emulator when it hosts Raxol (LiveView/SSH surfaces replay through it).
3. **A fuzz target.** Property tests (§8) generate interleaved seal/repaint/
   resize sequences and assert the emu grid never corrupts — cheap, exhaustive,
   CI-runnable.

### 3.2 What the emu cell CANNOT be

**It does not model native scrollback-feed (C-2).** Verified:
`commands/scrolling.ex scroll_up/4` shifts region lines up via `shift_lines_up`
and **blanks** the vacated rows (`buffer/scroll.ex add_line` is only wired to
full-buffer scroll paths, not region scroll). So when a top-anchored region
scrolls, the emu **discards** the top line rather than pushing it to
scrollback. That is *exactly the per-terminal behavior T0 exists to measure* —
and the emulator gets it wrong (or rather, unspecified) in the one dimension
that matters most. **Therefore the emu can never substitute for the real-
terminal C-2 measurement.** Treating a green emu run as proof of scrollback-feed
would be the single most dangerous false-positive in this whole plan.

Two follow-ons the emu also can't judge: **resize reflow of above-region
history** (C-4 — the emu has no scrollback to corrupt, so it can't reproduce
ghost columns / duplicate-frame flood) and **mode-2026 tearing** (C-5 —
buffering is invisible to a synchronous grid replay). Both are Ring B/C only.

**Rule for the verdict doc:** the `emu` cell may be marked pass on C-1/C-3/C-6/
C-8-structural; it is marked **`n/a`** on C-2/C-4/C-5-perceptual, never `pass`.

### 3.3 The Raxol-hosting-Raxol move, scoped

Yes, we can and should run the harness's inline output *through* our own
emulator as a CI cell — but only for the invariants in 3.1. The tempting
"drive a headless vt100 crate as a scrollback oracle" idea fails for the same
reason: most headless emulators (including vt100-rs, our own) model the *grid*,
not the *terminal's scrollback-on-region-scroll policy*, which is precisely
where kitty/iTerm/VTE diverge. If we want a second software oracle, the only
ones with real scrollback semantics under DECSTBM are full emulators driven
headlessly (kitty `--headless`? no; `wezterm` has a headless multiplexer;
`tmux` is itself a headless emulator). **tmux-as-oracle** is the practical
second reference: `tmux capture-pane -S` gives scrollback content
deterministically and runs in CI — but it measures tmux's policy, which is
itself a matrix cell (C-7), not the host's. Use it as *the* CI proxy for
"is scrollback-feed even plausible," with real-terminal Ring B as ground truth.

---

## 4. Observables (the typed cell outputs)

Every Ring-B test writes one row into the verdict table. A row is a struct:

```
%CellResult{
  terminal:   :kitty | :iterm2 | :wezterm | :ghostty | :alacritty | :vte | :apple | :emu,
  context:    :plain | :tmux,
  transport:  :local | :ssh,
  claim:      :C1 | :C2 | ... | :C8,
  observable: <one of the types below>,
  capture:    :native_gettext | :tmux_capture | :pty_tee | :human_eye,
  automation: :ci | :scripted | :human,
  evidence:   "<path to .cast / screenshot / capture-pane dump>",
  verdict:    :pass | :fail | :partial | :n/a
}
```

Observable types, by claim:

- **C-1 footer-pinned** (bool): after streaming K>region-height lines, are the N
  footer rows byte-identical to what we last wrote them? Capture: get-text of
  rows H-N+1..H before/after.
- **C-2 scrollback-feed** (enum `:fed | :lost | :partial`): after overflowing
  the region by M lines, scroll the terminal back (or `capture-pane -S -M` /
  `get-text --extent=all`) — are the M earliest lines present and intact?
- **C-3 cursor-integrity** (bool): after a print-above cycle, is the logical
  cursor restored to the footer input position; is no footer glyph displaced?
- **C-4 resize-history** (enum `:reflow | :freeze_clean | :ghost | :flood`):
  print 30 lines at width 80, resize to 120 then 60, capture scrollback — one
  of: reflowed to new width / frozen at 80 cleanly / ghost-column garbage /
  duplicate near-frames flooded.
- **C-5 mode2026** (`{decrqm: 0|1|2|3|:none, torn: bool}`): DECRQM reply value +
  whether a bracketed multi-row repaint ever shows a half-painted frame
  (Ring C for `torn`).
- **C-6 teardown** (enum per signal `:clean | :stuck_region | :stuck_modes`):
  for each of {exit, SIGTERM, trapped-crash, SIGKILL}, is the shell usable and
  the region reset afterward?
- **C-7 tmux** (`{region: :ok|:broken, osc133: :forwarded|:inert, decrqm: :ok|:swallowed}`).
- **C-8 algorithm** (`{long_lived: :ok|:corrupt, transient: :ok|:corrupt}`).

`capture` and `automation` are recorded so the verdict is auditable: a `:pass`
captured by `:human_eye` is weaker evidence than one by `:native_gettext`, and
the verdict schema (§7) weights them.

---

## 5. POSITIVE suite — proving the mechanics work

Each test: **ID · claim · setup · bytes · assert · cells · automation · what a
pass buys.**

### T0-P-01 · region orientation & footer pin · C-1

- **Setup:** term H=24, N=3 footer. Inline profile (no `1049h`).
- **Bytes:** `\e[1;21r` (region rows 1..21) · stream 40 lines each `text\r\n`
  into region · paint footer: `\e[22;1H<strip>\e[23;1H<status>\e[24;1H<composer>`
  · between each history write, save/restore around footer: `\e7 … \e8`.
- **Assert:** rows 22..24 byte-identical before/after the 40-line stream
  (get-text diff == ∅); row 21 shows line 40 (region scrolled).
- **Cells:** all 29. **Automation:** Ring A (emu, `:ci`) for the structural
  half; Ring B (`:scripted`) for real terminals.
- **Buys:** C-1 confirmed → footer is a real pinned strip, not a scrolling row.

### T0-P-02 · native scrollback feed · C-2 · **the keystone measurement**

- **Setup:** as P-01.
- **Bytes:** stream 100 numbered lines `LINE-0001\r\n`..`LINE-0100\r\n` into a
  21-row region (79 overflow the top).
- **Assert:** recover scrollback (`kitten @ get-text --extent=all` /
  `wezterm cli get-text --start-line -120` / iTerm2 API / `capture-pane -S -120`)
  → all of LINE-0001..LINE-0100 present, in order, un-duplicated.
- **Cells:** tier-1 + tier-2 real cells, plain + tmux, local + ssh. **NOT emu**
  (marked `:n/a`, §3.2). **Automation:** Ring B `:scripted` where get-text
  exists; `:human` (screenshot scroll-up) for Apple/VTE plain-local.
- **Buys:** C-2 — the single fact D-PA and the whole inline bet rest on.

### T0-P-03 · print-above cursor protocol · C-3

- **Setup:** footer composer has text `PROMPT> hello` with cursor after `hello`.
- **Bytes:** the T2b/T2c shared cursor owner: `\e7` (DECSC) · `\e[21;1H` (into
  region bottom) · emit sealed block lines · `\e8` (DECRC) · repaint footer only.
- **Assert:** after cycle, cursor is at composer col 13 (get-text cursor pos);
  composer content intact; region shows the new block.
- **Cells:** all 29. **Automation:** Ring A structural (emu tracks cursor) +
  Ring B for terminals exposing cursor position.
- **Buys:** C-3 → the T2b↔T2c cursor-ownership protocol is sound (the unpriced
  risk all three triad audits flagged).

### T0-P-04 · long-lived vs transient region · C-8

- **Setup:** two harness builds — (a) set `\e[1;21r` once at start;
  (b) per append: `\e[1;21r` → insert → `\e[r` (Bubble-Tea `insertTop` style).
- **Bytes:** each streams the P-02 100-line load.
- **Assert:** compare C-2 scrollback-feed + C-1 footer-pin between the two per
  terminal; record which is corruption-free.
- **Cells:** tier-1 + Alacritty, plain + tmux. **Automation:** Ring B.
- **Buys:** C-8 → T2a picks its DECSTBM algorithm per-terminal from evidence,
  not from the cohort's assumption that either is universal.

### T0-P-05 · mode-2026 composition · C-5

- **Setup:** capable terminal; footer repaint of 3 rows.
- **Bytes:** DECRQM probe `\e[?2026$p` (record reply) · then wrap a footer
  repaint `\e[?2026h \e[22;1H… \e[23;1H… \e[24;1H… \e[?2026l`.
- **Assert:** DECRQM reply parsed (feeds T1); Ring-C human pass "no torn frame"
  under a 200-row/s stream. On emu: assert brackets balanced, bytes between
  them touch only footer rows.
- **Cells:** kitty/WezTerm/Ghostty/iTerm2 (2026-native) + Alacritty (quirk) +
  emu. **Automation:** Ring A (bracket/row assert) + Ring C (tearing).
- **Buys:** C-5 → 2026 framing is safe to emit where probed true; Alacritty
  quirk characterized for T1.

### T0-P-06 · clean teardown resets region · C-6 (happy paths)

- **Setup:** running inline app.
- **Bytes on exit:** `\e[r` (reset region) · `\e[?25h` (cursor) · mode resets ·
  (no `1049l` — there was no `1049h`).
- **Assert:** for {clean exit, SIGTERM, `kill`+trap}: post-exit, emit a probe
  line at shell — it lands at column 1 full width (region gone); `tput`
  reports full-height scroll region.
- **Cells:** all real cells, local. **Automation:** Ring B `:scripted` (expect:
  spawn, signal, then run `printf 'X\n'` and capture position).
- **Buys:** C-6 happy paths → T2d/T2a teardown is real. (SIGKILL is the NEGATIVE
  test T0-N-05.)

### T0-P-07 · tmux happy path · C-7

- **Setup:** app inside tmux 3.x, one window.
- **Bytes:** P-01 + P-02 loads; also emit OSC 133 `\e]133;A\e\\`..`\e]133;D;0\e\\`.
- **Assert:** `capture-pane -p -S -120` shows fed scrollback (C-2 via tmux);
  footer pinned; record whether OSC 133 reached the outer terminal
  (`kitten @`/`wezterm cli` on the host — expected `:inert` per R-04 §D);
  DECRQM passthrough on/off (tmux ≥3.3a default off).
- **Cells:** tmux column, tier-1 hosts + emu-under-tmux. **Automation:** Ring B.
- **Buys:** C-7 → the `:tmux_conservative` tier is designed from measured tmux
  behavior, not guessed.

### T0-P-08 · SSH transport parity · C-1/C-2 over the wire

- **Setup:** app run over `ssh` to a host, terminal is the *local* one.
- **Bytes:** P-02 load.
- **Assert:** C-2 scrollback-feed still holds; measure added latency budget for
  the DECRQM round-trip (feeds T1's SSH-widened timeout).
- **Cells:** tier-1, ssh column, plain + tmux. **Automation:** Ring B (self-
  hosted runner with an SSH loopback).
- **Buys:** confirms the deployment path `Raxol.SSH` implies (the longcat audit
  flagged SSH-via-tmux as omitted).

---

## 6. NEGATIVE suite — proving we DETECT failure and pick the right fallback

Each negative test **must name the fallback trigger it forces** and the T3 tier
that trigger selects. A negative test passes when the harness *detects* the
condition and degrades correctly — not when the terminal misbehaves.

### T0-N-01 · region does NOT feed scrollback · C-2 fail → history-in-app tier

- **Trigger name:** `scrollback_not_fed`.
- **Setup:** a terminal (or contrived emu cell) whose region scroll discards top
  lines (our own emu literally does this, §3.2 — use it as the fixture).
- **Assert:** the P-02 recovery finds LINE-0001..LINE-0079 **missing** →
  detector flags `:lost` → verdict marks this terminal's cell `C-2 fail`.
- **Fallback:** if a **tier-1** terminal shows `:lost` → `scrollback_not_fed`
  fires → `:inline_log` cannot be default; harness keeps history in an app-side
  buffer (degraded, loses native copy/find) or drops to `:flat`. If tier-2 →
  that terminal pins to `:flat`.
- **Automation:** Ring A (emu is the built-in failing fixture!) + Ring B.
- **Maps to:** T3 tier `:flat` / degraded history buffer.

### T0-N-02 · resize corrupts above-region history · C-4 fail → fixed-width seal

- **Trigger name:** `resize_history_corrupt`.
- **Setup:** stream 30 lines at width 80, then drive `SIGWINCH` 80→120→60 (via
  the terminal's resize API or `stty cols`).
- **Assert:** `capture-pane -S`/get-text scrollback shows `:ghost` (stale-width
  fragments) or `:flood` (>30 near-duplicate frames) → detector classifies.
- **Fallback:** `resize_history_corrupt` → D-PA cannot be (B) for the visible
  tail on this terminal; T2b seals at a **fixed width with a gutter** and
  accepts frozen mis-wrap (R-04 §E's only honest inline answer), OR
  `:flat` if even that floods.
- **Automation:** Ring B only (emu has no scrollback to corrupt → `:n/a`).
- **Maps to:** D-PA option (A) forced; T2b resize policy = freeze-at-seal.

### T0-N-03 · tmux swallows OSC 133 / DECRQM · C-7 partial → tmux_conservative

- **Trigger name:** `tmux_passthrough_off`.
- **Setup:** app inside tmux 3.4 with `allow-passthrough off` (default ≥3.3a).
- **Assert:** OSC 133 not seen on host (`:inert`); DECRQM `\e[?2026$p` gets no
  reply within timeout (`:swallowed`).
- **Fallback:** `tmux_passthrough_off` → when `$TMUX` set, T3 picks
  `:tmux_conservative`: no OSC marks assumed consumed, 2026 emitted-but-not-
  probed (or off), caps clamped. **The harness must not hang** waiting for the
  swallowed DECRQM reply — this is also T1's timeout test.
- **Automation:** Ring B `:scripted`.
- **Maps to:** T3 tier `:tmux_conservative`; T1 timeout policy.

### T0-N-04 · Alacritty stuck DECRQM `Pm=2` · C-5 fail → don't-trust-probe

- **Trigger name:** `decrqm_stuck_reset`.
- **Setup:** Alacritty; probe `\e[?2026$p`.
- **Assert:** reply is `\e[?2026;2$y` (mode "permanently reset") **even though**
  Alacritty renders synchronized output — i.e. the probe lies.
- **Fallback:** `decrqm_stuck_reset` → T1 quirk table: for Alacritty, ignore the
  DECRQM value, fall back to `$TERM_PROGRAM`/version allowlist for 2026, OR emit
  2026 unconditionally (harmless if ignored). Never gate a *feature* on this
  reply.
- **Automation:** Ring B (real Alacritty) — the reply value cannot be faked
  faithfully in CI, but the *handling* (given a `;2` reply, don't disable 2026)
  is Ring A: feed the emu a canned `;2$y` and assert policy.
- **Maps to:** T1 quirk table entry; no tier change (emit-anyway).

### T0-N-05 · mid-frame kill leaves stuck region · C-6 SIGKILL → documented residual

- **Trigger name:** `sigkill_stuck_region` (accepted residual, not auto-fixed).
- **Setup:** app with region set; `kill -9` mid-stream (SIGKILL runs no cleanup).
- **Assert:** post-kill, shell prompt is confined to the old region /
  cursor mispositioned → detector confirms the region persists.
- **Fallback:** **documented, not automatic** (roadmap T2a): the recovery is a
  one-liner (`printf '\e[r'` / `reset`) or a parent-shell trap / external
  wrapper — a dead process cannot reset its own TTY. The test's *pass* is that
  the docs state this and a wrapper-based mitigation (if shipped) works; the
  bare app leaving it stuck is the honest expected result.
- **Automation:** Ring B `:scripted` (spawn, `kill -9`, inspect TTY state).
- **Maps to:** no tier; residual-risk register + optional watchdog unit.

### T0-N-06 · full-screen clear wipes sealed history · C-3/keyframe → forbid 2J

- **Trigger name:** `keyframe_clear_leak`.
- **Setup:** drive the *current* `build_terminal_frame` keyframe path (emits
  `\e[2J` on resize/force_repaint — verified in `backends.ex`) in inline mode.
- **Assert:** after 20 sealed lines, force a keyframe → scrollback/visible
  history is wiped (get-text shows blanks where LINE-* were).
- **Fallback:** `keyframe_clear_leak` → T2c invariant: **`\e[2J` is forbidden on
  the `:inline_log` path**; keyframes clear the footer region only. This is a
  regression *guard*, not a runtime fallback — the Ring-A test asserts the
  inline emit stream contains zero `\e[2J`.
- **Automation:** Ring A `:ci` (byte-stream scan via `SequenceScanner`) — this
  is the cheapest, highest-value guard in the whole suite.
- **Maps to:** T2c keyframe policy; permanent CI regression net.

### T0-N-07 · footer scrolls away (region orientation inverted) · C-1 fail → flat

- **Trigger name:** `footer_not_pinned`.
- **Setup:** deliberately set region = bottom N rows (`\e[22;24r`) — the
  *inverted* orientation the triad warned T0 must not ship.
- **Assert:** streaming history scrolls the footer; get-text shows footer rows
  changing → detector flags inversion.
- **Fallback:** `footer_not_pinned` on any tier-1 → `:flat` (no reliable pinned
  strip). This test also *validates the detector*: run it against the correct
  orientation (P-01) and it must NOT fire (no false positive).
- **Automation:** Ring A + Ring B.
- **Maps to:** T3 `:flat`; guards against the orientation bug in T2a.

### T0-N-08 · scroll-while-streaming loses the tail · C-2 interaction

- **Trigger name:** `scroll_lock_needed`.
- **Setup:** stream continuously; simultaneously the user scrolls the terminal
  back to read (mouse wheel / PgUp).
- **Assert:** does new history land correctly when the viewport is scrolled up?
  Does the footer stay reachable? Capture behavior per terminal.
- **Fallback:** `scroll_lock_needed` → informs whether a product-level scroll-
  lock/reading-mode (pi #4679) is required; if a terminal drops the tail, note
  it as a known interaction limit, not a tier change.
- **Automation:** Ring B `:scripted` (inject scroll events) + Ring C.
- **Maps to:** product backlog (scroll-lock unit), verdict note.

---

## 7. Verdict-doc schema (design question c: result → D-PA input → fallback)

T0's output is `t0-verdict.md` + a machine-readable `t0-verdict.json`. The JSON
is the contract downstream units read.

### 7.1 Cell table (the raw evidence)

```json
{
  "matrix": [
    {"terminal":"kitty","context":"plain","transport":"local",
     "C1":"pass","C2":"fed","C3":"pass","C4":"freeze_clean","C5":{"decrqm":1,"torn":false},
     "C6":{"exit":"clean","sigterm":"clean","crash":"clean","sigkill":"stuck_region"},
     "C7":null,"C8":{"long_lived":"ok","transient":"ok"},
     "capture":"native_gettext","automation":"scripted","evidence":"captures/kitty-plain-local/"},
    {"terminal":"emu","context":"plain","transport":"local",
     "C1":"pass","C2":"n/a","C3":"pass","C4":"n/a","C5":{"decrqm":1,"torn":"n/a"},
     "C6":{"exit":"clean"},"C8":{"long_lived":"ok","transient":"ok"},
     "capture":"emulator","automation":"ci","evidence":"ci"}
  ]
}
```

### 7.2 D-PA resolver (mechanical)

D-PA is computed from C-2 + C-4 across tier-1 cells by this rule:

```
tail_addressable = every tier-1 cell has C4 ∈ {reflow, freeze_clean}
                   AND some non-zero window of sealed rows stays on-screen
                   before native scroll consumes them (measured in P-02).

if  all tier-1  C2 == fed  and  tail_addressable:
      D-PA = (B) soft-owned history  — scoped to the VISIBLE TAIL ONLY,
             re-emit under 2026 frames, bounded depth = measured window.
elif all tier-1 C2 == fed  and  NOT tail_addressable:
      D-PA = (A) seal-time-only      — salience/fold frozen at seal.
else (any tier-1 C2 != fed):
      D-PA = (C) live-region-only    — north-star §3.2 narrowed to viewport;
             history is terminal-owned and never salience-graded.
```

The resolver is code (a pure function over the JSON), so D-PA is reproducible
and re-runnable when a new terminal version ships. **Downstream units
(T8/T9/T4/T15/T17) read `verdict.dpa` and switch their paint scope accordingly.**

### 7.3 Fallback-trigger registry (result → T3 tier)

Each negative test emits a named trigger; the registry maps trigger → mode
selection at startup:

```json
{
  "triggers": {
    "scrollback_not_fed":     {"tier1_effect":"inline_log_not_default","tier2_effect":"flat","t3_mode":"flat|history_buffer"},
    "resize_history_corrupt": {"effect":"dpa_force_A + fixed_width_seal","t3_mode":"inline_log"},
    "tmux_passthrough_off":   {"env":"$TMUX","t3_mode":"tmux_conservative"},
    "decrqm_stuck_reset":     {"terminal":"alacritty","effect":"t1_quirk_emit_anyway","t3_mode":"inline_log"},
    "sigkill_stuck_region":   {"effect":"documented_residual + optional_watchdog","t3_mode":null},
    "keyframe_clear_leak":    {"effect":"forbid_2J_ci_guard","t3_mode":null},
    "footer_not_pinned":      {"tier1_effect":"flat","t3_mode":"flat"},
    "scroll_lock_needed":     {"effect":"product_backlog_scroll_lock","t3_mode":null}
  }
}
```

T3's startup mode picker is: `caps + $TMUX + verdict.triggers → :inline_log |
:tmux_conservative | :flat`. The verdict makes that decision *data-driven and
testable*, closing the triad's "T13 can go green while broken" gap.

### 7.4 Go/No-Go

```
GO for :inline_log default   ⟺  all tier-1 cells pass C1+C3 AND C2==fed
                                 AND no tier-1 emits footer_not_pinned.
GO with narrowed D-PA        ⟺  above but C2/C4 force (A) or (C).
NO-GO (flat primary)         ⟺  any tier-1 fails C1 or C3, or C2==lost on
                                 a tier-1 with no acceptable history-buffer fallback.
```

---

## 8. Automation summary & CI wiring

| Ring | Where it runs | What it proves | Tests |
|------|---------------|----------------|-------|
| **A — CI headless** | every PR, `mix test`, via AnsiReplayer/RenderOracle/SequenceScanner + StreamData | emitter invariants: no `1049h`, no `2J` (N-06), region-only bytes, 2026 brackets, cursor DECSC/DECRC pairing (P-03), N-04 policy-given-canned-reply, N-01 against the emu failing fixture | P-01(struct), P-03(struct), P-05(struct), N-01, N-04(policy), N-06, N-07(struct) + property fuzz (§8.1) |
| **B — scripted real-terminal** | self-hosted runner / dev machine, `mix t0.matrix` driver spawning each terminal + get-text/capture-pane | C-1..C-8 ground truth on real emulators | P-01..P-08, N-01..N-03, N-05, N-07, N-08 |
| **C — human-eye** | one documented pass per tier-1, recorded in verdict | flicker/tearing residue (C-5 `torn`), "feels native" | P-05(tearing), N-08(feel) |

### 8.1 Property tests (Ring A, CI)

Add `test/property/t0_inline_emit_property_test.exs` (StreamData, following the
existing `test/property/*` shape):

- **Invariant IE-1:** for any interleaving of seal/footer-repaint/resize ops, the
  emitted stream on the `:inline_log` path contains zero `\e[2J` and zero
  `\e[?1049h`. (guards N-06, driver profile T2d)
- **Invariant IE-2:** every `\e7`/`\e[s` is matched by a later `\e8`/`\e[u`
  before any footer glyph write (cursor protocol P-03).
- **Invariant IE-3:** replaying any generated stream through `Emulator`, footer
  rows change **only** inside a footer-repaint op — never during a seal op.
- **Invariant IE-4:** every mode-2026 `h` is balanced by an `l` and all bytes
  between touch only footer rows (P-05 structural).

These four run in CI forever and are the permanent regression net that lets the
Ring-B matrix be re-run only on terminal-version bumps.

### 8.2 The `mix t0.matrix` harness (Ring B tooling)

A dev task, not shipped: reads a `matrix.exs` cell list, for each cell spawns
the terminal (or attaches over its control socket), runs the app with a scripted
input tape, captures via the cell's `capture` method, classifies observables per
§4, appends a `CellResult` row. Emits `t0-verdict.json`. Idempotent and
re-runnable; asciinema `.cast` + screenshots stored as `evidence`.

---

## 9. Open questions (for the orchestrator)

1. **Self-hosted runner reality:** Ring B needs GUI terminals + GPUs; no public
   CI runs kitty/iTerm. Is there a Mac + Linux self-hosted runner budget, or is
   Ring B a manual-on-demand suite gated to release checkpoints?
2. **tmux-as-oracle trust:** we propose `capture-pane -S` as the CI proxy for
   scrollback-feed. It measures tmux, not the host. Acceptable as a *plausibility
   gate* with Ring B as ground truth — or does D-PA need real-terminal C-2 before
   any T2\* commit? (Recommend: yes, block on ≥2 tier-1 real C-2 measurements.)
3. **Apple Terminal / VTE C-2 without get-text:** these have no scrollback API.
   Accept human-screenshot evidence for their C-2 cells, or run them only inside
   tmux (measuring tmux, not them) and mark host-C-2 `:unmeasured`?
4. **Ghostty version pinning:** get-text API status changes fast; pin a version
   in the verdict so re-runs are comparable.
5. **Does D-PA (B)'s "visible tail window" survive real scroll-while-stream
   (N-08)?** If the user scrolls, the tail window's addressability assumption may
   break — may collapse (B)→(A) even where C-2/C-4 permitted (B).
```
