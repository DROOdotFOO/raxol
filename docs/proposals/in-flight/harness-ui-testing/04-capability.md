# 04 — Test Suite Design: T1 Capability Detection + T3 Degradation Ladder

Status: **design (v1)** · Date: 2026-07-15 · Owner: test-suite designer
Scope: `harness-ui-roadmap.md` units **T1** (capability slice) and **T3**
(degradation ladder). Parent design: `f0-capability-detection.md`. Sibling
capture harness: **T0** (terminal matrix) — this doc defines the fixture format
T0 emits and T1 consumes.

Everything here runs in CI under `SKIP_TERMBOX2_TESTS=true`: **mock/fixture
based, no real terminal, no real clock, no real sleeps.** That constraint is
not a limitation to work around — it is the *forcing function* that shapes the
whole design. The three risks the roadmap names (reply swallowed/leaked, hang
on silence, terminal lies) are only CI-testable if the implementation exposes
**pure seams**. §1 specifies those seams; the suite in §5–§8 targets them.

---

## 0. The one-paragraph thesis

DECRQM/DA reply handling is testable in CI **iff** three things are pure
functions with no process and no wall-clock inside them: (1) a **reply scanner**
that turns a raw byte chunk into `{parsed-replies, leak-free-residual}` by
grammar, not position (extends `background_query.ex:scan/1`); (2) a **probe
reducer** `step(state, event)` where `event` is `{:input, bytes}` **or**
`{:clock, monotonic_ms}` — so the silence-timeout is driven by *injected* clock
events, never `Process.sleep`; (3) a **tier + ladder classifier** mapping a
`%Capabilities{}` record to a mode. The real driver wraps these with an actual
`receive/after` loop and `System.monotonic_time/1`; the tests feed scripted
event lists. Silence-is-the-failure-mode (F0 §2) becomes a table row, not a
flake.

---

## 1. Testable seams (what T1 must expose; the suite assumes this shape)

This is a **design constraint on T1's implementation**, stated here because the
test suite is unbuildable otherwise. If T1 builds a monolithic
`GenServer.handle_info` that sleeps and parses inline, none of §5–§8 can run in
CI. The three seams:

### 1a. `Raxol.Terminal.Capabilities.ReplyScanner` (pure)

Generalizes `BackgroundQuery.scan/1`. Same contract shape — chunk in,
`{result, cleaned}` out — widened to all F0 §3 reply framings.

```elixir
@spec scan(binary(), acc :: t()) :: {t(), leak_free :: binary()}
# acc accumulates parsed replies keyed by grammar+echoed-params:
#   %{osc11: rgb, kitty_kbd: flags, mode: %{2026 => 1|2|0, 2027 => ...},
#     xtversion: {name, ver}, xtgettcap: %{...}, da1: {level, attrs},
#     cell_px: {w,h}, sixel_regs: n, kitty_graphics: bool,
#     sentinel_seen?: bool, partial: binary()}
```

Invariants the suite pins:
- **Grammar dispatch, not position.** A reply is classified by its opening
  framing (`CSI`/`DCS`/`OSC`/`APC`) and its *echoed parameters* (`?2026` in
  `CSI ? 2026 ; 1 $ y`), never "the Nth reply." (F0 §2 corollary 1.)
- **Conservation.** Every input byte is either consumed into `acc` as a reply
  or returned in `leak_free`, in original order. No byte is duplicated,
  invented, or silently dropped. This is *the* anti-leak property.
