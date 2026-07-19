# Native Palette Riding — solve color against the terminal's own foundation

Status: **draft / design (v1)** · Date: 2026-07-19 · Owner: V + Claude
Parent: `f0-capability-detection.md` (the batched-probe substrate this rides on) ·
Sibling: `tui-steal-list.md` #7c/#8 (H-K solver + color-ladder foundation)
Depends on: the salience sign-flip fix (in flight, do **not** re-derive here)

**§7/§4 downgrade seam — LANDED (2026-07-19).** `Raxol.UI.ColorResolver`
(main raxol, `lib/raxol/ui/color_resolver.ex`) now performs the §3.3 step-5
downgrade routing per the §4 tiers table, gated on a guarded lazy read of
`Raxol.Terminal.Capabilities.color_depth/0` (defaults `:truecolor` when no
capability record is cached -- the existing-suite neutrality contract,
not that function's own `:ansi16` no-record default). `:truecolor` is the
identity; `:ansi256` quantizes truecolor hex/`{r,g,b}` via
`Colors.find_closest_256_color/1` (already-discrete literals pass
through); `:ansi16` role-tagged intents pin through `Ansi16Salience.slot/3`
(polarity from the detected ground, prominence bucket from the composed
`effective_p`), role-less colors chroma-gate (`0.03`, see
`color_resolver.ex`'s `@ansi16_gray_chroma_gate` comment for the
derivation against the PIN test's misroute band) before quantizing via
`Colors.find_closest_basic_color/1`; `:none` strips fg/bg to `nil`. The
`:ansi16` rung always emits one of the 16 standard atom names (never a raw
slot integer) so `packages/raxol_terminal`'s renderer needs no new encode
logic -- audited (§7's "renderer only encodes, never chooses"): the atom/
integer/nil encode clauses already in `renderer.ex` handle every shape the
resolver now emits, and the live pipeline (`backends.ex`) constructs the
renderer with an empty `%{}` theme, so the atom path's theme-lookup
fallback (a separate, pre-existing feature for named theme colors) never
intercepts an ANSI16 downgrade decision. The region-prominence-
propagation.md §3.1 grid-bg TODO closed in the same pass (see that doc's
updated note). Test coverage: `test/raxol/ui/color_resolver_test.exs`
("capability-tier downgrade", "grid-bg fg floor"),
`test/raxol/ui/theming/colors_test.exs` (resolver-level gray-misroute fix
+ role-pin-bypasses-quantizer), `test/raxol/ui/region_prominence_test.exs`
(RP-N-02 golden updated to stay grid-aware). Not yet done: rungs 5/6 (OSC
4 known-palette 16-color, live ground re-solve) -- unrelated to this seam,
still tracked at §8/§9.

Thesis: the terminal already *is* a theme. Its background color is the ground the H-K
salience solver was built to solve against; its foreground and 16 palette slots are a
user-chosen, user-trusted color foundation. Raxol should **ride that native palette** —
detect the ground once, solve every prominence tier against it (darker-from-bg on light
terminals, lighter-from-bg on dark), and degrade to ANSI-256/16 by the *honest* rule for
each tier: nearest-color when the real slot values are known, semantic-role pinning when
they are not. Text with no explicit color attribute inherits a WCAG-distance-correct
contrast from the detected ground automatically.

This is a **design**, not an implementation. Nothing below edits `salience.ex`.

**Amendments (review + V ratification, 2026-07-19):**
- **A1 — OSC 10 foreground rung (adopted from review).** The ladder below queries only
  the background. Add `ESC ] 10 ; ? BEL` (native foreground) to the same batched write —
  the terminal's own fg is the user-chosen *light* (or dark) extreme, and the prominence
  range should sit **between the terminal-defined bg and fg**, not between bg and the
  absolute `[0.03, 0.97]` bounds. Concretely: the anchor tier's target clamps to the
  native fg's apparent lightness when known; headroom compression in `tier_target/3`
  takes the fg-L (not 0.97/0.03) as the far bound. Falls through to the absolute bounds
  when OSC 10 is silent. One more reply class, zero extra round-trips.
- **A2 — floors are AA (ratified).** The attr-less text floor is WCAG **4.5 (AA)**, not
  AAA — canonical definition lives in `region-prominence-propagation.md` §3.4 (`:text`
  class). Rationale (V): users needing higher contrast configure a higher-contrast
  terminal palette; we ride the native range rather than fight it. This doc's
  "WCAG-distance-correct" language means that floor.
- **A3 — downgrade-site ruling.** The downgrade *decision* (which slot/index/hex) lives
  in main raxol's `ColorResolver` at the cell-emission choke point (it needs the semantic
  role and `Ansi16Salience`, both main-raxol); byte *emission* (SGR encoding of the
  decided value) stays in `raxol_terminal`'s renderer. §7's "renderer color-resolution
  seam" is amended accordingly: the terminal renderer gates on `color_depth` only to
  *encode*, never to *choose*.
- **A4 — Q-role-plumbing is answered** by the sibling design: `%ColorIntent{role: ...}`
  threads the semantic role to the resolver (option (a)). Not open anymore.
- **A5 — Q-midgray answered (V): option (a), hard 0.5 cutoff** for v1.
- **A6 (V, 2026-07-19):** ground/foreground normalize via H-K apparent lightness of
  the full detected color, not nominal OKLCH `L` — tinted terminals (green-on-green
  et al) rank by perceived brightness. Quasi-transparency (prominence fade toward
  rendered bg, else terminal bg) operates in AL space end-to-end.

---

## 0. What already exists (grounded)

The substrate is ~80% built. This proposal wires the last seams, it does not start cold.

| Piece | Module | State |
|---|---|---|
| OSC 11 bg query + parse (`rgb:`/`rgba:`/`#`, 1–4 hex-digit channel scaling) | `raxol_terminal/.../driver/background_query.ex` | **live**, standalone, own `:persistent_term` key |
| Batched probe (OSC 11 + kitty-kbd + DECRQM 2026 + XTVERSION + DA1 sentinel) | `raxol_terminal/.../capabilities/probe.ex` | **live** (F0 T1 slice), pure clock-seam reducer |
| Reply parser (grammar-dispatch, both OSC terminators, leak-free residual) | `.../capabilities/reply_scanner.ex` | **live**; captures `osc11` |
| Classifier → `%Capabilities{}` (tier, `truecolor`, provenance `source`) | `.../capabilities/classifier.ex` | **live**; **discards `osc11`** ⚠ |
| Session record + `:persistent_term` write-once cache | `.../capabilities/capabilities_record.ex` | **live** |
| Env-var truecolor decision (`$COLORTERM ∈ {truecolor,24bit}`, XTGETTCAP `RGB` > env) | `classifier.ex` `decide_truecolor/2` | **live** |
| H-K salience solver (ground → per-tier apparent-lightness targets) | `raxol/ui/theming/salience.ex` | **live** (sign-flip fix in flight) |
| Ground detection consumer | `raxol/ui/theming/salience_theme.ex` `detect_ground/0` | **live**; reads `BackgroundQuery`, not `Capabilities` ⚠ |
| Polarity-preserving ANSI-16 role table (loud/soft × dark/light pins) | `raxol/ui/theming/ansi16_salience.ex` | **live**; **not wired into render path** ⚠ |
| Nearest-color (squared-RGB Euclidean) 16/256 quantizers | `raxol/ui/theming/colors.ex` `find_closest_{basic,256}_color/1` | **live** |
| Truecolor SGR emit (`\e[38;2;r;g;b m` / `\e[38;5;n m`) | `raxol_terminal/.../renderer.ex` | **live**; **no capability gate** ⚠ |

The four ⚠ are exactly the seams this proposal closes. Nothing new is invented; the gaps are:
**(1)** the batched probe drops the background it parses; **(2)** the ground consumer reads the
old standalone module instead of the unified record; **(3)** the honest ANSI-16 table is built
but never reached at render time; **(4)** the renderer emits truecolor unconditionally with no
downgrade for 256/16/no-color terminals.

---

## 1. The one governing rule (inherited from F0 §2)

**Silence is the failure mode, not a NAK.** A terminal that cannot answer OSC 11 / OSC 4 /
XTGETTCAP says *nothing*. Every color query rides the same `CSI c` (DA1) sentinel the F0 probe
already emits last: read to DA1, and any color reply that didn't arrive is "unsupported →
conservative default." This is the sole reason color detection can be bounded rather than a
hang. It also means color detection **must not add its own timeout** — it is one more reply
class inside the existing single probe pass, not a second round-trip.

Corollary: **provenance is load-bearing.** Every color fact carries its `source` (`:osc11`,
`:osc4`, `:colorfgbg`, `:colorterm`, `:xtgettcap`, `:default`) exactly as `Capabilities.source`
already does for modes. `$COLORTERM` does not survive ssh/sudo/tmux, so an env-sourced truecolor
claim is weaker than an XTGETTCAP-probed one — the classifier already encodes this priority
(`RGB` cap > `$COLORTERM`), and the color-depth resolution below reuses it verbatim.

---

## 2. Detection ladder

One pass, cheapest-first, each rung falling through to the next on silence. Rungs 3–5 are
**bytes added to the existing F0 batched write**, before the DA1 sentinel — not new round-trips.

```
Rung 0 — NO_COLOR gate (free, env)
    $NO_COLOR non-empty  → color_depth: :none. Honor absolutely; skip all color emit.
    (Empty string == unset, per the standard.)

Rung 1 — color-depth seed (free, env + terminfo)
    $COLORTERM ∈ {truecolor, 24bit}      → seed :truecolor  (source: :colorterm, weak)
    terminfo RGB / Tc present             → seed :truecolor  (source: :terminfo)
    $TERM matches *-256color / terminfo colors≥256 → :ansi256
    else                                  → :ansi16   (Core floor; 8/16 assumed)

Rung 2 — polarity seed (free, env)  [fallback only, used iff rung 3 is silent]
    $COLORFGBG "fg;bg" (konsole/rxvt family): 2nd field is bg ANSI index.
        bg ∈ {0..6, 8}  → dark ;  bg ∈ {7, 15} → light   (source: :colorfgbg)
    Not set by iTerm2/Terminal.app/kitty/wezterm — absence is normal, not signal.

Rung 3 — OSC 11 background (probe, authoritative)   ← already in the batched write
    ESC ] 11 ; ? BEL   →   ESC ] 11 ; rgb:RRRR/GGGG/BBBB (BEL|ST)
    Parsed → {r,g,b} → H-K apparent lightness = the ground (amendment A6: not
    nominal OKLCH L). Overrides rung 2. (source: :osc11)

Rung 4 — truecolor certainty (probe, upgrades rung 1)  ← XTGETTCAP already in F0 batch
    DCS + q 524742 ST → RGB cap echoed  → :truecolor certain (source: :xtgettcap)
    (Optional stronger check: emit SGR 48:2:1:2:3, DECRQSS-read it back; out of scope v1.)

Rung 5 — palette-slot truth (probe, OPTIONAL, gates 16-color mapping mode)
    OSC 4 ; n ; ? BEL  for n ∈ 0..15  →  ESC ] 4 ; n ; rgb:.../.../... (BEL|ST)
    If answered → known_palette: %{0..15 => {r,g,b}}  → nearest-color 16-map is legal.
    If silent   → slots are user-themed and UNKNOWN → role-pinning is the ONLY honest map.

Rung 6 — default (silence past DA1)
    No OSC 11:   ground = Salience.reference_ground() (0.2, dark), polarity from rung 2 else dark.
    No color:    color_depth from rung 1 seed. tier from Capabilities.
```

Rung 5 is deliberately optional and last: 16 OSC 4 queries is the most expensive rung, most
terminals answer OSC 11 (which is enough for the solver), and the 16-color path is a fallback.
Gate rung 5 behind `color_depth == :ansi16 and want_known_palette?` so truecolor sessions never
pay for it.

### tmux / screen (F0 §7 step 4, reused)

tmux does **not** forward a bare OSC 11 to the outer terminal and does not reliably answer it
itself — the query times out unless wrapped. The F0 probe already emits the passthrough variant
`\ePtmux;<ESC-doubled payload>\e\\` when `$TMUX` is set and `allow-passthrough` is on (default
**off** since tmux 3.3a). When passthrough is off: clamp to the rung-1/rung-2 env seed, never
trust `$TERM=screen`, and accept the reference-ground default. No new tmux logic — color queries
go in the *same* passthrough payload F0 already builds (`@passthrough_payload` is exactly OSC 11
+ XTVERSION; add OSC 4 there only if rung 5 is enabled).

---

## 3. Data flow — where the result lives, how it reaches solver + renderer

Single source of truth: the **`%Capabilities{}` record** in `:persistent_term`, written once by
the probe. This proposal *adds fields*; it does not add a second cache. (The standalone
`BackgroundQuery.detected_background/0` becomes a thin shim over `Capabilities` during migration,
then is retired — see §7.)

```
raxol_terminal (owns the wire)
────────────────────────────────────────────────────────────────────
  Probe.step/2  ──emits──►  batched write (OSC11 + XTGETTCAP + [OSC4] + DA1)
      │
  ReplyScanner ──captures──►  osc11, osc4 slots, xtgettcap RGB
      │
  Classifier.classify/3 ──►  %Capabilities{
      │                         + background:   {r,g,b} | nil        (NEW, source :osc11)
      │                         + color_depth:  :truecolor|:ansi256|:ansi16|:none  (NEW)
      │                         + known_palette: %{0..15=>{r,g,b}} | nil  (NEW, source :osc4)
      │                         + polarity:     :dark | :light         (NEW, derived)
      │                         truecolor, tier, source{...}  (existing)
      │                      }
  Capabilities.cache/1 ──►  :persistent_term (write-once)

  Derived readers (pure, no I/O):
      Capabilities.ground/0        → H-K apparent lightness of background, else reference_ground()
                                       (amendment A6: not nominal OKLCH L)
      Capabilities.polarity/0      → :dark | :light   (from ground, 0.5 cutoff)
      Capabilities.color_depth/0   → the tier the renderer gates on

main raxol (consumes)
────────────────────────────────────────────────────────────────────
  SalienceTheme.detect_ground/0  ──reads──►  Capabilities.ground/0
      │   (today reads BackgroundQuery; repoint to the unified record)
  Salience.solve_palette(seeds, ground:, polarity:)  ← polarity from Capabilities.polarity/0
      │
  Theme  ──►  hex colors per semantic role

  Renderer color-resolution seam (NEW, §5)
      resolve_color(hex_or_role, Capabilities.color_depth, Capabilities.known_palette, polarity)
        :truecolor → \e[38;2;r;g;b m           (unchanged, current default)
        :ansi256   → nearest-256 in OKLab       (upgrade metric, §6)
        :ansi16 + known_palette → nearest-16 in OKLab over real slot RGB
        :ansi16 + unknown       → Ansi16Salience.slot(role, polarity, prominence)  ← honest path
        :none      → emit no SGR color at all
```

Key placement decision: the **role → hex** mapping (solver) and the **hex/role → wire** mapping
(downgrade) are *different stages*. The solver runs once per theme build in main raxol. The
downgrade runs per cell at render time in `raxol_terminal`. The 16-color honest path needs the
*semantic role*, not just the solved hex (nearest-RGB on a solved hex is the lossy path
`Ansi16Salience`'s moduledoc explicitly warns against). Therefore the render pipeline must carry
the role token alongside the resolved hex down to the renderer for the `:ansi16 + unknown` case —
this is the one non-trivial plumbing change and belongs in §4/open-questions.

---

## 4. Capability tiers (color axis)

Color depth is an axis orthogonal to F0's `tier` (Core/Modern/Rich) and to the `Ladder`'s render
mode (inline_log/tmux/flat). A Rich terminal can be `:ansi256` (256-color truecolor-less), a Core
terminal can be `:truecolor`. Do **not** fold color into the existing `tier`.

| `color_depth` | Detected by | Emit | Downgrade rule |
|---|---|---|---|
| `:truecolor` | `$COLORTERM`∈{truecolor,24bit} \| XTGETTCAP `RGB` \| terminfo `RGB`/`Tc` | `38;2;r;g;b` | none (native) |
| `:ansi256` | `$TERM=*-256color` \| terminfo `colors≥256`, no truecolor | `38;5;n` | truecolor hex → nearest-256 (OKLab) |
| `:ansi16` — **known palette** | `color_depth :ansi16` **and** OSC 4 answered | `38;5;0..15` | nearest-16 (OKLab over real slot RGB) |
| `:ansi16` — **unknown palette** | `:ansi16` **and** OSC 4 silent (the common case) | `30–37/90–97` | **role-pin** via `Ansi16Salience` (never nearest-RGB) |
| `:none` | `$NO_COLOR` non-empty | no color SGR | — |

The **known vs unknown palette split** is the crux of honest 16-color rendering and the single
most important design decision here:

- When the actual RGB of slots 0–15 is **known** (OSC 4 answered), nearest-color quantization is
  legal because we are matching against the values the user will actually see.
- When it is **unknown** (OSC 4 silent — most terminals, since the 16 slots are user-themed and
  unqueryable), nearest-RGB against a *guessed* palette is a lie: the user's slot 1 ("red") could
  be any hue. The only honest map is by **semantic category + polarity**, which is precisely what
  `Ansi16Salience` already encodes (error→a red slot, success→a green slot, chosen bright-on-dark
  / normal-on-light, with a WCAG-3:1 legibility floor). This proposal's contribution is to
  **route to it**, not to build it.

---

## 5. Dark ↔ light polarity decision

The solver's `:auto` polarity and `Ansi16Salience.polarity/1` already agree on the cutoff:
**OKLCH `L < 0.5` → dark canvas** (solve/pin *lighter* from ground), **`L ≥ 0.5` → light**
(solve *darker* from ground). Keep that single cutoff; do not introduce a second threshold.

Vision realized: on a light terminal, prominence steps move **darker** from the background; on a
dark terminal, **lighter**. The prominence range always sits between the terminal-defined dark and
light extremes because the solver's headroom-compression (`tier_target/3`) already clamps deltas to
displayable apparent-lightness bounds `[0.03, 0.97]` around the *detected* ground. Text with no
color attribute resolves to the `:baseline` tier against the ground — which, by construction, is a
fixed apparent-lightness delta from the background and therefore a stable, WCAG-distance-correct
contrast regardless of whether the terminal is `#1e1e1e` or `#fdf6e3`. This is the whole point:
**one seed table, correct contrast on every terminal, because the ground is measured not assumed.**

**Mid-gray grounds** (`L ≈ 0.45–0.55`, e.g. a gray Solarized-ish surface) are the hazard: a hard
`< 0.5` flip means `L = 0.49` solves up and `L = 0.51` solves down, and near the cutoff *both*
sides have little headroom, so tiers compress hard and prominence separation shrinks. Options
(pick one, §8 open question):
- **(a) Hard cutoff (status quo).** Simple, deterministic, but a near-gray terminal gets a
  low-separation palette. Acceptable because near-gray terminals are rare and the compression is
  graceful (ordering preserved, never inverted).
- **(b) Dead-band + hysteresis.** Between `L ∈ [0.45, 0.55]` pick the side with *more* headroom
  (i.e. `L < 0.5` → up is already the more-headroom side, so this only matters exactly at 0.5) and,
  for live `mode 2031` theme flips, add hysteresis so a hovering-at-gray OS theme doesn't thrash.
- **(c) Chroma-aware.** A saturated mid-L ground (rare in terminals) could bias polarity toward the
  lower-chroma side. Almost certainly over-engineering for v1 — note and drop.

Recommendation: **(a) for v1**, revisit **(b)** only if a real mid-gray terminal theme surfaces
during dogfood. (scope-mode: Hold Scope.) — **RATIFIED by V 2026-07-19 (amendment A5).**

---

## 6. Distance metric for the nearest-color rungs

The current quantizers (`colors.ex color_distance_sq`) use **squared-RGB Euclidean**, which is
perceptually wrong (it over-weights green, under-weights blue, and disagrees with the H-K model the
rest of the theming stack runs on). For the `:ansi256` and `:ansi16-known` rungs, switch the
metric to **OKLab ΔE** — Euclidean distance in OKLab — which `salience.ex` already has the full
sRGB↔OKLab machinery for (`rgb_to_oklch`, `oklab_to_linear`). Rationale from the color-difference
literature: CIELAB/OKLab are the perceptually-uniform spaces designed for exactly this "map a
truecolor pixel to the nearest palette entry" problem; weighted-RGB (redmean) is the fast
approximation you reach for only when you lack a Lab transform — Raxol already has OKLab, so pay
nothing and get the perceptual metric. **Do not** use OKLab for the unknown-palette-16 rung — there
is no palette to measure distance against there; that rung is role-pinning, not quantization.

This is an isolated, testable change: `find_closest_256_color/1` and `find_closest_basic_color/1`
keep their signatures, swap the internal distance function. (Their doc already steers semantic
roles to `Ansi16Salience`; this only improves the *non-semantic* raw-color quantization path.)

---

## 7. Module boundaries — who owns what

Strict: **raxol_terminal owns every byte on the wire; main raxol theming only ever reads a pure
record.** No OSC bytes are ever emitted from `lib/raxol/ui/`.

**raxol_terminal (`packages/raxol_terminal/lib/raxol/terminal/`):**
- `capabilities/reply_scanner.ex` — already captures `osc11`; add OSC 4 slot capture (only if
  rung 5 enabled).
- `capabilities/classifier.ex` — **stop discarding `osc11`.** Add `background`, `color_depth`,
  `known_palette`, `polarity` to the classification, each with a `source`. Reuse the existing
  `decide_truecolor/2` priority for `color_depth`.
- `capabilities/capabilities_record.ex` — add the four fields + pure derived readers
  `ground/0`, `polarity/0`, `color_depth/0`. Add `$NO_COLOR` and `$COLORFGBG` to the env seed the
  classifier consumes.
- `capabilities/probe.ex` — extend `@query` / `@passthrough_payload` with OSC 4 bytes *only* when
  the 16-color-known path is requested; otherwise unchanged.
- `renderer.ex` — add the color-resolution seam (§3 bottom): gate `resolve_fg_ansi` /
  `resolve_bg_ansi` on `color_depth`, routing to nearest-256 / nearest-16-known / role-pin / none.
  This is where the render-time downgrade lives.
- `driver/background_query.ex` — **retire** after migration; during migration make
  `detected_background/0` delegate to `Capabilities.background`.

**main raxol (`lib/raxol/ui/theming/`):**
- `salience_theme.ex` — repoint `detect_ground/0` at `Capabilities.ground/0`; pass
  `Capabilities.polarity/0` into `Salience.solve_palette(..., polarity:)`.
- `ansi16_salience.ex` — unchanged data; becomes *reached* via the renderer seam. Its `polarity/1`
  and the record's `polarity/0` must return the same value from the same ground (shared cutoff).
- `colors.ex` — swap the nearest-color distance metric to OKLab (§6).

Cross-package discipline (per CLAUDE.md): main raxol already refers to
`Raxol.Terminal.Driver.BackgroundQuery` behind `@compile {:no_warn_undefined, ...}` +
`Code.ensure_loaded?/1`. The unified reader `Capabilities.ground/0` is accessed the same guarded
way — theming degrades to `reference_ground/0` when the terminal package/record is absent (headless,
LiveView, tests), which is the current behavior preserved.

---

## 8. Open questions for V

- ~~**Q-role-plumbing.**~~ **ANSWERED (amendment A4):** option (a) — the sibling design's
  `%ColorIntent{role: ...}` threads the semantic role to the resolver at the cell-emission
  choke point. `Ansi16Salience` is reached via that field.
- **Q-osc4-cost.** Enable rung 5 (16× OSC 4 queries) always on `:ansi16`, or only behind an opt-in
  flag / only when the app declares it needs known-palette fidelity? 16 queries is the heaviest
  rung and only helps genuine 16-color terminals (increasingly rare).
- ~~**Q-midgray.**~~ **ANSWERED (amendment A5, V):** option (a), hard 0.5 cutoff for v1.
- **Q-live-reflow.** F0 mode 2031 gives live OS dark/light flips. When the ground changes
  mid-session, does the whole theme re-solve + full repaint (simple, correct, a flash) or diff-only
  restyle (complex)? The record is currently *write-once immutable* — live theme events need a
  second, explicitly-mutable "current ground" cell separate from the immutable capability record, or
  a documented exception to write-once. Flag now, decide with F0's 2031 work.
- **Q-colorfgbg-trust.** `$COLORFGBG`'s bg field is an ANSI *index* (0–15), not RGB, and its
  light/dark convention (`15;0` vs `0;15`) is only loosely standardized across konsole/rxvt/urxvt
  (urxvt sometimes emits a 3-field form). Trust it as a polarity seed only (never as a ground), and
  only when OSC 11 is silent — confirm that's the intended weight.
- **Q-retire-bgquery.** Confirm `driver/background_query.ex` should be *retired* into the unified
  record rather than kept as a second live path. (It predates the F0 batched probe and now
  duplicates a strict subset of it.)

---

## 9. Sequence (design-only; no implementation here)

1. `Classifier` stops discarding `osc11`; add `background` + derived `ground/0`, `polarity/0` to the
   record. (Smallest, highest-value: the ground the solver wants is already parsed and thrown away.)
2. Repoint `SalienceTheme.detect_ground/0` at the unified record; pass polarity through. Retire
   `BackgroundQuery` behind a delegating shim.
3. Add `color_depth` classification (`$NO_COLOR` → `$COLORTERM`/terminfo → `$TERM` → floor) with
   provenance; add `$COLORFGBG` polarity seed.
4. Swap nearest-color metric to OKLab (§6) — isolated, unit-testable against known fixtures.
5. Renderer color-resolution seam: gate on `color_depth`, route truecolor/256/16-known. (Resolve
   Q-role-plumbing before wiring the 16-unknown → `Ansi16Salience` leg.)
6. (Optional) OSC 4 rung 5 + `known_palette`, behind the Q-osc4-cost decision.
7. (Deferred to F0 2031) live ground re-solve — needs the write-once exception from Q-live-reflow.

---

## Sources

- [Terminfo.dev — Terminal Color Detection: NO_COLOR, COLORTERM, OSC Probes](https://terminfo.dev/fundamentals/color-detection) — OSC 10/11/4 sequences + `rgb:` reply format, `$COLORTERM ∈ {truecolor,24bit}`, `$NO_COLOR` "honor absolutely", 100–200ms timeout guidance, "assume ≤256 if COLORTERM unset".
- [termstandard/colors](https://github.com/termstandard/colors) + [kurahaupo truecolor gist](https://gist.github.com/kurahaupo/6ce0eaefe5e730841f03cb82b061daa2) — `$COLORTERM` truecolor semantics, not forwarded via ssh/sudo/tmux, terminfo `RGB` cap since ncurses-6.0-20180121, `$TERM=xterm-256color` as broad floor.
- [rocky/shell-term-background](https://github.com/rocky/shell-term-background) + [Canop/terminal-light](https://github.com/Canop/terminal-light) — OSC 11 → luminance → dark/light; `$COLORFGBG` `fg;bg` convention (`0;15` dark, `15;0` light); 20ms/0.1s read timeouts; fallback order OSC 11 → COLORFGBG → `$TERM` default.
- [microsoft/terminal #19904](https://github.com/microsoft/terminal/issues/19904) + [#3718](https://github.com/microsoft/terminal/issues/3718) — OSC 11 reply leaking into the prompt when not consumed (the reply-drain requirement); Windows Terminal OSC 10/11/12 support history.
- [tmux allow-passthrough guide](https://tmuxai.dev/tmux-allow-passthrough/) + [tmux/tmux #5237](https://github.com/tmux/tmux/issues/5237) + [openai/codex #19741](https://github.com/openai/codex/issues/19741) — tmux does not forward bare OSC 11, `allow-passthrough` (3.2+, default off since 3.3a), DCS wrap `\ePtmux;<ESC-doubled>\e\\`, tmux answering OSC 10/11 from the first attached client.
- [compuphase — Colour metric (redmean)](https://www.compuphase.com/cmetric.htm) + [Color difference — Wikipedia](https://en.wikipedia.org/wiki/Color_difference) — perceptual nearest-color: CIELAB/OKLab Euclidean is the perceptually-uniform choice, weighted-RGB (redmean) is the fast approximation used when a Lab transform is unavailable.
- [tmuxai — Terminal Compatibility Matrix](https://tmuxai.dev/terminal-compatibility/) + [g.p. anders — State of the Terminal](https://gpanders.com/blog/state-of-the-terminal/) — OSC 11 support across Alacritty/kitty/WezTerm/iTerm2/foot/Windows Terminal and the silent-ignore degradation behavior.
- Internal: `docs/proposals/in-flight/f0-capability-detection.md` (batched probe, DA1 sentinel, tiers, tmux passthrough), `tui-steal-list.md` #7c/#8, `palette-inventory.md` (existing 16-color table sprawl).
