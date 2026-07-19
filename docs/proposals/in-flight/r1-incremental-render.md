# R1 — Incremental terminal rendering (diff the grid, one emit vocabulary)

Status: **draft / design (v3)** · Date: 2026-07-15 · Owner: V + Claude
Parent: `raxol-problems-backlog` R1 · Depends on nothing · Preserves ADR-0029
(the terminal cell model), esp. invariant 5 (the frame owns its geometry)

Spine decision: **diff the grid the runtime already keeps, and emit every frame —
keyframe or diff — in one absolute-CUP vocabulary.** The previous frame already
exists in `state.buffer` as the same `ScreenBuffer` the next frame is; compare
per row, emit changed rows absolutely addressed (`\e[{y};1H\e[0m\e[2K` + row). A
keyframe is just the diff with *every* row in the changed set. No shadow state,
no string split, no `\r\n`-joined serialization anywhere.

> v3 supersedes v2 (grid-diff, but keyframe still on the legacy `\e[H\e[2J` +
> `\n`-joined `render/1`) and v1 (string-line-diff). Two review rounds
> (adversarial, lateral, empirical ×2) drove it. Empirically, the legacy keyframe
> does not round-trip a multi-row frame through Raxol's reference emulator (rows
> collapse); the CUP keyframe does. v1/v2 designs are retained as alternatives (§3).

---

## 1. Problem (ground truth)

Every render to a live terminal clears the whole screen and repaints the entire
frame, regardless of how little changed.

`lib/raxol/core/runtime/rendering/backends.ex`:

- `render_to_terminal/2:17` builds a fresh `ScreenBuffer`, calls
  `Raxol.Terminal.Renderer.render/1` for the whole frame as one `\n`-joined
  string, prepends `"\e[H\e[2J"` at `:32`, writes it with `IO.write/1`, and stores
  the buffer back into state (`:47`) — so next frame it is the *previous* frame,
  in hand, unused.
- `render_to_ssh/2:163` does the identical thing for SSH (`:170`).

Three distinct defects (previously bundled as "flicker + bytes"):

1. **Flash.** `\e[2J` blanks the screen before repaint. **Already mitigated** on
   mode-2026 terminals — the Engine sets `sync_output` (`engine.ex:86`) and
   `backends.ex:34-40` wraps the frame in `\e[?2026h…?2026l`, so
   kitty/iTerm2/WezTerm/Ghostty commit atomically. Real only on non-2026 terminals.
2. **Bytes.** The whole screen is repainted every event, over SSH even for one cell.
3. **Wasted work.** The full frame string is *rebuilt* every frame (~10k cells of
   per-cell SGR construction) then thrown away when nothing changed. The word
   "incremental" should address this; a transmit-only diff doesn't.

And a latent correctness issue the empirical pass surfaced: the current `\e[H\e[2J`
+ `\n`-joined repaint does **not** round-trip through Raxol's reference emulator —
a multi-row frame collapses (content rows pile onto row 1), width-independently.
Real xterm-class terminals cook `\r\n` correctly, so this is an emulator trait, not
a production bug — but it means absolute-CUP addressing is the *only* emit the test
harness can validate, which (see §3) is the reason the keyframe must use it too.

## 2. Prior art (6-framework survey, 2026-07-15)

Universal invariants across ncurses, notcurses, tcell, ratatui, prompt_toolkit,
Bubble Tea:

1. **One authoritative grid is the model; the diff is a projection of that grid.**
   Raxol has it — `ScreenBuffer` in `state.buffer`.
2. **Resize → both buffers to new size → invalidate previous → one full repaint.**
3. **A full-repaint escape hatch always exists** (ncurses `redrawwin`, tcell
   `Sync`, the universal `Ctrl-L`).
4. **Wrap the emit in mode 2026.** Raxol already does.

Everyone shares: absolute-move to a changed run's start then let the terminal
advance; SGR only on style change (pen elision). The one thing only ncurses does —
cursor-motion cost model + scroll detection — is skipped by every modern framework;
§12 covers the one place (scroll) that costs us, and why it doesn't here.

