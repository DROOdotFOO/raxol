# Region Prominence Propagation — intent colors resolved at the render choke point

Date: 2026-07-19 · Status: **Phases 0–3 LANDED** (2026-07-19: P0 `9ddb74167`, P1 `d9ae0ebc7`, P2 `cfa1e6eb7`, P3 `b335f91fa`; γ_region pinned closed-form `ln(0.65)/ln(0.45)` by byte-exact modal parity — component-own fades stay γ=1 pending the eye pass). **Phase 4 LANDED-PENDING-REVIEW** (`Raxol.UI.RegionPolicy` + `Raxol.UI.Layout.Engine`'s `region:` marker/focus wiring — see §9 Phase 4 for scope, Q6 answered as an interim per that section). Human-eye matrix (§8 RP-H-*) still outstanding for the whole design.

**Ratification log (V, 2026-07-19):**
- **Engine-core placement ratified.** Prominence propagation is a rendering-engine-core
  primitive — a render-context mechanism analogous to React contexts, flowing down the
  element tree and composing multiplicatively (C1). Canonical example: two panes scrolling
  individually — the inactive pane gets lowered prominence; a modal mounted above both
  lowers them further, **combined** (pane-defocus × overlay). Ad-hoc per-component fade
  implementations are prohibited once Phase 2 lands; the three existing sites migrate onto
  the core mechanism, never the reverse.
- **Q2 answered: AA 4.5, not AAA 7.0**, as the `:text` floor. Rationale: a person who
  needs higher contrast already configures a higher-contrast terminal palette — the ground
  and native range reflect that choice, and we exist *within* that range rather than
  fighting it. AAA available as explicit `{:ratio, 7.0}` opt-in.
- **Q5 answered: yes** — literal colors participate in region fading by default
  (matching today's modal dim of literals); `{:fixed, color}` remains the exemption.
- **Mid-gray polarity: hard 0.5 cutoff** (see sibling doc §5 option (a), ratified).
- Still open: Q1 (γ), Q3 (peer level / depth falloff), Q4 (region identity), Q6–Q8.
Owner ask: components hand off **(hue, chroma, prominence) intents**, not literal
colors; the window-stack manager resolves them **at render level against the
actual ground**; when one region gains focus, **other regions de-prominence
proportionally**; prominence **composes through the layer/region stack**.

This doc must (and does, §3.4/§6) fix by construction the two findings from
`harness-ui-testing/05-salience.md`:

- **F1** — fades hardcoded to the near-black reference ground invert on light
  themes (`05-salience.md:31-47`; live instance:
  `lib/raxol/ui/components/harness/diff_viewer.ex:535`).
- **F2** — the "0.4 floor" floors the *input multiplier*, not *output
  legibility* (`05-salience.md:49-63`). The clamp here is on the **output WCAG
  ratio against the LOCAL resolved background**, applied **after** composition.

Solver-model note: a sign-flip bugfix of the H-K solver is in flight. This
design treats the model abstractly as

```
AL(L, C, h) = L + k·C·hue_factor(h)        # chromatic reads BRIGHTER
```

and every formula below is written in terms of `AL(...)` / `solve_L(...)`, so
the fix lands underneath without touching this design. Where current code is
cited (`lib/raxol/ui/theming/salience.ex:79`, sign `-`), read it as "the model,
whichever sign is ratified".

---

## 1. Problem statement

Three problems, one root cause — color decisions are made **too early**, before
the ground, the capability tier, and the focus state are known:

1. **Literal colors in the view tree.** Components emit `fg: :cyan`,
   `fg: "#c1712c"`, or the `:white` default
   (`lib/raxol/ui/element_renderer.ex:347-348`). By the time the terminal's
   real background is known (OSC 11,
   `lib/raxol/ui/theming/salience_theme.ex:45-55`), the color is already a
   literal — it cannot adapt direction (dark-on-light vs light-on-dark), cannot
   re-solve for a mid-gray ground, and cannot degrade sanely to 16 colors.
   Attribute-less text resolves to `:white` — illegible on a white terminal,
   never contrast-checked anywhere.

2. **Prominence is component-private.** Three separate fade implementations
   exist, each resolving eagerly at its own layer:
   - `Raxol.UI.Harness.Prominence.resolve/3`
     (`lib/raxol/ui/harness/prominence.ex:187-206`) — ground-aware, opt-in
     legibility clamp, needs-input floor. Correct, but callers must thread
     ground and prominence by hand per call.
   - `DiffViewer.fade_toward_ground/2`
     (`lib/raxol/ui/components/harness/diff_viewer.ex:532-542`) — F1: ground is
     the constant `Salience.reference_ground()`.
   - `Raxol.UI.CellDim` (`lib/raxol/ui/cell_dim.ex`) — modal-backdrop dimming,
     its own `(contrast_keep, chroma_keep)` pair, applied per cell after
     rendering.
   These cannot compose: a diff line at prominence 0.6 inside a defocused
   region behind a modal is faded once, by whichever mechanism runs, not by
   the product of all three.

3. **Only modals de-prominence anything.** The one region-level mechanism is
   the dialog dim: layout stamps `:in_dialog` / `:dim_behind_modal`
   (`lib/raxol/ui/layout/engine.ex:129-147`), the renderer calls
   `CellDim.dim_cells/1` (`lib/raxol/ui/ui_renderer.ex:112-113`). It is binary
   (dimmed or not), global (no nesting), and special-cased to dialogs. Focus
   moving between a sidebar and a main pane changes nothing about their
   relative visual weight. Modal-behind-dimming should be **one special case of
   a general region-prominence mechanism** — it currently *is* the mechanism.

## 2. Prior art in this repo

| Piece | Where | What it gives us | What it lacks |
|---|---|---|---|
| H-K salience solver | `lib/raxol/ui/theming/salience.ex` — tiers `:alarm/:recede/:differentiate/:baseline/:anchor` (`:32-38`), `tier_target/3` with headroom compression (`:123-135`), `:auto` polarity by ground side (`:137-139`), gamut-mapped OKLCH→sRGB (`:161-192`) | the `(tier, C, h, ground) → hex` engine; direction-correctness and mid-gray compression already solved | consumed eagerly by components, not by the renderer |
| Seed-table theme | `lib/raxol/ui/theming/salience_theme.ex:25-34` | proof that a whole palette can be `(h, c, tier)` seeds solved at runtime against detected ground | builds a static `Theme` once; not per-cell, not prominence-aware |
| Prominence attribute | `lib/raxol/ui/harness/prominence.ex` — fade line `fade_color/5` (`:229-231`), opt-in output-WCAG clamp with bisection (`:296-348`), needs-input floor 0.6 (`:128`), identity at ≥1.0 (`:190`) | the fade/clamp math, the pure-fade vs floored two-mode policy, the starvation guard | caller-driven; no notion of region or composition; truecolor-only |
| Prominence ladder | `diff_viewer.ex:512-517` (1.0/0.8/0.6/0.4), `lib/raxol/harness/recency_policy.ex` (same ladder, "no new tiers" fence, seal-time grading law) | the ratified tier values; the purity discipline (`policy(state, focus)` is a pure map) | per-block only; no region dimension |
| Sub-prominence riding | `diff_viewer.ex:559-562` — gutter rides 20pp under its row, clamped at floor | precedent for *relative* prominence (child offset from parent) | additive-clamped, ad hoc; should become own×region composition |
| Modal dim | `lib/raxol/ui/cell_dim.ex:202-208` (`contrast_keep 0.45`, `chroma_keep 0.65`), stamped by `engine.ex:136-147`, applied at `ui_renderer.ex:112-113` | the **choke point** ("every element type eventually becomes cells before paint — dimming is implemented once here", `cell_dim.ex:5-9`); apparent-lightness-space interpolation | binary, non-nesting, dialog-only; its `(0.45, 0.65)` pair is a second, incompatible fade parameterization |
| Dialog overlay | `lib/raxol/ui/components/absolute_layer.ex:109-119`, demo `lib/raxol/playground/demos/modal_demo.ex:56-66` | the layer/overlay structure regions can hang off | overlays aren't first-class regions; only `dialog: true` has semantics |
| 16-color degradation | `lib/raxol/ui/theming/ansi16_salience.ex` | role→slot pinning with polarity awareness and an explicit legibility>category>tier priority ranking | consumes roles, not intents; not wired to a prominence ladder |
| Test discipline | `05-salience.md` — SAL-P/SAL-N/SAL-POL suites, guarantee→falsifier, human-eye protocol §5 | the test-matrix pattern §8 follows | — |
| Identity exclusion | `lib/raxol/harness/projection.ex:143-144` — salience/prominence explicitly NOT in either identity key | prominence is presentation, never transcript content — the resolver must stay downstream of identity | — |

**Load-bearing discovery:** `lib/raxol/ui/rendering/composer.ex:6-9` and
`lib/raxol/ui/rendering/painter.ex:6-9` are **stubs** ("Currently a stub…").
The real pipeline today is:

```
view/1 → Preparer → Layout.Engine (positions + dim_behind_dialog post-pass)
       → Raxol.UI.Renderer.render_to_cells (ui_renderer.ex) → ElementRenderer
       → cells {x, y, char, fg, bg, attrs} → maybe_dim → buffer diff → ANSI
```

So "as close to render as possible" concretely means: **the cell-emission
choke point where `maybe_dim` sits today** (`ui_renderer.ex:103-115`), fed by a
**region stamp generalized from the `dim_behind_dialog` layout post-pass**
(`engine.ex:129-147`). Not the stub Composer/Painter.

## 3. Proposed architecture

Four pieces. Everything upstream stays symbolic; exactly one late pass turns
symbols into bytes.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ view/1 (components)                                                        │
│   emit ColorIntent (h, c, tier|prominence) or literal colors (escape       │
│   hatch), plus optional region: markers on containers                      │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ element tree (symbolic colors survive)
┌──────────────▼─────────────────────────────────────────────────────────────┐
│ Layout.Engine                                                              │
│   positions elements; REGION STAMP pass (generalizes dim_behind_dialog):   │
│   every positioned element carries region_path: [root, ...]                │
└──────────────┬─────────────────────────────────────────────────────────────┘
               │ flat positioned list, region_path stamped     ┌────────────┐
               │                                               │ Focus /    │
               │                        region prominence map  │ Region     │
               │                  ┌────────────────────────────│ Policy     │
               │                  │  %{region_path => p}       │ (pure fn)  │
┌──────────────▼──────────────────▼───────────────────────┐    └────────────┘
│ Raxol.UI.Renderer → cells {x,y,char,fg,bg,attrs}        │  ┌─────────────┐
│                                                         │  │ Detection   │
│ ★ RESOLUTION PASS (Raxol.UI.ColorResolver) ★            │◄─┤ (given):    │
│   per cell:                                             │  │ ground OSC11│
│   1. resolve bg intent against enclosing ground         │  │ + capability│
│   2. effective_p = own_p × Π region_p × Π overlay_p     │  │ tier        │
│   3. resolve fg intent at effective_p vs LOCAL ground   │  └─────────────┘
│   4. output legibility clamp (WCAG vs LOCAL bg) — F2    │
│   5. capability degrade (truecolor / 256 / 16)          │
└──────────────┬──────────────────────────────────────────┘
               │ concrete cells (hex / palette index / ANSI slot + attrs)
┌──────────────▼───────────────────────────────────────────┐
│ ScreenBuffer diff → Terminal.Renderer → ANSI             │
└──────────────────────────────────────────────────────────┘
```

### 3.1 Intent representation

A color slot (`fg:` / `bg:` in styles; the `fg`/`bg` positions of a cell
tuple) accepts one more shape — the cell tuple already carries heterogeneous
terms (atoms, `{r,g,b}`, hex strings, integers; see `CellDim.dim_color/2`
clauses, `cell_dim.ex:130-150`), so intents ride the existing slots with no
tuple-shape change:

```elixir
%Raxol.UI.ColorIntent{
  h: 0..360 | nil,          # hue identity; nil = achromatic
  c: float,                 # chroma; 0.0 = neutral
  tier: Salience.tier() | nil,   # semantic tier (preferred), OR
  prominence: float | nil,  # explicit scalar 0.0..1.0 (component-own p)
  role: atom | nil,         # semantic role for ANSI-16 slot pinning
                            #   (:error, :accent, ... → Ansi16Salience)
  floor: :none | :ui | :text | {:ratio, float}
                            # legibility class, see §3.4. Default :none for
                            # explicit intents; attr-less text gets :text.
}
```

Rules:

- **`tier` and `prominence` are two entries to the same axis.** `tier` is
  resolved to the tier's apparent-lightness target
  (`Salience.tier_target/3`); `prominence` is a scalar on the fade line from
  the baseline-tier target. A component states *either* ("I am `:recede`
  chrome") *or* ("I am this row at 0.6"). Both compose identically with
  region prominence (§5).
- **Defaulting: no color attribute ⇒ baseline-tier neutral intent.**
  `%ColorIntent{h: nil, c: 0.0, tier: :baseline, floor: :text}` replaces
  today's `fg: :white` default (`element_renderer.ex:347-348`). This is the
  single change that makes attr-less text resolve to proper contrast in the
  correct direction on any ground: `:auto` polarity picks the headroom side
  (`salience.ex:137-139`), the `:text` floor post-checks it (§3.4).
  **Degenerate case, ratified (Phase 3, §9):** the intent above only fires
  when the element itself has a painted bg. When the enclosing bg is
  unpainted (`nil`), fg stays `nil` end-to-end -- never a solve against a
  guessed or reference ground -- and the terminal's own default fg shows
  through (`packages/raxol_terminal/.../renderer.ex`'s `nil`-fg path emits
  no fg SGR). This is the PRIMARY case and holds even when no ground was
  ever detected/cached, since a `nil` fg short-circuits before any ground
  read. **CLOSED (landed via native-palette-riding.md §7):** an element
  with an unpainted OWN bg that sits visually over an ancestor's/sibling's
  painted bg (paint-order grid, §3.5) used to fall to this `nil` case --
  terminal-default fg over a raxol-painted bg, an accepted interim while
  the gap stayed open. `Raxol.UI.ColorResolver.resolve_cell/4`'s
  `grid_bg_floor_fg/3` is the one-line fix this section reserved: a
  `nil`-fg cell whose LOCAL grid bg (the paint-order grid's `under` entry
  at that coordinate) is non-`nil` now gets the SAME baseline-tier,
  `:text`-floored intent this section's producer already emits for an
  explicitly painted own bg, before resolution proceeds. The producer
  (`style_processor.ex`'s `default_fg_intent/2`) is unchanged -- it still
  cannot see the grid and still correctly returns `nil` for its own
  nil/nil case; the promotion happens one layer down, inside the
  resolver, where the grid actually lives. The PRIMARY nil-fg-over-
  nothing-painted case (no grid entry at all) is untouched and still
  holds with no ground ever detected/cached.
- **Backward compat / escape hatch — literal colors remain valid.** Hex
  strings, `{r,g,b}` tuples, ANSI atoms, and 256 palette integers pass
  through the resolver as today. They still participate in **region**
  prominence (faded via the `Prominence.fade` path, exactly like `CellDim`
  fades literals for modals today) — unless wrapped `{:fixed, color}`, which
  exempts a color from all fading (the "I really mean these bytes" hatch;
  needed for e.g. syntax-highlight themes under screenshot goldens).
- **`bg` intents and the transparency sentinel.** `bg: nil` stays the
  unpainted/transparent sentinel (`element_renderer.ex:349-352`,
  `CellDim.dim_bg/2` `nil` pass-through). A bg *intent* means "paint a
  surface at this tier relative to the enclosing ground" (e.g. a modal
  surface one step off the ground, a diff row wash). The resolver resolves bg
  intents **first**, top-down, because a resolved bg becomes the LOCAL ground
  for every fg inside it.

### 3.2 Region model

**A region is a scope annotation on a container, not a new element type.**
Three sources, unified into one `region_path`:

1. **Explicit:** any container element may carry `region: id` (stable atom or
   string chosen by the app — stable across re-renders, like widget focus
   ids in `Raxol.UI.FocusHelper`).
2. **Implicit from the layer stack:** each `:absolute_layer` overlay is a
   region; the `flow_child` is a region. `dialog: true`
   (`absolute_layer.ex:109-119`) additionally marks the overlay a **dimming
   region**: while mounted, it pushes an *overlay factor* onto every region
   not on its own path (this reproduces today's modal dim as the special
   case it should be).
3. **Nesting:** regions nest by containment; a positioned element's
   `region_path` is the list of enclosing region ids root-first
   (`[:app, :main, :diff_pane]`). Stamped during the layout walk exactly the
   way `clip_bounds` is threaded today (`ui_renderer.ex:303,341-344`), then
   available on the flat positioned list — generalizing the existing
   `dim_behind_dialog/1` flat post-pass (`engine.ex:136-147`), which becomes
   `stamp_region_prominence/2` and is subsumed.

**Focus → weights: a pure policy function** (the `RecencyPolicy` /
SAL-POL-05 discipline — no processes, no clocks):

```elixir
@spec region_prominence(region_tree, focus :: region_path | nil,
                        overlays :: [region_path]) :: %{region_path => float}
```

Default policy (ladder-respecting — the "no new tiers" fence from
`recency_policy.ex` applies; every constant below is from the shipped
1.0/0.8/0.6/0.4 ladder):

- The focused region and **every ancestor and descendant of it**: `1.0`
  (focus illuminates its whole path — a focused input must not dim its own
  panel).
- Every other region: one ladder step down, `@peer_level 0.8`.
- No focus at all (`nil`): every region `1.0` — **neutrality**: an app that
  never focuses a region renders byte-identically to pre-region code
  (the SAL-P-06 pattern).
- Each active dimming overlay (modal) multiplies every region not on its
  path by `@overlay_keep` — set to `CellDim.@contrast_keep = 0.45` so the
  shipped modal appearance is preserved (§5 chroma note).
- **Proportional variant (opt-in, `depth_falloff: true`):** peers at distance
  `d` in the region tree (siblings d=1, uncle-subtrees d=2, …) get
  `max(1.0 - 0.2·d, 0.4)` — the recency ladder applied spatially. Default
  OFF; the two-level default is predictable and covers the sidebar/main case.

The map rides the render context (precedent: `reduced_motion` already flows
through the Dispatcher's render context — CLAUDE.md render-pipeline notes;
`focused_element` already flows there for `FocusHelper.focused?/2`).

### 3.3 Resolution point (exact)

**One new module, `Raxol.UI.ColorResolver`, invoked where `maybe_dim` runs
today** — `ui_renderer.ex:103-115`, after `render_visible_element` +
clipping, before the cells leave `Raxol.UI.Renderer`. The comment at
`ui_renderer.ex:96-102` already names this the modal-dim choke point; it
becomes the *general* prominence choke point, and `maybe_dim`/`CellDim` are
reimplemented on top of it (§9 Phase 1).

Inputs that must flow there (all already exist or are provided by the
parallel detection task):

| Input | Source | Today |
|---|---|---|
| ground (OKLCH L of terminal bg) | OSC 11 via `SalienceTheme.detect_ground/0` (`salience_theme.ex:45-55`) / `BackgroundQuery` | exists |
| capability tier (`:truecolor` / `:color256` / `:color16`) | detection task (out of scope here; consumed as given) | provided |
| region prominence map | §3.2 policy, via render context | new |
| per-element `region_path`, `prominence`/intents | layout stamp + styles | new |
| LOCAL bg per cell | the cell's own resolved `bg`, else the **under-layer bg at that coordinate**, accumulated in paint order (§3.5), else ground | new bookkeeping (§3.5) |

Per-cell order of operations (the whole pass is one fold over the cell list,
with the same per-frame uniq-color memo `CellDim.dim_cells/1` uses at
`cell_dim.ex:67-85` — resolution cost is per *distinct* (intent,
effective_p, local_ground) triple, not per cell):

```
1. bg   := resolve_bg(bg_slot, enclosing_ground)      # intents solve vs ground
2. p    := own_p(fg_slot) × Π region_p(path) × Π overlay_p   # §5 law C1
3. fg   := resolve_fg(fg_slot, p, AL(bg or ground))   # solve ONCE at composed p
4. fg   := clamp_output(fg, bg or ground, floor_class(fg_slot))   # §3.4, F2
5. cell := degrade(fg, bg, capability_tier)           # §7
```

**Why exactly once, exactly here:** the fade is linear interpolation in
apparent-lightness space; composing scalars *then* resolving once is exact,
whereas fading at each stage (component fades, then region fades the result,
then modal fades that) accumulates gamut-clamp and 8-bit round-trip error and
— worse — re-derives `AL` from an already-quantized hex each time. The
existing three fade sites disagree today precisely because each resolves
early. Intents survive until the ground is known; scalars compose upstream;
bytes are minted once.

### 3.4 Legibility floor — output-contrast, LOCAL bg, post-composition (F2)

Adopted from `Prominence`'s two-mode design (`prominence.ex:30-45`) — a
universal floor would flatten the salience gradient, so the floor is a
**class**, not a constant:

- `floor: :none` — pure fade. Context/history tiers; recoverable on
  promotion, may fade to ground at p→0. (The gradient is the point.)
- `floor: :ui` — `@floor_ratio 3.0` (placeholder pending the human-eye
  ratification pass, `prominence.ex:73-76`). Interactive/acting content.
- `floor: :text` — **`@text_floor 4.5` (WCAG AA, normal text — ratified,
  see log)** — the class attr-less default text gets. Text with no color
  attribute lands at proper AA distance from its local background, in the
  correct direction. Direction is the solver's polarity; distance is this
  clamp. AAA is the explicit `{:ratio, 7.0}` opt-in, not the default:
  high-contrast needs are expressed by the user's own terminal palette, and
  the resolver rides the native range.
- `{:ratio, r}` — explicit override.

Mechanics: after step 3, `wcag_ratio(fg_hex, local_bg_hex)`
(`prominence.ex:240-245`) is checked against the class floor; on failure the
clamp walks back up the fade line by bisection exactly as
`Prominence.clamp_to_floor/7` does (`prominence.ex:296-348`), with the same
true-full-chroma ceiling and documented best-effort return when even p=1.0
misses (mid-gray grounds, §6). Two constructive differences from today:

1. the ratio is measured against the **LOCAL resolved bg** (the cell's own
   painted background if any), not the global ground — a light chip on a dark
   terminal clamps against the chip;
2. it runs **after** all composition, so no upstream stage can push a floored
   class back under the floor (region dim of a modal of a faded row —
   whatever the composed p, the floor is on the output).

The needs-input starvation guard stays and generalizes: `needs_input: true`
floors the **composed effective p** at `needs_input_floor 0.6`
(`prominence.ex:128`), i.e. a modal + defocused region + recency demotion
can never fade a pending approval below ordinary context (SAL-N-04's
invariant, now over the full composition).

### 3.5 Local-ground bookkeeping (C5 mechanics)

C5 needs, for every cell, the LOCAL ground = the apparent lightness of what
will actually be painted **under/at** that cell. The resolution pass runs over
a *flat* positioned cell list at the `maybe_dim` choke point
(`ui_renderer.ex:103-115`), where tree containment is already erased and
overlapping absolute layers make "enclosing" ambiguous — so containment cannot
be the source of LOCAL ground.

**Decision — a paint-order bg accumulator (a sparse `%{{x,y} => resolved_bg}`
grid), read-before-write, mirroring the buffer merge.** The resolver folds the
concatenated cell list **in paint order** and maintains the grid:

```
for each cell {x,y,char,fg,bg,attrs} in paint order:
  under      := Map.get(grid, {x,y})                 # under-layer bg, or nil
  enclosing  := under || terminal_ground             # ground for THIS cell's bg intent
  bg'        := resolve_bg(bg, enclosing)            # §3.1; nil intent stays nil
  local_grd  := (bg' != nil) && AL(bg') || AL(under) || AL(terminal_ground)
  fg'        := resolve_fg(fg, effective_p, local_grd)   # §3.3 step 3
  fg'        := clamp_output(fg', (bg' || under || ground), floor_class)  # §3.4/F2
  if bg' != nil: grid := Map.put(grid, {x,y}, bg')   # opaque paints seed ground;
                                                     # nil (transparent) never writes
```

**Why this is correct, not a heuristic:** LOCAL ground is *by definition* the bg
the compositor lands at `{x,y}`, and the compositor is exactly this fold.
`CellManager.put_cell` (`cell_manager.ex:62-65`) and `Backends.inherit_background`
(`backends.ex:450-455`) already resolve overlaps by folding cells in paint order
and inheriting the earlier bg for a `nil`-bg cell. The grid is that same
accumulator computed one stage earlier, so fg resolution can read the ground the
buffer *will* show. It reproduces truth by construction rather than approximating
containment.

**Why the fold order forbids the ordering hazard.** "Later in paint order" =
"higher z" = painted *over*, never *under* (`engine.ex:578`: flow first, overlays
last; top-level `Enum.flat_map` preserves list order, `ui_renderer.ex:45-55`). A
later opaque cell **replaces** the earlier cell at `{x,y}` (last-writer-wins), so
no already-resolved fg is left floating on a newly-inserted bg; a later
transparent cell keeps its own fg and reads the grid's earlier bg — exactly the
ground the buffer will inherit. Nothing can paint bg *under* an already-emitted
cell, so a single forward pass is exact — no second pass, no re-sort.

**Relocation:** the resolver moves from per-element `maybe_dim`
(`ui_renderer.ex:108`, which only sees one element's cells) to a single pass over
the fully concatenated list in `render_to_cells` (`ui_renderer.ex:45-56`) — the
only place top-level overlay/flow overlaps are visible before the buffer merge.
`ComponentCache` (`component_cache.ex:59,99`) caches *pre-resolution* symbolic
cells and stays upstream of this pass; resolution is context-dependent
(effective_p, region map, LOCAL ground) and must not be cached per element.

**Cost.** One sparse map keyed by *painted* coordinate, storing one bg term each;
built in O(cells), the same order as today's fold. Bounded by screen area —
≤1920 entries at 80×24, ≤~30k at 300×100 (a few MB worst case, rebuilt per
frame). The per-frame uniq-color memo (`cell_dim.ex:67-85`) is unchanged: it keys
resolution on the `(intent, effective_p, local_ground)` triple (§3.3), and
distinct local grounds are few (few painted surfaces), so the grid feeds the memo
without inflating its key space.

**Transparency / clipping / damage:**
- *Transparent chains* (`bg: nil`, `element_renderer.ex:349-352`) read the grid
  and never write it, so a stack of transparent cells all fall through to the
  deepest painted bg — identical to `inherit_background`.
- *Clipped cells* are dropped by `clip_cells_to_bounds`
  (`cell_manager.ex:19-25`) **before** the concat, so a clipped-away surface
  never seeds the grid — correct, since it is never painted.
- *Damage / partial repaint:* the grid is a **full-frame** construct — the
  resolver runs over the whole positioned list every frame, and damage is
  computed *downstream* by the buffer diff (`DamageTracker`), so no partial
  repaint can lose it today. A future sub-rect repaint path
  (`r1-incremental-render.md`) MUST seed the grid at the repaint boundary from
  the retained buffer's bg, or transparent boundary cells would resolve against
  terminal ground instead of the retained under-layer (RP-N-06, §8; open
  sub-question §10).

**Rejected alternatives.**
- *Region-carried bg (option (b)):* `region_path` nodes carry their resolved bg,
  no grid. Rejected — an element's true under-layer is whatever painted there
  earlier in z, which for **overlapping disjoint subtrees** (a dialog chip over
  two panes) is a *sibling* of a different region, not an ancestor; containment
  cannot express z-overlap or nil-bg chains that cross region boundaries.
- *Hybrid (region bg as seed, grid for overlaps):* the grid already handles the
  in-subtree case for free (a parent paints before its child, so the parent bg
  is in the grid at the child's coords), so the region seed adds machinery with
  no coverage gain. Rejected as redundant.

Respects the ratifications: this is engine-core bookkeeping at the one choke
point (not per-component); literal bg colors are resolved to their AL and seed
the grid identically to intents (literals participate); the AA 4.5 `:text` floor
(§3.4) is measured against this LOCAL bg, so a light chip on a dark terminal
clamps against the chip.

## 4. Composition laws (formulas)

Notation: `g` = apparent lightness of the local ground; `a` = AL of the
color at full strength; `p ∈ [0,1]`.

**C1 — prominence composes multiplicatively:**

```
effective_p = own_p × Π region_p(r for r in region_path) × Π overlay_p
```

Clamped to `[0,1]` (negatives are gamut-undefined, `prominence.ex:261-267`).
Multiplication is the right monoid: it is commutative/associative (stamping
order can't matter), `1.0` is the identity (an unmarked region is free), and
it never *raises* prominence (a nested region cannot out-shine its dimmed
parent) — the only sanctioned raise is the needs-input floor, applied after
composition by name.

**C2 — the fade is interpolation of apparent lightness toward the local
ground, at the composed p, once:**

```
faded_AL = g + (a − g) · effective_p
faded_C  = C · effective_p^γ
fg_hex   = oklch_to_hex(solve_L(faded_AL, faded_C, h), faded_C, h)
```

C1 + C2 give the exactness property the design leans on: because C2 is linear
in `p`, `fade(fade(x, p₁), p₂) = fade(x, p₁·p₂)` for the AL channel — staged
fading and one-shot fading agree *in the model*, and one-shot avoids the
quantization drift (§3.3).

**The chroma exponent γ unifies the two shipped parameterizations.**
`Prominence.fade` and `DiffViewer` scale chroma by `p` (γ=1,
`prominence.ex:229-231`, `diff_viewer.ex:539`); `CellDim` keeps chroma 0.65
at contrast 0.45 (`cell_dim.ex:35-39`) — and `0.45^0.55 ≈ 0.645`, so
**γ ≈ 0.55 reproduces the modal dim from the single scalar** while γ=1
reproduces the harness fades. One profile must win (open question Q1); until
ratified, the resolver takes γ per call-class with these two values, and the
byte-exact goldens pin whichever survives.

**C3 — tier intents compose as target-then-fade:** a `tier:` intent first
resolves its full-strength target `a = tier_target(tier, g, :auto)`
(headroom-compressed, `salience.ex:123-135`), then C2 applies with
`own_p = 1.0` unless the component also set one. Region dimming therefore
moves tier content *along its own tier's fade line*, preserving tier
ordering within a region (a dimmed region's `:anchor` still outranks its
dimmed `:baseline` — ordering is scale-invariant under shared `p`).

**C4 — sub-prominence riding (the gutter pattern) becomes multiplicative:**
`diff_viewer.ex:559-562`'s `content_p − 0.2 (clamp 0.4)` is re-expressed as
`own_p = ride_factor × parent_own_p` so it composes under C1 instead of
additively fighting it. (Re-bake the DiffViewer goldens; SAL-P-02 guards the
delta.)

**C5 — bg intents resolve against the ENCLOSING ground, and their result is
the ground for their interior:** `bg_AL = tier_target(bg_tier, g_enclosing)`,
then every fg inside uses `g_local = AL(bg)`. Nested surfaces (panel in
modal in app) chain naturally; the F2 clamp always sees the innermost bg.

## 5. Focus-driven region prominence — state machine

Per region, states are labels over the policy output (the policy stays a
pure function; this machine documents the transitions surfaces observe):

```
                 focus enters path              modal opens above
   ┌──────────┐ ───────────────────► ┌────────┐ ────────────────► ┌──────────┐
   │  PEER    │                      │ LIT    │                   │ OVERLAID │
   │ p=0.8    │ ◄─────────────────── │ p=1.0  │ ◄──────────────── │ p×0.45   │
   └──────────┘  focus leaves path   └────────┘   modal closes    └──────────┘
        │  ▲                              ▲                            │
        │  │ needs_input content inside   │ needs_input floors         │
        │  │ (floors composed p at 0.6 —  └── composed p at 0.6 ───────┘
        │  │  guard is per-CONTENT, not per-region: SAL-N-04)
        ▼  │
   ┌──────────────┐
   │ SEALED       │  print-once substrate surfaces only (harness scrollback):
   │ p frozen at  │  prominence was composed AT SEAL TIME and is never
   │ seal-time    │  re-graded (RecencyPolicy's seal-time grading law) —
   └──────────────┘  region transitions apply only to REPAINTABLE regions
```

Transition rules:

- Events: `focus_moved(new_path)`, `overlay_mounted(path)`,
  `overlay_unmounted(path)`, `region_mounted/unmounted`. Each recomputes the
  map; the map diff marks exactly the changed regions as damage (DamageTracker
  granularity — a focus move repaints the two affected regions, not the
  screen).
- LIT covers the focused region's full ancestor/descendant path (§3.2).
- OVERLAID composes: two stacked modals ⇒ `0.45²`. Composition floor: the
  policy clamps the *regional* product at the ladder floor `0.4`
  (`recency_policy.ex` `@floor`) — below that reads as "broken terminal"
  (`diff_viewer.ex:516`); the per-content needs-input floor still applies on
  top.
- Transitions are **instant** in v1. Animated prominence (fade-over-150ms) is
  representable later as an animation hint on the region (hints are
  declarative metadata, CLAUDE.md render rules) — explicitly out of scope
  here to keep the resolver pure per-frame.

## 6. Error / edge cases

| Case | Behavior (by construction) |
|---|---|
| **Mid-gray ground (g≈0.5)** | `tier_target` headroom compression already scales deltas proportionally, ordering preserved (`salience.ex:123-135`). Composed fades inherit it via C3. The `:text` AA floor (4.5) sits right at the mid-gray ceiling (max ratio on a g≈0.5 ground ≈ 4.6:1 vs white/black), so it is reachable but with near-zero slack — and any `{:ratio, 7.0}` opt-in is **unreachable** there: clamp returns the true full-strength ceiling (documented best-effort, `prominence.ex:307-312`) and emits `[:raxol, :ui, :prominence, :floor_unreachable]` telemetry — never silent, never a raise. |
| **Zero headroom / degenerate grounds (0.0, 1.0, 0.5)** | Extend SAL-N-05: resolver never raises, never NaN, always in-gamut hex, tier order preserved under full compression. Pure black/white grounds are the easy case (max headroom one side). |
| **Nested modals** | Multiplicative stacking with the 0.4 regional floor (§5). Top modal's own region is LIT; the mid modal is OVERLAID once, the base app twice→floored. |
| **Non-numeric / missing ground** | Falls back to `reference_ground` exactly as `Prominence.normalize_ground/1` does (`prominence.ex:258-259`) — detection absence degrades to today's behavior, never crashes. |
| **Streaming regions** | A region whose content re-renders every frame (live tail, `ShadowStream`) recomposes per frame — fine, resolution is memoized per distinct color (§3.3). The **sealed** scrollback of print-once surfaces is out of reach by the seal-time grading law: region prominence composes into the grade at paint time and is frozen (SEALED state, §5). A region transition therefore never triggers a repaint of sealed lines — no contradiction with the substrate. |
| **Focus thrash** | Policy purity + map diffing: same `(tree, focus, overlays)` ⇒ same map (SAL-POL-05 analogue); oscillation costs two-region repaints per move, bounded. |
| **Intent in an attrs-path that predates the resolver** | Any intent that survives to the terminal writer unresolved is a bug; the writer must reject `%ColorIntent{}` loudly in dev (guard), map to `:default` in prod (fail visible-but-safe). |
| **`{:fixed, color}` under a modal** | Exempt from all fading — documented sharp edge: fixed colors will glare through dims. That is what "fixed" means; lint-level warning candidate. |
| **LiveView / MCP surfaces** | Resolver runs server-side at the same choke point, so browser cells get resolved hex identically; MCP `StructuredScreenshot` may additionally expose the *intent* (semantic, pre-resolution) — richer for agents than bytes. Deferred detail. |

## 7. ANSI-16 / 256 fallback interaction

Detection is out of scope (parallel task); the resolver **consumes**
`capability_tier` as an input. Step 5 (§3.3) routes:

- `:truecolor` — emit the solved hex.
- `:color256` — quantize via `find_closest_256_color/1` **after** resolution,
  with the pinned regression that the 1.0/0.6 pair must survive as distinct
  indices (`prominence.ex:99-105`). The full redistributed per-ground ladder
  (`tiers_for(:color256)`, SAL-N-01) remains deferred exactly as
  `Prominence` defers it — this design adds the *seam* (capability routing at
  the choke point) without deciding the ladder.
- `:color16` — intents with a `role:` pin to `Ansi16Salience` slots
  (hue-category-preserving, polarity-aware — `ansi16_salience.ex` moduledoc);
  role-less intents map tier→{normal, bright, `:dim`-attr} three ways;
  region de-prominence degrades to the `:dim` cell attribute (the only
  honest de-prominence a 16-color terminal has). Priority ranking is
  inherited: legibility > category > tier separation.

The floor classes (§3.4) apply to the **emitted** value's reference palette on
16-color, with `Ansi16Salience`'s named exemption set — the clamp cannot
manufacture contrast a 16-slot palette doesn't have.

## 8. Test matrix sketch (guarantee → falsifier, per 05-salience discipline)

| ID | Guarantee | Falsifier that would catch its absence |
|---|---|---|
| RP-P-01 | Neutrality: no intents, no regions, no focus ⇒ cell list byte-identical to pre-resolver commit (SAL-P-06 pattern) | golden diff on Table/Block render if the resolver touches a literal it shouldn't |
| RP-P-02 | One-shot ≡ staged: `resolve(intent, p₁·p₂)` == `fade(resolve(intent,p₁),p₂)` within EPS_QUANT (C1×C2 exactness) | property over (h,c,p₁,p₂,g); fails if anyone re-fades resolved bytes |
| RP-P-03 | Monotone: p₁>p₂ ⇒ apparent-contrast(p₁)≥contrast(p₂)−EPS, **both grounds** (SAL-P-04 lift) | light-ground run fails if any path still hardcodes reference ground (F1) |
| RP-P-04 | Direction: outputs land on the headroom side of the LOCAL ground; dark→lighter, light→darker (SAL-N-02 companion) | fixture with light chip on dark terminal — global-ground bug resolves fg the wrong side of the chip |
| RP-P-05 | Floor on output: every `floor: :text` cell has `wcag_ratio(fg, LOCAL bg) ≥ 4.5` (or ceiling+telemetry when unreachable), after arbitrary region/overlay composition (F2) | property-generate region stacks × grounds; input-scalar-floor regression drops low-contrast seeds under 4.5 |
| RP-P-06 | Attr-less default: `text("hi")` with no style resolves to baseline-tier neutral meeting RP-P-05 on grounds {0.2, 0.5, 0.95} | today's `:white` default fails instantly on ground 0.95 |
| RP-P-07 | Tier ordering survives region dim: within one region at any composed p, anchor>baseline>differentiate>recede by apparent contrast | scale-variance bug (per-tier γ drift) collapses ordering at low p |
| RP-P-08 | Needs-input floor over full composition: min composed-p over needs-input content ≥ 0.6 for ANY (focus, overlays, recency) state (SAL-N-04 lift) | generate modal+defocus+3-turns-behind; approval below 0.6 is red |
| RP-P-09 | Policy purity + neutrality: `region_prominence(t,f,o)` deterministic; `f=nil, o=[]` ⇒ all 1.0 | any clock/process read; any default ≠ 1.0 |
| RP-P-10 | Composition floor: regional product never < 0.4 (nested modals) | triple-modal fixture renders sub-0.4 "broken terminal" gray |
| RP-P-11 | Local-ground chip (C5, §3.5): a `floor: :text` fg on a cell whose own resolved bg is a light chip painted over a dark terminal meets `wcag_ratio(fg, chip) ≥ 4.5` — clamps against the chip, not the terminal ground | fixture: light chip on dark terminal; a global-ground resolver yields fg ≥4.5 vs dark ground but <4.5 vs the chip → unreadable on the chip |
| RP-P-12 | bg-nil fall-through (§3.5): a transparent (`bg: nil`) fg cell over an opaque under-layer resolves its LOCAL ground to the under-layer's resolved bg (grid read) — the SAME bg `Backends.inherit_background` lands there | fixture: light under-layer + dark terminal, transparent dark-fg cell over it; a resolver treating `nil` as terminal ground resolves fg the wrong side of the visible bg |
| RP-P-13 | Paint-order over containment (§3.5): where two overlays over shared flow overlap, a later-painted chip seeds the grid so a still-later transparent fg reads the chip, not the flow beneath — LOCAL ground follows z/list order, not `region_path` | region-carried-bg (rejected option b) reads the fg's region-ancestor (flow) bg where disjoint subtrees overlap → wrong local ground |
| RP-N-01 | Degenerate grounds {0.0, 0.5, 1.0}: no raise, no NaN, valid hex, order preserved (SAL-N-05 lift to full pass) | NaN from headroom-0 division; out-of-gamut hex |
| RP-N-02 | Modal parity: Phase-1 reimplementation of `CellDim` over the resolver reproduces shipped modal-demo cells byte-exact (given ratified γ) | golden on `modal_demo` cell tree |
| RP-N-03 | Unresolved-intent guard: an intent reaching the terminal writer raises in dev / maps `:default` in prod | inject an intent past the resolver |
| RP-N-04 | 16-color: role intents keep hue category; 1.0/0.6 survive 256-quantization distinct (existing pin, now via the resolver) | quantization collapse per hue |
| RP-N-05 | Sealed lines untouched: a focus/overlay transition produces zero damage in sealed scrollback rows | damage-tracker assertion on a transcript fixture |
| RP-N-06 | Partial-repaint local-ground consistency (§3.5): resolving a damaged sub-rect with the retained buffer's boundary bg seeded into the grid yields byte-identical cells to a full-frame resolve | incremental path that starts the sub-rect grid empty resolves transparent boundary cells against terminal ground → mismatch vs full-frame golden |
| RP-H-* | Human-eye matrix (05-salience §5) extended with a **region panel**: focused/peer/overlaid side by side, both grounds; checklist adds "is the focused region unmistakable without reading?" | eye pass gates re-bakes; ratifies γ, `@peer_level`, and floors |

## 9. Migration plan

Phased so RP-P-01 (neutrality) holds at every merge:

- **Phase 0 — the resolver, dormant.** `ColorIntent` struct +
  `Raxol.UI.ColorResolver` wired at `ui_renderer.ex:103-115`, no producer
  emits intents, no policy map. Byte-identical output (RP-P-01 golden).
  Includes the writer guard (RP-N-03).
- **Phase 1 — modal dim rides the resolver.** `dim_behind_dialog` →
  `stamp_region_prominence`; `maybe_dim`/`CellDim.dim_cells` reimplemented as
  an overlay region at `overlay_keep 0.45`; γ ratified against the modal
  golden (RP-N-02). `CellDim` public API kept as a thin delegate. First
  visible proof that modal = special case of the general mechanism.
- **Phase 2 — harness surfaces (the components already speaking prominence).**
  `Block` (`block.ex:885`), `ShadowStream` (`shadow_stream.ex:277`),
  `DiffViewer` fades become intents + `own_p`; `fade_toward_ground`'s
  hardcoded ground dies with the module-local fade (F1 closed at its last
  site); `gutter_prominence` re-expressed per C4. `RecencyPolicy` output
  becomes `own_p`, composing with region p at seal time. Goldens re-baked
  once under the gauntlet + eye pass.
- **Phase 3 — attr-less default flips.** `resolve_fg`'s `:white` default
  (`element_renderer.ex:347`) becomes the baseline-tier intent. The most
  visible change in the plan; gated on RP-P-06 + the eye matrix + a
  playground sweep (53 demos). Escape: components that *want* literal white
  say `fg: {:fixed, :white}`.
- **Phase 4 — focus policy live. LANDED-PENDING-REVIEW.** `Raxol.UI.RegionPolicy`
  (`lib/raxol/ui/region_policy.ex`) is the pure `region_prominence(region_tree,
  focus, overlays, opts) :: %{region_path => float}` function §3.2 specifies:
  focus weight is bidirectional (a focused path's whole ancestor/descendant
  lineage lights up to `1.0`; everyone else drops to `@peer_level` `0.8`, or
  the opt-in `depth_falloff: true` proportional variant, default off);
  overlay weight is one-directional (only an overlay's own subtree is exempt
  from its own dim — an overlay still dims its own ANCESTOR regions, which is
  what makes nested modals compose to "top LIT, mid overlaid once, base app
  overlaid twice", §5); the composed regional product floors at `0.4`
  (RP-P-10). `Raxol.UI.Layout.Engine` generalizes: any container may now
  carry `region: id`, threaded root-first into a `:region_path` field during
  the layout walk (a new `process_element/3` clause, matched before every
  type-specific clause, mirroring `stamp_in_dialog/1`'s own-subtree-isolation
  shape); `stamp_region_prominence/2` (formerly the Phase 1 hardcoded
  1.0/`@overlay_keep` binary split) now builds the full set of region paths
  present (dialog overlays get an implicit path, `@dialog_region_id`,
  prefixed the same way `dialog: true` already worked) and consults
  `RegionPolicy.region_prominence/4` instead — **the modal case's output is
  unchanged by construction** (RP-N-02 golden still byte-exact, verified):
  with no focus and one dialog overlay, the general policy composes to
  exactly the old hardcoded split (`focus: nil` ⇒ every region's focus
  weight is `1.0`; the dialog's own overlay weight is `1.0` on-path,
  `@overlay_keep` off-path — identical to Phase 1's two-branch code, just
  derived instead of hardcoded). `apply_layout/4` accepts an optional
  render-context map (`:focused_region`, a region path directly, or
  `:focused_element`, a widget id — see Q6 below) threaded through
  `lib/raxol/core/runtime/rendering/engine.ex` from the SAME Dispatcher
  render context `focused_element`/`reduced_motion` already ride
  (`:get_render_context`). Absent context (every existing caller) is the
  neutrality case: `region_prominence: 1.0` everywhere, byte-identical to
  Phases 0-3. Playground demo wiring (`focus_ring`/`panel_highlights`) and
  the `SalienceTheme` intent-table re-expression are NOT part of this
  landing — deferred, no shipped demo currently declares `region:` markers,
  so the mechanism is live but dormant pending a follow-up demo/theme pass.
- **Order rationale:** first migrants are the components already
  intent-shaped (harness), then the mechanism that already exists (modal),
  then defaults, then new behavior (focus) — each phase has a shipped
  behavior to pin against.

## 10. Open questions for the owner

1. **γ (chroma exponent):** unify at ≈0.55 (modal-dim look everywhere,
   harness goldens re-bake) or γ=1 (harness look, modal re-bake), or keep two
   named profiles? One number is cleaner; the eye matrix should decide.
2. ~~**AAA (7.0) as the attr-less text floor**~~ — **ANSWERED (see
   ratification log): AA 4.5 default, AAA as `{:ratio, 7.0}` opt-in.**
3. **`@peer_level 0.8` and the depth-falloff variant:** is one ladder step
   enough de-prominence for the sidebar/main case, or should the proportional
   variant be the default?
4. **Region identity:** structural paths (positions in the layer tree) are
   free but unstable under reordering; explicit ids are stable but manual.
   Proposed: explicit id wins when present, structural fallback otherwise —
   ratify?
5. ~~**Should literal (non-intent) colors participate in region fading by
   default**~~ — **ANSWERED (see ratification log): yes**, matching today's
   modal dim of literals; `{:fixed, color}` is the opt-out.
6. ~~**Focus source of truth**~~ — **ANSWERED, interim (Phase 4):** reuse
   `focused_element` (widget-level) and derive the focused *region* as that
   widget's OWN positioned element's `region_path` — "the widget's enclosing
   region is the focused region." `Raxol.UI.Layout.Engine.resolve_focus_path/2`
   implements the lookup (scan the positioned list for the element whose
   `:id` matches `:focused_element`, read its `element_region_path/1`);
   `:focused_region` (an explicit region path) is also accepted and takes
   precedence when present, for callers that want to name a region directly
   without an intermediate widget id. Marked interim, not final ratification:
   a first-class, separately-navigable region-focus concept (the "or" branch
   of this question) remains open if a future surface needs to focus a
   region with no single representative widget (e.g. an empty panel, or a
   region spanning several unrelated widgets).
7. **Prominence transitions animation** (fade over ~150ms via hints):
   worth a v2 slot, or does instant switching read better in terminals?
8. **MCP surface:** expose pre-resolution intents in `StructuredScreenshot`
   (semantic layer for agents) alongside resolved bytes?
9. **Incremental-render grid seam (§3.5, RP-N-06):** when the in-flight
   sub-rect repaint path (`r1-incremental-render.md`) lands, the bg grid must be
   seeded at the repaint boundary from the retained buffer. Is reading the prior
   buffer's bg back into OKLCH apparent-lightness per boundary cell cheap enough
   per frame, or should the resolved-bg grid be **persisted alongside the
   buffer** between frames (traded memory for the round-trip)?
10. **Resolver vs `ComponentCache` (§3.5):** relocating resolution to a
    whole-list pass keeps `component_cache.ex` caching *symbolic* cells upstream
    — confirm no producer path (`render_cached`/`render_elements_cached`) ever
    resolves-then-caches, which would freeze a LOCAL ground into a cache entry
    reused under a different overlay stack. Lint/guard candidate?

---
Explicitly NOT proposed: new tier values (the 1.0/0.8/0.6/0.4 ladder and the
five salience tiers are ratified — this design only routes them), palette
detection (parallel task), the 256-color redistributed ladder (seam added,
decision deferred with `Prominence`'s), and any re-grading of sealed history
(frozen by the seal-time law).