- **Both terminators.** OSC/DCS/APC close on BEL (`0x07`) **or** ST (`ESC \`);
  accepting only one lets a reply swallow the next (F0 §4).
- **`partial` carries across chunks.** A chunk ending mid-reply parks the
  fragment in `acc.partial`; the next `scan/2` resumes. No re-parse from zero.

### 1b. `Raxol.Terminal.Capabilities.Probe` (pure reducer — the clock seam)

```elixir
new(env :: map(), opts :: keyword()) :: t()
step(t(), event()) :: {t(), [action()]}
  event  :: {:input, binary()} | {:clock, monotonic_ms :: integer()} | :start
  action :: {:write, iodata()}          # emit batched query (once, on :start)
          | {:passthrough, iodata()}    # tmux-wrapped re-issue (F0 §7 step 4)
          | {:extend_deadline, ms}      # first byte seen, sentinel not (F0 §7 step 3)
          | {:leak_free, binary()}      # residual → hand to InputParser
          | {:done, %Capabilities{}}
result(t()) :: :pending | {:done, %Capabilities{}}
```

- Deadlines are computed from `env` (`~100ms` local, `~1s` if `$SSH_*`) and
  compared against the `{:clock, now}` events the driver injects. **No time is
  read inside `step`.** The driver's real loop:
  `write; loop receive bytes -> step({:input,_}); after remaining -> step({:clock, now})`.
- `:start` emits `{:write, batched_query}` with DA1 (`CSI c`) as the last
  byte-group (F0 §2). Under `$TMUX` with passthrough available it may also emit
  `{:passthrough, ...}`.
- On DA1 seen → drain window opens; on drain complete or `{:clock}` past
  deadline → `{:done, caps}`. Unanswered caps default to unsupported.

### 1c. `Raxol.Terminal.Capabilities.Classifier` + `Raxol.Terminal.Degradation.Ladder` (pure)

```elixir
Classifier.classify(acc :: map(), env :: map()) :: %Capabilities{}   # T1
Ladder.select(%Capabilities{}) :: {:ok, mode} | {:error, reason}     # T3
  mode :: :inline_log | :tmux_conservative | :flat
Ladder.assert_capable!(mode, %Capabilities{}) :: :ok | no_return     # T3 guard
```

`Classifier` applies the quirk table (Alacritty, tmux clamp, Windows-platform
gates) *after* the naive grammar parse. `Ladder` is a total function over the
`%Capabilities{}` state space. `assert_capable!` is the fail-loud guard for the
misdetection-consequences test (§7, LAD-N-01).

---

## 2. Fixture schema (shared contract with T0)

T0 runs the real terminal matrix (kitty, iTerm2, WezTerm, Ghostty, Alacritty,
GNOME/VTE, Apple Terminal — each bare / tmux / ssh / ssh+tmux) and **captures
raw reply bytes**. T1's positive suite replays them. One schema, two producers
(T0 real capture; hand-authored edge fixtures), one consumer (this suite).

**Format: JSON**, one file per `capture/<terminal>-<context>.json`. JSON (not
`.exs`) because T0's capture harness is a shell/raw-tty tool, not Elixir, and
because bytes-as-hex is unambiguous across the boundary. Control bytes are
**lowercase hex, no separators** in `reply_hex`; the loader decodes to binary.

```json
{
  "schema": "raxol.capability.capture/1",
  "terminal": "alacritty",
  "terminal_version": "0.13.2",
  "context": "bare",                        // bare | tmux | ssh | ssh+tmux
  "env": {                                   // env seed the probe also sees
    "TERM": "alacritty",
    "COLORTERM": "truecolor",
    "TERM_PROGRAM": null,
    "TMUX": null,
    "SSH_TTY": null
  },
  "query_hex": "1b5d31313b3f071b5b3f753...",// exact batched write (reference)
  "reply_hex": "1b5d31313b7267623a...",     // exact bytes read back, in order
  "notes": "DECRQM 2026 value stuck at 2 (never flips to 1 after set).",
  "expected": {                              // golden — asserted by CAP-P-*
    "identity":       ["Alacritty", "0.13.2"],
    "tier":           "modern",
    "unicode":        "wide",
    "truecolor":      true,
    "sync_output":    true,                  // quirk: 2 is 'recognized' => supported
    "grapheme_width": "assumed",
    "in_band_resize": false,
    "lr_margins":     false,
    "theme_events":   false,
    "kitty_keyboard": null,
    "sixel":          false,
    "multiplexer":    "none"
  },
  "expected_tier": "inline_log"              // T3 ladder golden
}
```

Design points that make it a *shared* contract:
- **`reply_hex` is the whole raw read**, sentinel included, exactly as the tty
  delivered it (including any interleaving T0 happened to capture). The suite
  decodes and feeds it through `ReplyScanner`/`Probe` unmodified — so a T0
  capture is a complete end-to-end regression, not a curated snippet.
- **`expected` is authored once from the first trusted capture** and becomes
  the lock. A terminal upgrade that changes replies fails loudly against the
  golden — exactly the "terminal drift" signal F0 §5 wants (never trust a
  static table for a live session, but *do* pin captures as regressions).
- **`context` drives which risks a fixture exercises.** `tmux`/`ssh+tmux`
  captures are where passthrough-off garble and clamp live (§6).
- **Hand-authored edge fixtures use the same schema** with `terminal:
  "synthetic"` and a `notes` explaining the constructed condition (silence,
  reorder, echo-leak, partial-EOF). They live in `capture/synthetic-*.json`.

**Loader:** `Raxol.Test.CapabilityFixtures.load!(name) -> map` (decodes
`*_hex` → binary via `Base.decode16!(s, case: :lower)`). One table-driven test
iterates `capture/*.json`; adding a T0 capture adds a test with zero code.

Representative real-shape reply bytes (placeholders until T0 lands the true
captures — the schema is stable, the bytes get replaced):

| terminal | 2026 reply | XTVERSION (DCS) | DA1 | classifies |
|---|---|---|---|---|
| kitty | `CSI ?2026;2$y` | `DCS>\|kitty(0.32)ST` | `CSI ?62;c` | inline_log |
| iTerm2 | `CSI ?2026;1$y` | `DCS>\|iTerm2 3.5ST` | `CSI ?62;4c` | inline_log |
| WezTerm | `CSI ?2026;1$y` | `DCS>\|WezTerm …ST` | `CSI ?65;…c` | inline_log |
| Ghostty | `CSI ?2026;1$y` | `DCS>\|ghostty…ST` | `CSI ?62;…c` | inline_log |
| Alacritty | `CSI ?2026;2$y`* | `DCS>\|Alacritty…ST` | `CSI ?6c` | inline_log |
| GNOME/VTE | `CSI ?2026;2$y` | `DCS>\|VTE(0.76)ST`† | `CSI ?65;…c` | inline_log |
| Apple Term | *(silence)* | *(silence)* | `CSI ?1;2c` | flat/core |

\* the "lie": value never flips to 1. † VTE XTVERSION is version-dependent;
older VTE is silence → identity via DA2 fallback.

---

## 3. Fake-clock / timeout pattern (no real sleeps)

**The pattern:** time is an *input event*, never a side effect. `Probe.step`
receives `{:clock, monotonic_ms}`; the test constructs the timeline explicitly.

```elixir
test "silence: no reply → conservative default within one budget, no wait" do
  p = Probe.new(%{"TERM" => "dumb"}, budget_ms: 100)
  {p, [{:write, _}]} = Probe.step(p, :start)
  # advance the fake clock straight past the deadline; feed ZERO input
  {p, actions} = Probe.step(p, {:clock, 101})
  assert {:done, caps} = Probe.result(p)
  assert caps.sync_output == false and caps.tier in [:core, :modern]
  refute Enum.any?(actions, &match?({:extend_deadline, _}, &1))
end
```

No `Process.sleep`, no `assert_receive` timeout, no real elapsed time. The
test *is* the clock. Corollaries:

- **`extend_deadline` (F0 §7 step 3):** feed `{:input, first_byte}` then
  `{:clock, 60}` (< base 100 but the extend budget applies) — assert the probe
  emits `{:extend_deadline, _}` on first byte and only finalizes after the
  *extended* deadline, again purely by clock event.
- **SSH-widened timeout:** two `Probe.new` instances, `env` with/without
  `SSH_TTY`; assert the finalize clock threshold differs (~100 vs ~1000) by
  feeding a `{:clock}` between the two thresholds and checking one is `:done`,
  the other still `:pending`.
- **Bounded time is asserted structurally**, not measured: the property is
  "for any input event stream, `result/1` becomes `{:done, _}` after at most
  one `{:clock, now}` with `now ≥ deadline` — the reducer never requests a
  second extension after the first" (LAD/PROBE fuzz, §8, CAP-F-04).
- The **driver-level** real-clock loop gets *one* `@tag :integration` smoke
  test outside CI's default set, asserting it terminates — but the logic lives
  in the pure reducer where the 30+ timing cases run instantly.

---

## 4. Fuzz strategy (StreamData, reusing repo conventions)

Convention mirrored from `test/property/dcs_parsing_property_test.exs` and
`parser_property_test.exs`: `use ExUnit.Case, async: true` + `use
ExUnitProperties`; `check all(gen, max_runs: N)`; generators `binary/1`,
`integer/1`, `list_of/2`, `member_of/1`, `one_of/1`. Totality assertions
(`assert_sane_result`) already established there.

Two fuzz targets, three generators:

**Target A — `ReplyScanner.scan/2` (the anti-leak surface).**
- `G-noise` = `binary(max_length: 128)` — arbitrary bytes.
- `G-reply` = a StreamData generator that assembles *well-formed* reply
  fragments from a bank: `CSI ? <mode> ; <0..4> $ y`, `OSC 11 ; rgb:… <BEL|ST>`,
  `DCS > | <ascii> ST`, `CSI ? <n..> c`. Params drawn from `integer/1`,
  terminators drawn from `member_of([<<7>>, <<0x1b,?\\>>])`.
- `G-interleave` = `list_of(one_of([G-reply, printable_bytes]))` shuffled —
  models replies interleaved with user keystrokes.

Properties (CAP-F-*):
1. **Totality:** `scan/2` never raises on `G-noise` (any acc). (mirrors DCS
   totality)
2. **Conservation:** for any `G-interleave`, the multiset of bytes in
   `leak_free` = input bytes minus exactly the bytes of the replies parsed into
   `acc`; order preserved. No byte invented/duplicated/dropped.
3. **No-leak-of-replies:** every byte the scanner classified as a reply is
   absent from `leak_free` (so it can never reach the key parser).
4. **No-eat-of-input:** every printable/key byte in `G-interleave` that is *not*
   inside a reply appears in `leak_free`.
5. **Chunk-split invariance:** `scan` fed the input split at an arbitrary index
   across two calls yields the same `acc` and concatenated `leak_free` as one
   call. (partial-reply carry correctness)

**Target B — `InputParser.parse/1` (the app-facing leak surface).**
6. **DECRQM never becomes a keystroke:** for `G-reply`-generated DECRQM/CPR/DA
   sequences, `parse/1` emits **no** `:key`/`:char` event for the reply bytes
   (they're `:consumed`). (regression-locks the `input_parser.ex:197` path)
7. **Totality under prepended reply:** `parse(reply <> G-noise)` never raises,
   never hangs. (mirrors existing parser totality)

**Target C — `Probe` (the timeout/state surface).**
8. **Termination:** for any finite event list mixing `{:input, G-noise}` and
   monotonic-increasing `{:clock, _}`, `Probe` reaches `{:done, _}` after the
   first clock event past the deadline and stays done (idempotent). Never
   `:pending` forever.

---

## 5. POSITIVE suite — reply parsing & classification

IDs `CAP-P-*`. All pure, `async: true`, fixture- or table-driven.

| ID | Name | Feeds | Asserts |
|---|---|---|---|
| CAP-P-01 | matrix golden replay (table over `capture/*.json`) | each fixture `reply_hex` | `Classifier.classify` == fixture `expected` (byte-exact record) |
| CAP-P-02 | sentinel discipline: all replies before DA1 parsed | `OSC11 · 2026;1$y · 2048;1$y · DA1` | all three caps set true; identity present |
| CAP-P-03 | missing-reply-before-sentinel → unsupported, no wait | `OSC11 · DA1` (2026 absent) | `sync_output=false`, probe `:done` on DA1 drain, zero `extend_deadline` |
| CAP-P-04 | both OSC terminators | two fixtures, BEL vs ST | identical parse |
| CAP-P-05 | grammar-dispatch not position | replies emitted in scrambled order (still all pre-DA1) | each cap attributed by echoed params, not slot |
| CAP-P-06 | DECRQM value semantics table | `2026;` with value ∈ {0,1,2,3,4} + silence | {1,2}→supported, {0,3,4,silence}→unsupported (F0 §3) |
| CAP-P-07 | XTVERSION identity parse (DCS `>\|name ver ST`) | per-terminal DCS | `{name, version}` prefix-matched |
| CAP-P-08 | identity fallback to DA2 when no XTVERSION | Apple-Term-shape fixture | identity from DA2/`nil`, tier=core, no crash |
| CAP-P-09 | truecolor priority order | `$COLORTERM=truecolor` vs XTGETTCAP `RGB` vs neither | decided per F0 priority, `$COLORTERM` alone still trusted only as seed |
| CAP-P-10 | cell-px + sixel-regs parse | `CSI 6;h;w t`, `CSI ?1;0;n S` | `cell_px={w,h}`, `sixel` count |
| CAP-P-11 | kitty keyboard flags | `CSI ? <flags> u` | `kitty_keyboard=flags`; absent→`nil` |
| CAP-P-12 | env seed only, non-TTY path | `stdout not tty` | Core-minus, **zero** query emitted (F0 §7 step 0) |
| CAP-P-13 | `:persistent_term` cache round-trip & immutability | classify once | second read identical; re-classify no-ops |
| CAP-P-14 | tmux passthrough-ON re-issue | `context:tmux`, passthrough available | `{:passthrough, wrapped}` emitted, payload < ~60 chars, outer identity parsed |

---

## 6. NEGATIVE suite — the failure modes

IDs `CAP-N-*`. These are the risks the roadmap names. Each is a constructed
`synthetic-*.json` or inline binary.

| ID | Risk | Feed | Assert |
|---|---|---|---|
| CAP-N-01 | **silence → bounded conservative default** | no bytes, `{:clock, deadline+1}` | `:done` conservative; **no real sleep** (fake clock); no `extend` |
| CAP-N-02 | **reordered reply** (OSC after DA1, same chunk/drain window) | `2026;1$y · DA1 · OSC11` | OSC11 still parsed within drain window (grammar dispatch); cap set |
| CAP-N-03 | **late reply after window closed** | OSC11 arrives in a chunk *after* `:done` | classification unchanged, bytes drained not leaked, no crash |
| CAP-N-04 | **interleaved user keystroke** | `"l" · 2026;1$y · "s\r"` | cap parsed **and** `leak_free=="ls\r"` → InputParser yields l,s,enter |
| CAP-N-05 | **Alacritty lie** | `2026;2$y` + Alacritty XTVERSION | quirk table: `sync_output=true`, flagged `no_verify` (never set-then-requery) |
| CAP-N-06 | **tmux passthrough-off garble** | `context:tmux`, garbled/partial reply + `$TMUX` set | clamp to `:tmux_conservative` tier; `sync_output=false`; `$TERM=screen` NOT trusted |
| CAP-N-07 | **echo-leak** (unknown term echoes query) | our `CSI ?2026$p` echoed back verbatim | recognized as non-reply (`$p`≠`$y`), drained; **no** key events; **no** false cap |
| CAP-N-08 | **partial reply then EOF/timeout** | `CSI ?2026;1` (no `$y`) then clock past deadline | cap unsupported; partial bytes drained, not leaked as keys |
| CAP-N-09 | **partial reply then continuation** | `CSI ?2026;1` then next chunk `$y` | cap supported; chunk-split invariant holds |
| CAP-N-10 | **malformed reply** | `2026;$y` (empty), `2026;9$y` (out-of-range), truncated DCS | parse→unsupported/ignored, never crash (also covered by fuzz CAP-F-01) |
| CAP-N-11 | **DECRQM leaked as keystroke regression** | `2026;1$y` through `InputParser.parse/1` | zero `:key` events (locks `input_parser.ex` consume path) |
| CAP-N-12 | **Windows platform gate** | `env` no XTVERSION/pixel/2048, platform=windows | 2048/pixel gated off by *platform*, not DECRQM; no hang (F0 §9) |

---

## 7. LADDER suite — T3 tier selection (regression matrix)

IDs `LAD-*`. `Ladder.select/1` and `assert_capable!/2` are pure — the matrix is
exhaustive-by-construction over the decision-relevant `%Capabilities{}` fields.

**Table-driven `{caps × expected mode}`** (LAD-P-01, one row per case):

| caps condition | expected mode |
|---|---|
| not a TTY / `TERM=dumb` / core-minus | `:flat` |
| `multiplexer == :tmux` (any caps) | `:tmux_conservative` |
| `multiplexer == :screen` | `:tmux_conservative` |
| Core+ with scroll-region floor, no tmux | `:inline_log` |
| Modern/Rich, sync_output true, no tmux | `:inline_log` |
| capable caps but `env` override `RAXOL_FORCE_FLAT` | `:flat` |
| capable caps but `env` override forces inline under tmux | rejected (see LAD-N-01) |

Property (LAD-P-02): `select/1` is **total** — for any `%Capabilities{}` drawn
from a StreamData record generator (each field over its enum/bool domain),
`select/1` returns `{:ok, mode}` in the three-mode set or `{:error, _}`, never
raises. This is the "exhaustive over the record's state space" requirement.

**Flat-mode mechanical assertion** (LAD-P-03): render the *same* fixture
session in `:flat` and assert the output byte-stream contains **no**
cursor-move / CUP / scroll-region sequences (`\e[…H`, `\e[…;…r`, `\e[…A/B/C/D`,
`\e[2J`). Regex/scan over emitted bytes — "NVDA-shaped" is commentary; the
mechanical criterion is the test. (roadmap T3 accept.)

**tmux-conservative assertion** (LAD-P-04): `multiplexer=:tmux` fixture →
`:tmux_conservative`; assert OSC 133/777 marks are emitted-but-noted-inert and
no cap is assumed consumed (clamped record).

**Misdetection-consequences — the fail-loud test** (LAD-N-01, highest value):

```elixir
test "inline mode forced on incapable caps REFUSES, does not corrupt" do
  incapable = %Capabilities{tier: :core, sync_output: false,
                            # no scroll-region floor
                            multiplexer: :none}
  assert_raise Raxol.Terminal.Degradation.IncapableModeError, fn ->
    Ladder.assert_capable!(:inline_log, incapable)
  end
  # and the non-raising surface returns an error, never proceeds:
  assert {:error, :incapable} = Ladder.guard(:inline_log, incapable)
end
```

The system must **fail loud** (raise / `{:error, :incapable}`) rather than emit
inline sequences to a terminal that can't host them (= corruption). Symmetric
guard LAD-N-02: forcing `:flat` on a *capable* terminal is allowed (downgrade
is safe) but emits a `[:raxol, :degradation, :forced_downgrade]` telemetry so a
silent product downgrade is at least *observable* (risk 5, the other half).

---

## 8. FUZZ suite — property tests

IDs `CAP-F-*`. Generators and properties per §4. `max_runs: 500–1000` per repo
convention.

| ID | Target | Property |
|---|---|---|
| CAP-F-01 | `ReplyScanner.scan/2` | totality on `G-noise` — never raises |
| CAP-F-02 | `ReplyScanner.scan/2` | conservation on `G-interleave` — leak_free = input − replies, order kept |
| CAP-F-03 | `ReplyScanner.scan/2` | chunk-split invariance across arbitrary split index |
| CAP-F-04 | `Probe` | termination — done after first clock past deadline, idempotent, never `:pending` forever |
| CAP-F-05 | `InputParser.parse/1` | `G-reply` DECRQM/CPR/DA never yields a key/char event |
| CAP-F-06 | `InputParser.parse/1` | `parse(reply <> G-noise)` never raises (mirrors existing parser totality) |
| CAP-F-07 | `Ladder.select/1` | totality over `%Capabilities{}` record generator |
| CAP-F-08 | `ReplyScanner.scan/2` | no-leak-of-replies + no-eat-of-input (the two-sided keystroke property) |

---

## 9. File layout

```
packages/raxol_terminal/
  lib/raxol/terminal/capabilities/
    reply_scanner.ex          # §1a  (T1)
    probe.ex                  # §1b  (T1)
    classifier.ex             # §1c  (T1)
  lib/raxol/terminal/degradation/
    ladder.ex                 # §1c  (T3)
  test/raxol/terminal/capabilities/
    reply_scanner_test.exs        # CAP-P-02..11, CAP-N-02..10
    classifier_matrix_test.exs    # CAP-P-01 (fixture table), CAP-P-05..13
    probe_clock_test.exs          # CAP-N-01, CAP-P-03, extend/ssh timeout (§3)
    echo_leak_test.exs            # CAP-N-07, CAP-N-11
    tmux_clamp_test.exs           # CAP-P-14, CAP-N-06, CAP-N-12
  test/raxol/terminal/degradation/
    ladder_matrix_test.exs        # LAD-P-01..04, LAD-N-01..02
  test/property/
    capability_scanner_property_test.exs   # CAP-F-01..03, CAP-F-08
    capability_probe_property_test.exs     # CAP-F-04
    capability_ladder_property_test.exs    # CAP-F-07
  test/property/parser_property_test.exs   # extend with CAP-F-05, CAP-F-06
  test/support/capability_fixtures.ex      # load!/1 (JSON+hex decode)
  test/fixtures/capability/capture/*.json  # T0-produced + synthetic-*.json
```

---

## 10. Open questions (for orchestrator / V)

1. **Alacritty semantic (CAP-N-05):** DECRQM `2` = "mode recognized, currently
   reset" — technically *supported* (you can set it). So the generic rule
   already classifies it supported; the quirk is really "don't do a
   set-then-requery verification, because Alacritty's value never flips to 1."
   Is the quirk-table entry `no_verify`, or a hard `sync_output=true` override?
   Design assumes `no_verify`; confirm.
2. **Drain-window bound (CAP-N-02 vs CAP-N-03):** how long after DA1 does the
   scanner keep accepting a reordered OSC reply — same chunk only, or a bounded
   byte/clock window? Affects whether reorder is "parsed" or "drained." Design
   proposes: same read-until-sentinel+drain pass (one `{:clock}` budget); after
   `:done`, late replies are drained-not-parsed. Confirm the boundary.
3. **Fixture ownership:** does T0 commit `capture/*.json` directly into this
   suite's fixture dir, or into a T0-owned dir this suite symlinks/reads? One
   directory = zero-code test growth (§2 loader). Recommend T0 writes here.
4. **`Ladder` env overrides:** the exact env var names for forced-flat /
   forced-inline (`RAXOL_FORCE_FLAT`?) and whether forced-inline-on-incapable
   is a hard raise or a logged refusal-then-flat. Design has both surfaces
   (raise + `{:error,_}`); pick the driver default.
5. **Scroll-region floor definition:** what minimal cap set makes `:inline_log`
   *capable* (DECSTBM support is not directly DECRQM-probeable)? T0's verdict
   (D-PA / fallback triggers) feeds this; until then LAD rows key off
   tier+sync_output as a proxy. Reconcile with T0 when its matrix lands.
```
