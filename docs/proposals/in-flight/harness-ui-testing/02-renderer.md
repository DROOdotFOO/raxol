# 02 — Renderer Test Suite (T2b/T2c + PaintAuthority)

Date: 2026-07-15 · Area: **the dual renderer** — printed-history append path
(T2b) + pinned viewport (T2c), gated by the PaintAuthority (D-PA) interface.
Substrate: **byte-capture** — every assertion is on captured output bytes, so
CI is terminal-independent. Counterpart of `harness-ui-roadmap.md` §2 T2b/T2c
and §0 D-PA; findings it operationalizes: grok45 #1/#3/#8, longcat #1/#8/#17,
composer #16/#18.

The five risks this suite exists to kill (roadmap framing):

1. **Sealed history rewritten by accident** (the Ink failure we reject).
2. **Full-screen `\e[2J` keyframe** wiping terminal-owned pixels.
3. **Cursor-ownership races** between the two emit paths.
4. **Resize** violating the chosen D-PA policy.
5. **The two paths composing wrong** under interleaving.

---

## 0. Orientation (locked from roadmap T2a, do not re-derive)

- **Scroll region = TOP rows `1..H-N`** (history, scrolling, feeds native
  scrollback). DECSTBM set once per size: `CSI 1 ; (H-N) r`.
- **Footer = rows `H-N+1..H`**, *outside* the region, pinned. This is T2c's
  buffer-diff viewport (live tail + strip + composer).
- Append path (T2b) writes **only at the region's bottom line** and lets the
  region scroll content up; sealed blocks migrate `region → native scrollback`.
- 2026 framing bytes are `\e[?2026h` … `\e[?2026l` (already emitted by
  `Backends`, see `render_to_terminal`).
- Inline path **forbids** `\e[2J`/`\e[3J`/`\e[H\e[2J`. Keyframes clear the
  **footer region only**.

---

## 1. Harness architecture — how we intercept the emit stream

Two capture layers, two oracles. The layers are chosen so **positive
mechanical tests run today against the raw byte stream** (before PaintAuthority
lands), while **semantic/adversarial tests use the tagged log** the
PaintAuthority provides.

### 1a. Raw capture — `io_writer` shim (existing pattern)

Reuse the exact idiom from `test/property/ssh_rendering_property_test.exs`:

```elixir
io_writer = fn data -> send(self(), {:wrote, data}) end
# ... run emit path ...
raw = collect_writes()   # concat of all {:wrote, _} in order
```

For the terminal path that writes via `IO.write/1` (T2c's `render_to_terminal`
lineage), use `ExUnit.CaptureIO.capture_io/1` — same as the existing
`render_capturing_both/2` helper. `raw` is a single `binary()`: the ground
truth every byte-level property asserts against.

### 1b. Tagged capture — `CaptureAuthority` (the PaintAuthority test double)

The PaintAuthority is the single seam both emit paths go through (roadmap T2b:
"one owner module, both paths go through it"). Define the behaviour so it can
be swapped for a recorder:

```elixir
@callback append_sealed(t, iodata) :: t          # T2b: append at region bottom
@callback repaint_footer(t, iodata) :: t          # T2c: footer-region paint
@callback keyframe_footer(t, iodata) :: t         # T2c: Ctrl-L / resize footer redraw
@callback with_cursor(t, region :: :history | :footer, (t -> t)) :: t
@callback resize(t, w, h) :: t                     # policy-bearing (D-PA)
@callback region_top(t) :: pos_integer            # current H-N (footer boundary)
```