Bubble Tea diffs the rendered *string* because a string is all it has (its `view`
returns text, no grid). Raxol owns the grid; projecting its serialization and
re-parsing it (Alternative A) adopts Bubble Tea's workaround while owning the thing
the workaround compensates for. Invariant #1: the diff projects the grid, not bytes.

## 3. Decision: diff the grid; one emit vocabulary for keyframe and diff

At the moment `render_to_terminal/2` runs it holds `state.buffer` (previous
`ScreenBuffer`) and builds `updated_buffer` (this frame's) — same struct type.
Compare per row; emit the changed rows. **A keyframe is the same emit with every
row treated as changed** (plus a leading `\e[2J`).

**The one emit primitive** — for a set of row indices `Y`:

```
[if keyframe: "\e[2J"] <> for y in Y: "\e[#{y + 1};1H\e[0m\e[2K" <> render_row(buffer, y)
```

- diff frame: `Y` = rows where `prev.cells[y] != next.cells[y]`
- keyframe:   `Y` = all rows, prefixed with `\e[2J`

Per-piece (ADR-0029 inv 5):

- `\e[{y};1H` — absolute move to col 1 of row `y`; safe under DECAWM-off (a
  full-width row's last cell doesn't auto-advance, nothing wraps). **No row
  separators are emitted at all**, so the `\r\n`-vs-bare-`\n` hazard — and the
  reference-emulator row-collapse of §1 — cannot occur, for *either* frame kind.
- `\e[0m` — reset pen before the erase so `\e[2K` on a `bce` terminal clears to the
  canvas, not a stale bg (inv 2).
- `\e[2K` — erase the line. Mostly redundant today (dense grid — `Cell` defaults
  `char: " "` — a re-emitted full-width row overwrites every column); load-bearing
  for the wide-char-shrink case and future trailing-blank trimming.
- `render_row(buffer, y)` — the existing per-row render (§7/§10-G1), `\e[0m`-
  terminated per run.

Why one vocabulary matters: v2 kept the keyframe on the legacy `\e[H\e[2J` +
`\n`-joined `render/1`, which the empirical pass showed does not round-trip a
multi-row frame on the reference emulator — so frame 0 and every recovery re-emit
rode the one path the harness can't validate and the doc condemns as Alternative
A's sin. Making the keyframe an all-rows CUP emit collapses keyframe and diff into
**one code path** (they cannot diverge), round-trips on the validation substrate,
and costs ~+9% bytes over the `\n`-join on the rare keyframe — paid only on first
frame / resize / Ctrl-L, and wrapped in mode-2026 sync when supported.

**Alternatives considered:**

- **A — line-diff the rendered string** (v1). Rejected: the row-join byte and an
  in-cell `\n` are the same byte, so one newline-bearing cell injects a phantom row
  and desyncs every `\e[y;1H` (empirically demonstrated). Also re-renders the whole
  frame every frame (defect #3). Its §7 "blocker" was a framing artifact.
- **A′ — grid-diff but legacy keyframe** (v2). Rejected: split emit vocabulary; the
  keyframe path doesn't round-trip on the harness (§1).
- **B — cell-diff (sub-row spans).** Deferred: needs wide-char trailing-column
  machinery (ratatui carries ~8 tests for it). Option C composes toward it — inside
  a changed row you already hold old+new cell lists, so span refinement is a later
  local edit in one function.

## 4. Inputs / outputs

Signatures unchanged. **No new frame-state field** — uses `state.buffer` (previous
frame, `backends.ex:47`). Adds one transient recovery flag:

```
state.force_repaint :: boolean   # set by Ctrl-L and by :update_size (resize); next frame is a keyframe
```

- **Input:** `cells` + `state` (with `state.buffer` = previous `ScreenBuffer` | nil).
- **Output:** `{:ok, %{state | buffer: updated_buffer, force_repaint: false}}`.

Row comparison operates on `ScreenBuffer` rows (`buffer.cells`, list of lists of
`Cell`), never on strings.

Why a flag and not `buffer = nil`: the tidy "set `buffer = nil` so the existing
`prev == nil` arm fires" is foreclosed — `handle_call(:get_buffer, …)`
(`engine.ex:191`) reads `state.buffer` as "last composed frame" for Headless/MCP
screenshots. `buffer` already carries "last composed"; conflating it with "what the
terminal shows" is the two-jobs trap. `force_repaint` is the minimal split of those
meanings — the ADR-0029 move, carried by a flag.

## 5. Data flow

```
view(model) → cells → ScreenBuffer.new + write_char   (apply_cells_to_buffer/2, backends.ex ~:231)
                        └─ updated_buffer

prev = state.buffer                                   (previous frame, same type; may be nil)

Y, keyframe? =
  if prev == nil or state.force_repaint or dims(prev) != dims(updated_buffer):
     all_rows, true
  else:
     [y for y in 0..h-1 if prev.cells[y] != updated_buffer.cells[y]], false

frame = (if keyframe?: "\e[2J") <> Enum.map_join(Y, fn y ->
          "\e[#{y+1};1H\e[0m\e[2K" <> render_row(updated_buffer, y) end)

wrap in \e[?2026h / \e[?2026l  if sync_output          (existing, backends.ex:34-40)
IO.write(frame) | io_writer.(frame)
Recorder.record_output(frame)  if recorder alive        (existing, backends.ex:43)
→ {:ok, %{state | buffer: updated_buffer, force_repaint: false}}
```

`prev.cells[y] != updated_buffer.cells[y]` is one Elixir term compare per row over
lists of `%Cell{}` (each carrying a nested `%TextFormatting{}`), short-circuiting on
the first differing cell — empirically it catches style-only changes (same char,
fg red→blue) and skips identical rows. An unchanged row costs one comparison and
**no rendering** (fixes defect #3).

Safe-direction caveat: `%Cell{}` also carries `dirty`/`wide_placeholder`/`sixel`; a
`dirty`-flag flip alone compares unequal, so an inconsistently-set `dirty` would
*over*-emit a row, never *miss* a real change. No correctness risk to the trigger.

## 6. Resize / first frame / recovery

Keyframe (all-rows emit) fires on:

- **First frame** — `prev == nil`. Terminal's prior contents unknown; `\e[2J` +
  all-rows CUP is the correct clean start.
- **Resize** — **owned by the `:update_size` handler, not a render-time dims check.**
  `engine.ex:142-150` (`handle_cast({:update_size, …})`) replaces `state.buffer`
  with a fresh blank `ScreenBuffer.new(w, h)` of the *new* size, so by render time
  `dims(prev) == dims(next)` and a render-time dims guard **never fires** — and a
  diff against that blank grid would leave stale pre-resize rows unrepainted. So
  `:update_size` must **set `force_repaint`**. The `dims(prev) != dims(next)` check
  in §5 stays only as defense-in-depth.
- **Recovery — `Ctrl-L`.** A terminal is externally disturbable (stray `IO.puts`,
  BEAM error report, SSH banner, NIF `printf`); today's clear-every-frame self-heals
  in one frame, a diff does not (unchanged rows never re-emit → corruption is
  permanent). `Ctrl-L` sets `force_repaint` — the 45-year curses idiom, making
  corruption *user*-recoverable (ADR-0029's "what happens when the terminal is not
  mine?"). Empirically, the keyframe deterministically wipes out-of-band corruption
  where a no-op diff cannot. No existing binding claims `Ctrl-L` (`G4`).

Cut from v2: the periodic every-N-frames keyframe (statistical insurance against a
deterministic problem — `Ctrl-L` + resize repair it deterministically) and the
**resume/focus trigger** (no SIGCONT/focus-in machinery exists, and real resume
recovery needs driver-level termios/alt-screen/DECAWM re-init, not a repaint flag —
future work, with scroll).

## 7. Why the existing diff/damage machinery is not reused

The repo has three change-detection mechanisms; none is usable here, and that is
fine — this design builds the minimal live one at the only live call site:

- **`Core.Renderer.render_diff/2`** (`renderer_compat.ex:70`) — reads `old.lines`;
  `ScreenBuffer` has `:cells`, no `:lines` → `KeyError`; and keys
  `:fg_color`/`:bg_color` vs the live `:foreground`/`:background` → silent colour
  drop. **Dead** (zero production callers). v1 mistook "can't reuse this" for
  "can't diff the buffer."
- **`UI.Rendering.DamageTracker` + `RenderBatcher`** — live-looking, but the only
  caller is `mix raxol.bench` (`raxol.bench.ex`). **Dormant.**
- **`ScreenBuffer.damage_regions`** (`screen_buffer.ex:413-428`) — populated only by
  emulator-side `mark_damaged`; the render path builds a *fresh* buffer each frame
  so it is structurally always `[]`. Using it would require a persistent mutable
  buffer — a far bigger change than the diff.

This design compares the two `ScreenBuffer`s already in hand. No `Core.Buffer`, no
bridge, no resurrection.

## 8. Invariants preserved (ADR-0029)

- **Inv 5 (frame geometry) — strengthened.** Both frame kinds emit absolute-CUP
  rows with no separator, relying on DECAWM-off (set once, `driver.ex:191`). The
  bare-`\n`/`\r\n` hazard the ADR's failure table records cannot occur. Empirically
  the CUP emit round-trips through the reference emulator (keyframe *and* diff)
  where the legacy `\r\n` join does not.
- **Inv 2 (transparency).** A rendered row's bytes are byte-identical to today's;
  the only additions are the leading `\e[{y};1H\e[0m\e[2K`, and `\e[0m` is exactly
  what stops `\e[2K` painting a bg. Empirically a shrunk row's tail lands `nil`-bg,
  matching a full repaint cell-for-cell.
- **Recording.** Recorder gets the same bytes. Asciinema v2 is pure-delta replay
  from frame 0; frame 0 is always a keyframe, so `[keyframe][diff…]` replays
  correctly (now via the CUP keyframe, which round-trips on the harness) and is
  smaller than today's `[full][full]…`.
- **New invariant to enforce (§10-G5).** In-cell control bytes. Today
  `normalize_frame` rewrites `\n → \r\n` inside cells too, and clear-every-frame
  self-heals any spill. Under diff a `Cell` holding `\n` corrupts its row tail and
  bleeds onto row y+1 *permanently* (y+1 unchanged → never repainted). ADR-native
  fix: sanitize C0 out of `Cell.char` at the write boundary (make the invalid cell
  unrepresentable), plus a display-integrity test.

## 9. Companion change: style batching (re-prices this proposal's own numbers)

`render_to_terminal` calls `Renderer.new(updated_buffer)` → `style_batching \\
false` (`renderer.ex:131-136`) → one SGR + `\e[0m` **per cell** (~40 B/cell
measured). Flipping `style_batching: true` (run-merge adjacent same-style cells into
one SGR, keeping per-run `\e[0m`) is empirically **8–28× smaller** on run-structured
styled UIs (8.15× at 80-col, 17× at 300-col, 28× on flat panels), **1.0× only on
per-cell-unique gradients**, and round-trips to an identical grid in every case.

It is separable (per-Renderer-instance flag, flipped only at this call site; the
other production `Terminal.Renderer.render` caller keeps the `false` default) and
ADR inv-2 safe (each run still `\e[0m`-terminates). Ship as **companion PR #1**.

**It re-prices this proposal's own §11/§12 numbers** — the worst-case byte bound
below is stated post-batching for that reason.

## 10. Open gaps (author input before implementation)

- **G1 — expose per-row rendering.** `render_row_optimized/3` (`renderer.ex:167`)
  is private; `render/1` *is* `cells |> Enum.map_join("\n", &render_row_optimized/3)`
  with no-op cursor/font wrappers and `cursor: nil`. Empirically an isolated row is
  byte-identical to its full-frame slice with zero cross-row pen state. So G1 = a
  3-line public `render_rows/1` delegate + a pin test `render(r) ==
  Enum.join(render_rows(r), "\n")` guarding against future drift (a real cursor
  stub, cross-row pen elision).
- **G5 — C0 sanitization** at the write boundary (`transform_cells_for_update`,
  `backends.ex ~:295`) + display-integrity test. See §8. **Must close** (diff makes
  in-cell control bytes persistent).
- **G2 — wide-char row math.** Row length ≠ column count with CJK/wide cells; the
  CUP+`\e[2K` emit is width-agnostic so it holds, but any later per-span refinement
  (Option B) must use display width, not string length.
- **G3 — SSH `io_writer` back-pressure.** Does any SSH consumer assume a full frame
  per call? Audit before switching `render_to_ssh`. Terminal path ships first.
- **G4 — `Ctrl-L` wiring.** Route the redraw key to set `force_repaint`. Confirmed
  no existing binding claims it.

## 11. Validation architecture (autonomous, no human, no tty)

The oracle already exists and this whole review used it: emit the bytes, replay them
through `Raxol.Terminal.Emulator` (via `Raxol.Test.CrossTerminal.AnsiReplayer`),
compare the resulting **grid** to the intended `ScreenBuffer`. Machine-checkable,
headless, deterministic (the render path has no NIF/clock/randomness — `Raxol.FATE`
already pins this). The design principle that makes it autonomous:

> **Assert the semantic grid, never the byte string.** Byte-golden tests (FATE
> hashes, the button `.snap` files) pin the wrong thing — they fail on *correct*
> refactors and need a human to re-bless (we regenerated them twice this cycle, for
> transparency and again here). Round-trip-to-grid asserts meaning, so it survives
> batching, pen-elision, and the CUP reshaping. **Policy: an R1 change may not add a
> byte-golden assertion where a round-trip assertion is possible.** Byte-golden is
> reserved for the few places bytes *are* the contract (every run `\e[0m`-terminated).

### Oracles (each computes "expected" from the model — no golden data)

1. **Grid identity** — `replay(emit(buf)) == buf`. The buffer is the spec; expected
   isn't stored, it's the model. Non-circular: emit (Renderer→bytes) and check
   (Emulator→grid) are independent modules.
2. **Diff ≡ full (metamorphic)** — `apply(gridA, diff(A,B)) == apply(blank,
   keyframe(B))`. Two paths to one screen must agree; neither is golden. This is the
   relation that autonomously catches the dead-resize-guard class (a diff leaving
   stale rows diverges from the keyframe that repaints them). **Blind spot (spike-
   verified):** it cannot catch a bug that afflicts *both* emit paths equally — an
   in-cell `\n` corrupts keyframe and diff identically, so they still agree. Oracle
   1 is what catches that, because it checks against the buffer's own text, not
   against a second emit. The flow needs both; the adversarial L1 generator (below)
   must be paired with **oracle 1** to discover G5.
3. **Desync/recovery (stateful)** — after out-of-band corruption + a no-op frame,
   grid ≠ intended; after corruption + `Ctrl-L`, grid == intended.
4. **Stability** — same model twice → 2nd emit has no `\e[...H`; `render(m)`
   byte-stable across runs.

### Four layers

- **L0 — deterministic oracle fixtures** (default suite, unit, ms). A `render_oracle`
  helper wrapping `AnsiReplayer`; every row of the matrix below is a one-liner over
  it. The Emulator is pure Elixir, so a small-frame round-trip is microseconds —
  this is what makes round-trip a *unit* test, not an integration one.
- **L1 — generative property** (`StreamData`). Generate `ScreenBuffer` pairs +
  mutations; assert oracles 1 & 2 per transition. The cell-`char` generator is
  **adversarial by construction** — control bytes, wide/CJK, combining, `nil`, `""`
  — so the property *discovers* the G5 sanitization need rather than waiting for a
  hand-written case. Failures shrink to a minimal 2-row repro.
- **L2 — stateful command property** (a small model-checker). Commands `[Render(m),
  Resize(w,h), Corrupt(junk), CtrlL]`; model-state = intended buffer + may-be-corrupt
  flag; after each, assert the grid per oracle. This layer *generates* the
  dead-resize-guard and permanent-desync bugs the human reviews caught by hand.
- **L3 — regression pins** — each falsification-round finding (in-cell `\n` bleed,
  wide-char shrink tail, blank-row collapse, style-only change) as a named test.

### Matrix (which oracle / layer each lands in)

| invariant | oracle | layer |
|-----------|--------|-------|
| unchanged frame emits nothing | 4 | L0 |
| only changed rows emitted | 4 | L0 |
| style-only change re-emits its row | 1 | L0 |
| first frame is a keyframe (`\e[2J` + all rows) | 1 | L0 |
| resize sets force_repaint | 2 | L0 + L2 |
| in-cell newline: correct addressing **and** (post-G5) no tail bleed | 1 | L1 + L3 |
| shrinking row clears tail (`nil`-bg) | 1 | L0 + L3 |
| keyframe round-trips (CUP) | 1 | L1 |
| diff ≡ full | 2 | L1 |
| force_repaint recovers desync | 3 | L2 |
| recording replays (`replay_cast`) | 1 | integration |
| worst-case bytes ≤ full + rows × 16 B | — | L0 perf guard |
| no visual regression | (structural) | visual |

The perf guard is **absolute**, not a percentage: after the batching companion a
plain 80×24 frame is ~2 KB, so the fixed ~15 B/row CUP prefix is ~+10-15%
*relative* — a percentage guard would fail on its own rollout order. `≤ full +
rows×16 B` is the honest, batching-independent bound.

This flow is the standing form of the empirical falsification rounds: the checks a
subagent ran by hand to validate the design become permanent properties, so every
future render change re-runs the same falsification and returns a boolean, not a
screenshot. Registered alongside `FATE` so CI exercises it per-arch.

## 12. Honest cost accounting

- **Typical** (few rows change): ~300× fewer bytes; unchanged rows cost zero render.
- **Worst case** (every row changes — scroll, marquee): the all-rows keyframe/diff
  is ~+9% bytes vs the `\n`-join it replaces (per-row CUP addressing), never better
  on this workload. Absolute story is fine (post-batching ~2.3 KB vs today's ~19 KB).
- **Scroll is out of scope, and largely inapplicable here.** A full-screen content
  rotation is where a scroll-region beats both — but DECSTBM scroll regions are
  **full-terminal-width**, so they cannot express a bordered sub-width panel scroll
  at all (that needs DECSLRM, spottily supported). Raxol's flagship `zero_system.exs`
  has no full-screen scrolling log — it renders one `List.last` line and a 6-row
  `Enum.take(-6)` panel inside a bordered box, which row-diff handles at ≤6-row cost.
  So scroll-region is inapplicable to the flagship's paneled layout, not merely
  deferred; adding it is later work gated on a real full-width-scroll workload.

## 13. Rollout

1. **Companion PR #1:** `style_batching: true` at the terminal render site (§9) —
   re-prices everything, low risk, independently valuable.
2. **This PR:** `render_to_terminal/2` grid-diff with the unified CUP emit (§3/§5),
   `force_repaint` set by `:update_size` + `Ctrl-L` (§6), C0 sanitization (G5). G1
   (row rendering) closed first.
3. SSH path (`render_to_ssh/2`) after the G3 audit.
4. Later PRs, each gated on a profiled workload this underserves: Option B (sub-row
   cell-diff), scroll-region (if a full-width-scroll workload appears), resume/focus
   recovery.
