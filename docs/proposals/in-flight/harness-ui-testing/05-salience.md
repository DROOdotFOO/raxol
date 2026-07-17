# Harness UI Testing — 05 · Salience (T8 prominence + T9 policy + perceptual risk)

Date: 2026-07-15 · Status: test design (pre-implementation).
Owns the test surface for **T8 prominence attribute** and **T9 recency/attention
policy** (roadmap §2, SAL subgraph), plus the cross-cutting **perceptual risk**
that makes both untrustworthy if wrong.

Sources read for this design (not guessed):
- `lib/raxol/ui/theming/salience.ex` — the shipped H-K solver (`hue_factor/1`,
  `apparent_lightness/3`, `solve_lightness/3`, `tier_target/3`, `oklch_to_hex/3`,
  `hex_to_oklch/1`, `reference_ground/0` = **0.2**).
- `test/raxol/ui/theming/salience_test.exs` — the byte-exact Darcula bake pattern
  this doc generalizes.
- `diff_viewer.ex` (PR `feat/harness-ui-harness_diff`, worktree
  `agent-a701a26bbf887fcaa`) — the established prominence mechanics:
  `prominence/1` ladder (1.0/0.8/0.6/0.4 floor), `dechroma/2`,
  `fade_toward_ground/2`, `gutter_prominence/2`, `@chrome_base_fg "#B4B4B4"`,
  and its byte-exact hex assertions (`#919191`, `#552527`, `#201819`, `#313131`,
  `#4f4f4f`, …). This is the pattern to lift into T8's general contract.
- `harness-ui-north-star.md` §3.2 (attention instrument; live-region-always /
  history-per-D-PA reach), `harness-ui-cohort-research.md` (P6 degradation
  cluster, P7 information-vs-decoration, FI-U3/FI-U4).

---

## 0. Two findings from reading the actual solver (these shape the suite)

These are not hypotheticals — they fall straight out of the current code and are
the reason the negative suite exists.

**F1 — the fade is hardcoded to the near-black reference ground.**
`DiffViewer.fade_toward_ground/2` does:

```elixir
ground = Salience.reference_ground()          # 0.2, a CONSTANT
faded_apparent = ground + (apparent - ground) * prominence
```

It fades toward apparent-lightness **0.2** regardless of the terminal's real
background. On a dark theme this is correct (content is lighter than ground;
fading pulls it *down* toward ground → less contrast → recedes). On a **light
theme** (ground ≈ 0.95) the theme's foregrounds are *darker* than 0.2 is from
them in the wrong direction: pulling apparent lightness toward 0.2 moves text
*away* from a light background → **contrast INCREASES as prominence drops**. The
fade inverts. T8's mapping layer MUST take the OSC-11-detected ground as a
parameter (the `Salience.solve/4` public API already accepts `:ground`; only the
DiffViewer shortcut hardcodes it). The negative suite pins this as SAL-N-02.

**F2 — the "0.4 floor" is a floor on the INPUT multiplier, not on OUTPUT
legibility.** `prominence(_) -> 0.4` floors the *prominence scalar*. But the
resulting contrast is `|faded_apparent - ground|` = `|apparent - ground| * 0.4`
— which depends on how bright the source color was. A source that started near
the ground (low-contrast accent, or a `recede`-tier color) at 0.4 prominence can
land below any legibility threshold. **Nothing in the code guarantees a contrast
floor.** The floor property (SAL-P-05) is therefore defined on the *output WCAG
contrast ratio*, not the input scalar — and it is expected that running it may
reveal 0.4 is too low for some source colors. That discovery is the property
doing its job, not a test bug.

Corollary: T8 needs a **legibility clamp** distinct from the prominence floor —
after computing the faded color, if its contrast ratio against ground is below
the ratified floor, clamp apparent lightness back out to the floor. The suite
tests the clamp, not just the raw fade.

---

## 1. Metrics (defined once, used by every property)

Two distinct contrast metrics — do not conflate them:

- **M1 · model-internal apparent-contrast** —
  `AL(color) = Salience.apparent_lightness(l, c, h)` for the color's own
  `{l,c,h}`; `apparent_contrast(color, ground) = |AL(color) - AL(ground)|`.
  Used for **uniformity and monotonicity** — we test the system against *its own
  model* (the solver's H-K metric is the ground truth for "equal brightness").
- **M2 · WCAG-ish luminance contrast ratio** — compute sRGB relative luminance
  `Y` (Rec.709 coefficients on linearized channels) of the solved hex and of the
  ground hex; `ratio = (max(Y_fg,Y_bg) + 0.05) / (min + 0.05)`. Used for the
  **legibility floor** — an *external* check the solver's own model cannot
  self-certify (F2). A tiny helper `Salience.Test.wcag_ratio(hex, ground_hex)`
  lives in `test/support/` (pure, no new lib dependency).

`FLOOR_RATIO` is a named constant, initial value **3.0:1** (WCAG AA
large-text / UI-component minimum), **ratified and pinned by the human-eye
protocol** (§5). `EPS_QUANT` = the 8-bit + gamut-shrink tolerance for M1
equalities, initial **0.02** in apparent-lightness units (matches the existing
round-trip test's `0.01` L tolerance, doubled to absorb shrink).

---

## 2. POSITIVE suite (`salience_prominence_test.exs`, `salience_policy_test.exs`)

### 2.1 Byte-exact fixtures (the DiffViewer pattern, generalized)

**SAL-P-01 · prominence-step bake.** For a fixed seed palette (reuse the Darcula
seeds already in `salience_test.exs`) and the reference ground 0.2, bake the
solved hex at each prominence step `{1.0, 0.8, 0.6, 0.4}` and assert byte-exact.
This is the T8 analogue of `@darcula_baked` — a frozen ladder table:

```
@prominence_bake [
  # {seed_hex, prominence, expected_hex}   (ground = 0.2, reference)
  {"#c1712c", 1.0, "#c1712c"},   # 1.0 is identity (guard clause)
  {"#c1712c", 0.8, "..."},        # values captured from first green run
  {"#c1712c", 0.6, "..."},
  {"#c1712c", 0.4, "..."},
  ...one row per hue in the Darcula set...
]
```

Formal: `∀ (hex, p, want) ∈ bake : T8.fade(hex, p, ground: 0.2) == want`.
Fill `"..."` from the first passing run (same discipline as the Darcula bake and
the DiffViewer `#552527`-style assertions). Regressions become one-line diffs.

**SAL-P-02 · gutter/chrome sub-tier bake.** Mirror DiffViewer's proven values
(`gutter_prominence` → `#919191` at 0.8-on-wash, `#313131` at 0.2, `#4f4f4f` at
0.4) so the general T8 layer reproduces the component-level numbers the PR
already ships. Guards against T8 generalization silently changing DiffViewer.

### 2.2 Perceptual-uniformity property (test the model against itself)

**SAL-P-03 · equal-prominence hue-evenness.**
> For any two hues `h₁, h₂` present in the palette, at the *same* prominence `p`
> and ground `g`, the model-internal apparent-contrast is equal within
> `EPS_QUANT`:
> `|apparent_contrast(fade(c(h₁),p,g), g) − apparent_contrast(fade(c(h₂),p,g), g)| ≤ EPS_QUANT`.

This holds *analytically* in the current code —
`faded_apparent = g + (AL−g)·p` is hue-independent by construction if every seed
starts at the same tier apparent-lightness — so the property is really guarding
against: (a) gamut-shrink at high chroma perturbing L off the solved target,
(b) a future refactor that reintroduces per-hue skew. `EPS_QUANT` absorbs (a).
Property-generate hues `0..359`, chroma `0.0..0.16`, fixed tier.
*Then validate the model itself ONCE, by eye* (§5 SAL-H) — the property proves
consistency with the model; only human review proves the model is right.

### 2.3 Monotonicity property

**SAL-P-04 · per-hue monotone contrast.**
> For a fixed hue/chroma/ground and prominences `a > b`:
> `apparent_contrast(fade(color,a), g) ≥ apparent_contrast(fade(color,b), g) − EPS_QUANT`.

Linear in the current code, but quantization can create micro-inversions →
the `−EPS_QUANT` slack. Property-generate `(h, c, a, b)` with `a > b`. Runs on
**both** grounds (dark 0.2, light 0.95) — on light ground the direction flips
sign but the *ordering by prominence* must still hold (a>b ⇒ more contrast).
If SAL-N-02 (inversion) is unfixed, this FAILS on the light ground — which is
the intended coupling: the monotonicity property and the inversion guard catch
the same F1 bug from two angles.

### 2.4 Legibility-floor property (the F2 guard)

**SAL-P-05 · floor holds against BOTH grounds.**
> For every palette color and every prominence `p ≥ 0.4`, the *clamped* T8 output
> has `wcag_ratio(output, ground_hex) ≥ FLOOR_RATIO` — for `ground ∈ {dark 0.2,
> light 0.95}` and for `ground_hex` being the actual solved ground color.

Uses M2, not M1 (F2: the model can't self-certify legibility). Property-generate
colors × grounds. This is the test that will expose whether 0.4 + raw fade is
enough or whether the legibility clamp (§0 corollary) is mandatory. Expected
outcome on first run: **fails for low-apparent-contrast source colors at 0.4** →
drives the clamp into T8. Pin `FLOOR_RATIO` only after §5 ratifies it.

### 2.5 Neutrality / regression guard (the default-not-neutral risk)

**SAL-P-06 · default 1.0 is byte-identical.**
> `T8.fade(hex, 1.0, _) == hex` for all hex (the `when prominence >= 1.0` guard),
> AND a component rendered with **no prominence attribute** produces a
> byte-identical cell tree to the same component pre-T8.

Two layers: (a) unit — the identity clause; (b) integration — snapshot a
representative component (Table row, message block) with no `prominence:` attr,
assert the rendered cell list equals a golden captured on the pre-T8 commit. This
is the guard that T8's machinery never touches a component that didn't opt in.
Wire into T20's degradation snapshots so it runs in CI.

### 2.6 T9 policy unit tests (pure function, fixture-driven)

T9 has no code yet; these are executable specs of the intended `policy/2`
(`turn_state, focus → %{block_id => prominence}`).

**SAL-POL-01 · 5-turn tier ladder.** Fixture: 5 sealed turns + 1 live turn.
Assert the documented ladder — current turn `1.0`, prior turns stepping
`0.8 → 0.6 → 0.4` and resting at the `0.4` floor, matching DiffViewer's distance
ladder so the two salience surfaces agree. Golden map, exact.

**SAL-POL-02 · approval promotion.** A `needs-input`/approval block in ANY turn
(including the oldest) resolves to full prominence **+ accent**, outranking every
context block. (North-star §2 "Deciding"; the 93%-blind-approve stat is why this
is non-negotiable.)

**SAL-POL-03 · focus transition.** Focus moves from block A to block B → A drops
one tier, B promotes to current. Assert the transition is a pure function of
`(turn_state, focus)` — same inputs, same output map (SAL-POL-05 property).

**SAL-POL-04 · needs-input never starves** (also a negative property, SAL-N-04) —
stated here as the positive contract: `policy` always maps needs-input ≥ every
context block.

**SAL-POL-05 · policy purity.** `policy(s, f) == policy(s, f)` structurally; no
process state, no clock read. Property-generate `(turn_state, focus)`.

---

## 3. NEGATIVE suite (`salience_degradation_test.exs`)

**SAL-N-01 · 256-color downsample preserves the ladder.**
> Quantize each prominence-step hex to the xterm-256 cube (standard 6×6×6 +
> grayscale nearest-match). Assert that adjacent tiers (0.6 vs 0.4, 0.8 vs 0.6)
> do **not** map to the same palette index; if any adjacent pair collides, the
> ladder must redistribute (fewer, wider-spaced tiers) rather than silently lose
> a step.

The solver emits 24-bit; nothing downsamples today, so on a 256-color terminal
(mosh, P6's "256-color" cluster) two tiers can quantize to one cell = information
loss with no signal. Test asserts distinguishability post-quantization OR that
T8 exposes a `tiers_for(:color256)` that returns a redistributed (e.g. 3-step)
ladder. Runs per hue — collisions are hue-dependent (low-chroma hues collapse
first). This is the concrete FI-U4 "256-color" golden, made a property.

**SAL-N-02 · light-theme fade direction (F1 guard).**
> For ground detected as **light** (OSC-11 → L > 0.5), fading a light-theme
> foreground with decreasing prominence must *decrease* `wcag_ratio(output,
> ground)` monotonically. Assert `ratio(p=0.4) < ratio(p=0.6) < ratio(p=0.8) <
> ratio(p=1.0)`.

Directly catches F1: with the hardcoded `reference_ground()` this FAILS (ratio
increases as prominence drops). Pins that T8 must thread the real ground.
Companion assertion: `fade(hex, p, ground: g)` for `g ∈ {0.2, 0.95}` produce
outputs on *opposite sides* of their respective grounds (dark → lighter than
ground; light → darker than ground) — the `resolve_polarity` auto behavior must
carry through the fade, not just the tier solve.

**SAL-N-03 · D-PA violation guard (structural rejection).**
> Under D-PA policy `(A) seal-time-only` or `(C) live-region-only`, an attempt to
> apply/recompute prominence on a **sealed** block must be rejected structurally
> — return `{:error, :sealed}` / no-op returning the sealed bytes unchanged —
> **not** silently dropped and not silently applied.

Fixture: a sealed block struct (fold+seal flag from T4) + a policy call targeting
it under each D-PA mode. Assert `(B) soft-owned` permits (bounded depth), `(A)`
and `(C)` reject. The rejection is observable (error tuple), so a regression that
starts mutating sealed history trips a red test, not a silent visual bug. Couples
to the T4/T7 seal semantics.

**SAL-N-04 · needs-input starvation property.**
> `∀ turn_state, focus : min prominence over needs-input blocks ≥ max prominence
> over context (non-needs-input, non-current) blocks.`

Property-generate arbitrary turn ladders with ≥1 needs-input block at a random
position. No generated state may violate. Catches the "everything faded, where's
my approval" failure and its dual (needs-input demoted by an over-eager recency
rule). This is the single most important policy invariant.

**SAL-N-05 · degenerate grounds (solver stability at extremes).**
> For ground ∈ {pure black L=0.0, pure white L=1.0, mid-gray L=0.5}: `solve/4`
> and `fade/3` return in-gamut `#rrggbb` (regex-valid), never raise, never NaN,
> and `tier_target` stays within `[al_min, al_max]`. Tier ordering preserved
> even under full headroom compression (extend the existing mid-gray test to
> the two extremes).

Guards the headroom-compression math (`scale = headroom / @max_delta`) at the
boundaries where `headroom → 0` (mid-gray) and `headroom → max` (pure
black/white). Mid-gray is the worst case: both sides cramped; assert tiers stay
sorted and the top tier ≤ 0.97 (already partially covered — extend to fade path
and both extremes).

---

## 4. Test inventory (IDs)

| ID | Kind | Statement (one line) | Metric |
|----|------|----------------------|--------|
| SAL-P-01 | byte-exact | prominence-step bake per hue reproduces frozen hex | — |
| SAL-P-02 | byte-exact | gutter/chrome sub-tiers match DiffViewer shipped hexes | — |
| SAL-P-03 | property | equal prominence ⇒ equal apparent-contrast across hues | M1 |
| SAL-P-04 | property | prominence a>b ⇒ apparent-contrast a≥b per hue, both grounds | M1 |
| SAL-P-05 | property | prominence ≥0.4 ⇒ WCAG ratio ≥ FLOOR, both grounds | M2 |
| SAL-P-06 | regression | default 1.0 byte-identical; no-attr = pre-T8 render | — |
| SAL-POL-01 | unit | 5-turn fixture → documented tier ladder | — |
| SAL-POL-02 | unit | approval/needs-input promoted + accent, outranks all | — |
| SAL-POL-03 | unit | focus transition demotes old / promotes new | — |
| SAL-POL-04 | unit | needs-input ≥ every context block (positive form) | — |
| SAL-POL-05 | property | policy is a pure function of (turn_state, focus) | — |
| SAL-N-01 | property | 256-color quantization keeps tiers distinct / redistributes | M2-ish |
| SAL-N-02 | property | light ground ⇒ fade decreases contrast (F1 guard) | M2 |
| SAL-N-03 | structural | sealed block under D-PA (A)/(C) rejects restyle | — |
| SAL-N-04 | property | no policy state starves needs-input | — |
| SAL-N-05 | property | degenerate grounds: stable, in-gamut, ordered | M1 |
| SAL-H-01..04 | human-eye | §5 playground matrix checklist | eye |

---

## 5. HUMAN-EYE protocol (the un-testable part, made disciplined)

The property suite proves T8 is *self-consistent* with the solver's H-K model.
It cannot prove the *model matches human vision*, nor that a tier ladder is
*visibly ordered* to an operator. That requires eyes — but disciplined, diffable
eyes, not vibes.

### 5.1 The matrix demo

A playground demo `salience_matrix` (`lib/raxol/playground/demos/`) renders a
grid: **hue (columns) × prominence tier (rows) × ground (two panels: dark 0.2,
light 0.95)**. Each cell = a short text label ("differentiate") painted at that
`(hue, tier, ground)`. Columns span the Darcula hue set (25, 57, 77, 134, 242,
250, 314) plus pure achromatic. A third panel renders the **256-color-quantized**
version of the same grid side-by-side with truecolor.

### 5.2 The checklist (the review is against this, every time)

Reviewer answers YES/NO per panel; any NO blocks the change:

1. **Legibility** — can you read the label in *every* cell, including the
   bottom (0.4) row, on both grounds? (F2/SAL-P-05 in the eye.)
2. **Order visible** — scanning a column top→bottom, is the fade *monotone and
   obvious*? Can you point to "this row is more prominent than that row" without
   guessing? (SAL-P-04 in the eye.)
3. **Hue-evenness** — scanning a row left→right, does any hue *pop* or *sink*
   relative to its neighbors at the same tier? (Blue sinking, yellow popping are
   the classic H-K failures — SAL-P-03 in the eye; this is the one that
   validates the *model*, not just the code.)
4. **No inversion** — on the light panel, does lower prominence actually look
   *quieter* (not darker-and-louder)? (SAL-N-02 in the eye.)
5. **Quantization** — in the 256-color panel, are all tiers still distinct, or
   did two rows merge? (SAL-N-01 in the eye.)

### 5.3 Capture + diffability

- The demo renders to a fixed 120×N buffer; capture via `Raxol.Headless.screenshot/1`
  → an ANSI dump committed at `test/fixtures/salience/matrix_{truecolor,256}.txt`.
  A cell-tree golden (the hex per cell) is committed alongside as the
  machine-diffable artifact; the ANSI dump is the human artifact.
- For the truest check, also capture a terminal PNG (kitty `+kitten icat` or an
  emulator screenshot) into `docs/proposals/in-flight/harness-ui-testing/img/`
  so a reviewer months later sees what "passed" looked like.
- The cell-tree golden diffing means a solver change surfaces as an exact hex
  delta before any eye is needed — the human pass runs only when the golden
  moves.

### 5.4 When it re-runs (the trigger, so it's a rule not a hope)

Mandatory human-eye re-review on ANY change to:
- `Salience` solver internals (`@hk_k`, `hue_factor/1`, `@tier_deltas`,
  `@reference_ground`, `apparent_lightness/3`, `solve_lightness/3`, the
  OKLCH↔sRGB matrices);
- T8's prominence→solver mapping or the legibility-clamp constant;
- `FLOOR_RATIO` or `EPS_QUANT`.
The cell-tree golden failing is the *mechanical* trigger; a reviewer signs off in
the PR (checklist §5.2 pasted, all YES) before the golden is re-baked. First run
of this protocol **ratifies `FLOOR_RATIO`** — pick the highest ratio at which
checklist item 1 passes for every cell, pin it, and SAL-P-05 enforces it forever
after.

---

## 6. Sequencing / dependencies

- SAL-P-01/02/03/04/05/06 and SAL-N-01/02/05 test the **solver + T8 mapping**;
  buildable against fixtures now (the solver ships). They gate T8's commit.
- SAL-N-03 needs the T4 seal flag + the D-PA verdict (T0) — the *test* is written
  now against a fixture seal struct; it commits with T8.
- SAL-POL-* and SAL-N-04 need T9's `policy/2` signature; written as executable
  specs now, wired when T9 lands (needs T7 turn-state + T8).
- SAL-P-06 and the §5 matrix goldens fold into **T20 degradation CI** so they run
  every build (FI-U4).
- The human-eye protocol (§5) is not CI-gated (needs eyes) but is *golden-gated*:
  the cell-tree golden failing blocks merge until a reviewer re-signs.