`Raxol.Harness.Test.CaptureAuthority` implements it as an ordered log of
`%Emit{origin: :seal | :footer | :keyframe | :cursor | :region, bytes: binary,
seq: n}` plus a concatenated `raw` mirror. Crucially the **origin tag is
recorded from the call site, not reverse-engineered from bytes** — this is what
makes "which path emitted this byte" a fact, not an inference. Production
`IOAuthority` implements the same behaviour writing to `IO.write`, so the tag
layer costs nothing in prod (tags simply aren't recorded).

Every test constructs a `CaptureAuthority`, drives a schedule of ops through
it, then hands `log`/`raw` to an oracle.

---

## 2. Oracle design — how "row N is sealed" becomes an assertion

Two oracles, reused verbatim from `test/support/cross_terminal/` (CLAUDE.md
rule: reuse `raxol_terminal`'s parser as the test oracle, do not hand-roll a
VT).

### O1 — Mechanical scanner: `SequenceScanner` (byte-level, no emulation)

`Raxol.Test.CrossTerminal.SequenceScanner.scan/1` tokenizes `raw` into
`{:csi, params, final} | {:osc, _} | {:esc, _} | {:text, _}`. From the token
stream we build a **tiny positional model** (≈40 LOC, lives in the test
support file, not a full VT):

- Track scroll-region top `t` from `{:csi, "1;" <> _, "r"}`.
- Track cursor row from `{:csi, "<row>;<col>", "H"}` (CUP), plus CUU/CUD and
  region-scroll on newline.
- Predicates: `emits_full_clear?(raw)` = any `{:csi, "2"|"" , "J"}` or
  `"3J"`; `cup_rows(raw)` = every row a CUP addresses; `save_restore_balance/1`
  counts `\e7`/`\e8` and `\e[s`/`\e[u`.

O1 is the cheap oracle for INV-2, INV-3, INV-4-mechanical, and flat-mode
purity. It cannot prove "a sealed block's *content* is unchanged" — only that
no addressing crosses into the frozen zone. That is O2's job.

### O2 — Full VT: `AnsiReplayer` + `Raxol.Terminal.Emulator` (content-level)

`AnsiReplayer.replay/2` feeds `raw` into the real emulator, which tracks
`scroll_region`, `scrollback_buffer`, the on-screen grid, and cursor. Exposed:
`grid_text/1`, `Emulator.get_scrollback/1`, `Emulator.get_scroll_region/1`,
`AnsiReplayer.cursor/1`, `cell_at/3`.

**"Sealed history" as an oracle value.** Define, for a replayed emulator `E`:

```
history(E) = Emulator.get_scrollback(E)          # rows scrolled off the top
          ++ rows_above_footer(E)                # on-screen region rows 1..H-N
```

`history(E)` is the ordered, terminal-owned record of everything sealed. The
seal-once invariant is then a **prefix relation** on this value (§3, INV-1):
snapshot `history(E_k)` right after seal `k`; assert it is a byte-identical
in-order prefix of `history(E_final)`. Any divergence = a sealed row was
rewritten. This catches every subclass — footer bleed, stray CUP, `\e[2J`
wipe, resize re-wrap — in one assertion, at the cost of a full replay
(so run it at lower `max_runs`, per the existing keyframe-replay test's
`max_runs: 25` precedent).

**Oracle self-test (meta).** One test in the suite deliberately feeds O2 a
stream with a known seal violation (a CUP into a sealed row followed by a
write) and asserts O2 flags it. This proves the oracle can fail before we
trust it to pass. Without this, a broken oracle would make every seal-once
test vacuously green.

---

## 3. Invariants (formal)

Let the op schedule be `σ = [op₁ … opₘ]`, `opᵢ ∈ {seal(lines), footer(state),
resize(w,h), ctrl_l, scroll(n)}`. Let `Eᵢ` be the emulator after replaying the
capture through `opᵢ`. `F = [H-N+1 … H]` is the footer row set; `Hist = [1 …
H-N] ∪ scrollback`.

- **INV-1 (Seal-Once / Immutable-Prefix).**
  `∀ k. history(E_k)` is a byte-identical, in-order **prefix** of
  `history(E_final)`. Equivalently: once a block's bytes enter `history`, they
  are constant for all later `t ≥ k`. Seal is a monotone append to an
  append-only log.

- **INV-2 (Footer-Confinement).** For every `:footer`- or `:keyframe`-origin
  emit `w`, every row addressed by `w`'s CUPs ∈ `F`. No footer-path byte lands
  in `Hist`. (`origin` from the tagged log; rows from O1.)

- **INV-3 (No-Full-Clear).** `raw` contains no `\e[2J`, no `\e[3J`, no
  `\e[H\e[2J`, on any path, within one attach lifetime. Footer keyframes clear
  only rows in `F` (per-row `\e[<r>;1H\e[2K`, `r ∈ F`).

- **INV-4 (Cursor-Ownership Round-Trip).** For every `with_cursor` bracket,
  `cursor(E_before) == cursor(E_after)`. `save_restore_balance(bracket) == 0`.
  Save/restore never nests across paths (single owner).

- **INV-5 (Resize-Policy-Conformance), D-PA-parameterized.** On `resize(w,h)`
  under policy `P`:
  - *Universal (all P):* INV-3 holds (no `\e[2J`); DECSTBM re-set exactly once
    as `CSI 1;(h-N) r`; footer re-derived within `F'`.
  - *P = A (seal-time-only) / C (live-region-only):* zero re-emission of any
    previously-sealed block. `history(E_after) == history(E_before)` (mis-wrap
    of old blocks at the new width is **accepted**, asserted-not-against).
  - *P = B (soft-owned):* re-emission bounded to `≤ D` tail blocks, every
    re-emit wrapped in a single 2026 bracket, none addressing `scrollback`;
    older history byte-unchanged.

- **INV-6 (Ctrl-L Footer-Only).** A `ctrl_l` op satisfies INV-2 for its redraw
  burst, emits no `\e[2J`, and re-emits zero sealed blocks
  (`history` unchanged).

---

## 4. Positive suite — `renderer_seal_once_property_test.exs`

IDs `R-P#`. Oracle column: O1 (scanner) / O2 (VT) / TAG (log).

| ID | Invariant | Statement | Oracle |
|----|-----------|-----------|--------|
| R-P1 | INV-1 | Stream N=1k sealed blocks at constant width `W`; `history(E_k)` is an immutable prefix of `history(E_final)` for all k. | O2 |
| R-P2 | INV-1 | Zero rewrites: for every sealed row index, `cell_at` content is constant across all later snapshots. | O2 |
| R-P3 | INV-2 | 500 footer repaints; every `:footer`-origin CUP row ∈ `F`, verified **inside** a `\e[?2026h…l` bracket. | O1+TAG |
| R-P4 | INV-3 | No `\e[2J`/`\e[3J` anywhere in a full seal+footer+resize session. | O1 |
| R-P5 | INV-4 | Cursor round-trip: `save → position(:history) → append → restore`; `cursor` equal before/after; balance 0. | O2+O1 |
| R-P6 | INV-5-univ | Resize 80→120→80→30: no `\e[2J`; exactly one `CSI 1;(h-N) r` per resize; footer within `F'`. | O1 |
| R-P7 | INV-5-A | (policy A) resize emits zero seal-origin re-emits; `history` byte-equal pre/post. | O2+TAG |
| R-P8 | INV-5-B | (policy B) resize re-emits ≤ D tail blocks, each in one 2026 bracket, none into scrollback; older history equal. | O2+TAG |
| R-P9 | INV-5-C | (policy C) as A for history; live-region (footer) salience bytes present but confined to `F`. | O2+TAG |
| R-P10 | INV-6 | Ctrl-L repaints footer only: INV-2 holds for the burst, no `\e[2J`, `history` unchanged. | O1+O2 |
| R-P11 | INV-1 | Interleaved seal+footer (non-adversarial, fixed schedule) still yields immutable `history` prefix. | O2 |
| R-P12 | — | Oracle self-test: O2 flags a hand-crafted seal violation (proves the oracle can fail). | O2 |

`max_runs`: O1-only props 200; O2 props 25 (full replay cost, per existing
precedent). Blocks generated as `list_of(string(:alphanumeric))` lines +
style attrs, mirroring `cell_gen/0`.

---

## 5. Negative suite — `renderer_adversarial_property_test.exs`

These **must fail on the buggy implementations** — each pairs a bug-injecting
authority with the property that catches it. Structure: a `BuggyAuthority.*`
double emits the flawed bytes; the property runs the *same* oracle used in the
positive suite and asserts it **detects** the violation (i.e. the test asserts
the oracle raises / returns a violation, so a regression that "fixes" the
detection also fails).

| ID | Bug injected | Caught by | Oracle |
|----|--------------|-----------|--------|
| R-N1 | `\e[2J` spliced into the inline/append path (simulates today's keyframe). | INV-3 / INV-1 prefix break. | O1+O2 |
| R-N2 | Footer path occasionally CUPs into `row = H-N` (one row into history) then writes. | INV-2 (footer-confinement). | O1+TAG |
| R-N3 | Append path positions cursor without matching restore (owner leak). | INV-4 round-trip (`cursor_before ≠ cursor_after`). | O2+O1 |
| R-N4 | Real `Backends.build_terminal_frame/4` driven with a **width change** → emits `\e[2J` on keyframe. Characterization + regression guard: assert the *old* path clears, assert the *new* inline path does **not**. | INV-3 / keyframe-on-resize. | O1 |
| R-N5 | Seal path re-emits a previously-sealed block verbatim (Ink-style rewrite) under policy A. | INV-5-A / INV-1. | O2+TAG |
| R-N6 | Policy B re-emits `D+1` blocks (exceeds bounded depth) on resize. | INV-5-B bound. | TAG |
| R-N7 | **Adversarial interleave** (generator §6): random schedule of `{seal, footer, resize, ctrl_l, scroll}`; assert **no byte ever addresses a sealed row** and `history` stays an immutable prefix. Shrinks to a minimal violating schedule. | INV-1+INV-2. | O2+TAG |

R-N4 is the highest-value negative: it pins the exact regression class the
roadmap names ("today's `build_terminal_frame` clears on width change"). It is
a *characterization* test — it encodes the current buggy behavior as a known
fact and guards that the inline path diverges from it.

---

## 6. Generators

### G1 — block stream (positive)

```elixir
block_gen = gen all lines <- list_of(string(:alphanumeric, min_length: 1,
                                      max_length: 40), min_length: 1, max_length: 8),
                    kind <- member_of([:message, :reasoning, :tool_call]),
              do: %Block{kind: kind, lines: lines}
seal_stream_gen = list_of(block_gen, min_length: 1, max_length: 200)
```

### G2 — adversarial schedule (R-N7, the core generator)

```elixir
op_gen = one_of([
  {:seal,   block_gen},
  {:footer, footer_state_gen},          # tail text + strip fields
  {:resize, integer(20..200), integer(6..60)},
  constant(:ctrl_l),
  {:scroll, integer(1..40)}             # user scrollback movement mid-stream
])
schedule_gen = list_of(op_gen, min_length: 1, max_length: 120)
```

The generator's power is that `:resize` and `:seal` and `:footer` are
**interleaved freely** — this is exactly the composition the roadmap warns is
"the two paths composing wrong under interleaving." Shrinking yields the
minimal `[seal, resize, footer]`-style triple that breaks an invariant, which
is the debugging artifact we want.

### G3 — width sweep (resize policy)

```elixir
width_seq_gen = list_of(integer(20..200), min_length: 2, max_length: 6)
```

Drives R-P6/7/8/9 across every intermediate width (models drag-resize, the
reflow hazard from research 04 §E / longcat #1).

---

## 7. D-PA parameterization — one suite, both sides of the decide-late interface

The suite is parameterized over `policy ∈ {:a_seal_time, :b_soft_owned,
:c_live_region}` via an ExUnit parameterized module (or a `for policy <- …`
around the `describe` blocks). Each policy supplies:

- a `PaintAuthority` impl (`Authority.SealTime`, `Authority.SoftOwned`,
  `Authority.LiveRegion`) with policy-specific `resize/3` behavior;
- a `resize_oracle(policy)` selecting INV-5-A / -B / -C.

Universal invariants (INV-1..4, INV-6) run identically for all three. Only
INV-5 branches. This means **T0's D-PA verdict does not invalidate the suite**
— whichever policy ships, its half is already covered, and the other halves
document the rejected options. The `policy` parameter is the single knob the
verdict turns; nothing else in the suite moves. (Roadmap §0: "design the suite
parameterized over the policy so both sides of the decide-late interface are
covered.")

Bounded-depth `D` for policy B is a suite constant (`@soft_owned_depth 8`)
matched to whatever T0 measures as the safe visible-tail re-emit budget.

---

## 8. File layout

```
test/property/renderer_seal_once_property_test.exs     # R-P1..P12
test/property/renderer_adversarial_property_test.exs   # R-N1..N7
test/support/harness/capture_authority.ex              # CaptureAuthority + %Emit{}
test/support/harness/buggy_authority.ex                # BuggyAuthority.* doubles
test/support/harness/seal_oracle.ex                    # history/1, prefix?/2, O1 positional model
```

Reuses without modification: `Raxol.Test.CrossTerminal.AnsiReplayer`,
`Raxol.Test.CrossTerminal.SequenceScanner`, `Raxol.Terminal.Emulator`.

---

## 9. Open questions (for the orchestrator / T0)

1. **Does `Emulator` migrate region-scrolled rows into `scrollback_buffer`
   when DECSTBM is active?** O2's `history/1` assumes yes. If the emulator only
   fills `scrollback_buffer` on full-screen scroll (not region scroll), the
   seal-once prefix must be computed from on-screen rows + a harness-side
   shadow of evicted rows. **Must be validated by a spike test before the
   suite is trusted** (extends the R-P12 self-test).
2. **`D` (policy-B bounded depth)** is unknown until T0 measures re-emit cost /
   visible-tail size per terminal. Suite ships with a placeholder constant.
3. **Cursor-save dialect**: `\e7`/`\e8` (DECSC) vs `\e[s`/`\e[u` (SCO). The
   PaintAuthority must pick one owner dialect; O1's balance check is
   dialect-specific. Pending T2d driver profile.
4. **tmux passthrough**: inside tmux, DECSTBM/2026 may be clamped; byte-capture
   CI tests the *emitted* bytes, not tmux's rewrite. A real-tmux integration
   tier (tagged `:integration`) is out of scope for this byte-level suite but
   named here so it is a decision, not an omission (grok45 #11, composer #14).
5. **Reattach lifetime scope**: INV-1's "never repainted" is scoped to *one
   attach lifetime* (roadmap T0 scrollback-identity ruling). A second attach
   re-printing history is *not* a violation — the suite must reset the oracle
   per attach. Encoded as: each test = one attach.
```
