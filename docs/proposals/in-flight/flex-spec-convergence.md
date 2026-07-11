# Proposal: Flex Layout Spec Convergence & Unification (v2)

**Status:** in-flight — revised after eng-review + grok/longcat external review (2026-07-11)
**Owner:** V + Claude
**v1 -> v2:** original P0 "normalize row/column/view to :flex, zero behavior change" was FALSE and is withdrawn. Unification is now the LAST phase, behind a compat map. Fix the live `:flex` path first.

## Ground truth (verified by code inspection, longcat recon 2026-07-11)

There are THREE flex-like layout dialects, all alive:

1. `Raxol.UI.Layout.Flexbox` + Distributor/Positioner/Wrapper/Calculator — the real `:flex` path (`Engine.process_element` engine.ex:199). View DSL `row/column` macros produce `:flex`, so most app code lands here.
2. `Raxol.UI.Layout.Containers.process_row/process_column` (engine.ex:184,189) — literal `:row`/`:column` element types. Different defaults from `:flex` (no grow/shrink math, own gap/align conventions). Consumers include Viewport (`viewport.ex:191,210`).
3. `Raxol.Core.Renderer.View.Layout.Flex` (~566 LOC) via `Core.Renderer.Layout.apply_layout` (caller: core/renderer/view.ex:178) — second full stack with its own calculate_layout.

Dead code (verified zero consumers): `:flexbox` legacy API (`Flexbox.new/render/calculate_layout` + `Calculator.distribute_flex` + legacy content_width/height fns), `Components.Box.calculate_layout`.

Hidden defect found during recon: `LayoutUtils.apply_padding` (layout_utils.ex:31-37) returns a bare `%{x,y,width,height}` map — drops `:prepared_cache`, so all flex children measure UNCACHED. Perf bug, fix in Phase A.

`:view` is a passthrough (process_children in full space) — it is NOT flex and stays that way.

## Scope decisions (V to confirm; recommendations marked)

| ID | Decision | Status |
|----|----------|--------|
| D1 | Scope split: fix live `:flex` first, unify later | DECIDED: fix-first |
| D2 | `flex: 1` semantics | DECIDED (V, 2026-07-11): terminal-pragmatic — `flex: 1` sugar sets `min_main: 0`, always equalizes; documented as intentional CSS divergence |
| D3 | `:view` stays passthrough | DECIDED: yes |
| D4 | `:row`/`:column` merge: explicit default-compat map, Phase D only | DECIDED: yes |
| D5 | Third stack (`Core.Renderer.View.Layout.Flex`, 566 LOC) | DECIDED (verified 2026-07-11): zero production callers — only `view_test.exs` + `test/support/raxol/visual.ex:96` (visual snapshot harness renders through the DEAD pipeline — snapshots certify a path production never runs). Re-point `visual.ex` to `UI.Layout.Engine`, re-pin snapshots consciously, delete stack + its tests in Phase D |
| D6 | Overflow when sum(min) > container | DECIDED (V): clip at container main-end edge, never overlap siblings — AND add text-overflow affordances (Phase E) so clipping is graceful |
| D7 | Percentage syntax | `{:pct, n}` tuple only; no string parsing |
| D8 | Invalid style values | silent-clamp + `[:raxol, :layout, :invalid_style]` telemetry |
| D9 | Estimate | A+B ~3-4 days; +E ~2.5-3 days; full through D ~2.5+ weeks. Phases land independently |

## Phases (revised)

### Phase A — correct the live `:flex` path (no unification)
Blast radius: `flexbox.ex`, `flexbox/*`, `layout_utils.ex`. `:row`/`:column`/Containers untouched.

1. Characterization first: pin current geometry for flex trees INCLUDING wrap, nested flex, both gap conventions, plus real playground demo trees (not synthetic-only; v1's ~10 happy-path trees insufficient — grok). Existing `flexbox_test.exs` (418 lines, pins geometry) is part of the net; expect conscious re-pins.
2. `FlexItem` resolution step: base_size from true flex-basis; grow/shrink; min/max main+cross from style; margins `{t,r,b,l}` with `:auto`; style-lift function so `style: %{flex: 1}` / `flex: {g,s,b}` / min/max work on any element (today only `attrs.flex` is read).
3. §9.7 resolve-flexible-lengths, corrected per review:
   - initial free space from BASE sizes; grow-vs-shrink mode chosen on sum of OUTER hypothetical sizes (margins included — margins land in Phase A, not later; deferring them made v1's P2 non-spec)
   - pre-freeze: factor-0 items and items whose clamped hypothetical != base freeze before the loop
   - loop: distribute, clamp violators, freeze, redistribute; bound: <= n iterations
   - integer remainder: largest-remainder among UNFROZEN items only; a remainder grant may not violate min/max (re-clamp or pass to next candidate)
4. Auto margins (main axis absorb-before-justify; cross center/push; disable stretch).
5. Stretch guard: only when cross size auto AND no auto cross margins; clamp min/max cross; container cross must be definite, else no-op.
6. Positioner rounding: same largest-remainder treatment for space-around/evenly/center (v1 assigned this nowhere).
7. Fix `apply_padding` cache drop.
8. `align-content: :stretch` for wrap lines; wrap line-breaking uses outer hypothetical sizes.

### Phase B — min-content measurement (fixes L6)
- `measure_element(el, space, mode)` with `:min_content` mode. Full element matrix (text=longest word via TextMeasure, fixed box=width, divider=1 (currently = available width — the L6 root), column=max(child min), row=sum+gaps, table/grid/split_pane/scroll/responsive enumerated in impl doc). CSS Grid has min/max-content track helpers — reuse decision at impl time.
- Cache design (not "alongside"): key = `{element_hash, mode}`, per-render map threaded through layout, rebuilt each render; min- and max-content entries must not collide.
- Automatic minimum size default per D2 outcome.
- Overflow policy per D6.

### Phase C — percentages
- `{:pct, n}` for width/height/basis/min/max/margins. Definite-vs-indefinite containing block rule: pct against indefinite dimension resolves as `:auto` (spec). Nested pct goldens.

### Phase E — text layout (independent after B; V-requested 2026-07-11)
Spec-following where a spec exists; monospace grid makes all of these cheaper than browser equivalents (integer widths via TextMeasure, no font metrics).

1. `white-space`: `normal | nowrap | pre | pre-wrap | pre-line` — unify existing wrap code behind one property.
2. `text-overflow: ellipsis` — single-line clip with `…` (1 cell). Wide-char rule: never split a CJK/emoji pair; clip one column early.
3. `line-clamp` (CSS Overflow Module L4): `max-lines` + block-ellipsis `…` on the last rendered line; interacts with D6 clipping (clamp wins over raw clip when both apply).
4. `text-wrap: auto` — current greedy wrap, default.
5. `text-wrap: pretty` — Knuth-Plass-style DP: minimize sum of raggedness² + orphan (single-word last line) penalty. Break opportunities: UAX #14 subset — spaces, hyphens, after CJK ideographs. Integer costs; paragraph sizes in terminals keep the DP trivial.
- Tests: golden wraps per property incl. CJK/emoji boundaries; property test — `pretty` never produces more lines than `auto`; ellipsis output width never exceeds container.
- Estimate: 2.5-3 days total (1-1.5 of it is `pretty`).

### Phase F — overflow + scroll anchoring (V-requested 2026-07-11, needs design pass)
Driver: terminal-style UIs (playground Virtual FS example) need principled overflow.
- `overflow: :visible | :hidden | :clip | :scroll | :auto` as a container property — formalize the ad-hoc clip_bounds already present in `UIRenderer.render_box_children`; `:scroll`/`:auto` integrate with the existing `ScrollContent`/Viewport machinery rather than a new scroller.
- `overflow-anchor: :auto | :none` (CSS Scroll Anchoring, simplified): pick an anchor node in the visible region; on relayout, adjust scroll offset so the anchor keeps its viewport-relative position. Terminal-log idiom (bottom-follow: anchored to end until user scrolls up) as the first-class case.
- Scope/design after Phase A+B land; drive with the Virtual FS demo as the acceptance example.

### Phase D — unification + deletion
- Delete verified-dead: `:flexbox` API, legacy Calculator half, `Components.Box.calculate_layout`.
- `:row`/`:column` -> `:flex` with explicit compat map (D4): preserve current Containers defaults; Viewport + panels (measure via synthetic `:column`) + responsive (builds synthetic flex) named as consumers requiring their own characterization pins.
- Third stack per D5.
- `:view` untouched (D3).
- Docs: supported-property table + intentional-divergence list ships with Phase A, not last (grok: divergence table mid-stream).

## Output contract (eng-review G1)
`Engine.apply_layout/2` returns a flat list of absolutely-positioned element maps; every element carries `:type, :x, :y`; sized types (`:box`, component elements) additionally `:width, :height`; text carries `:text`. This contract is pinned by a characterization test in Phase A step 1 and consumed by UIRenderer + MCP TreeWalker.

## Test strategy (revised)
- Characterization: synthetic trees + real playground demo trees + wrap + nested + Viewport row/column path.
- Spec goldens (~15): equalization per D2, min-content floor, clamp-freeze-redistribute, auto-margin centering, pct definite/indefinite, stretch-vs-explicit.
- Properties (corrected per grok): sizes >= 0; exact-fill invariant guarded (sum(grow)>0, no max clamp binding, no auto margins, free >= 0, nowrap); frozen items within [min,max]; equal-`order` stability (v1's permutation property was tautological — replaced).
- Chrome differential oracle: DROPPED from plan (systematically biased: subpixel, box-sizing, font metrics). Replaced by hand-derived spec-example vectors.
- Perf: bench suites (`render_throughput` etc.) already exercise apply_layout; add flex-specific bench before Phase B (double measurement).

## Risks
- Existing `flexbox_test.exs` pins current (wrong) geometry — every re-pin is a conscious, reviewed change.
- Phase A alone changes production layouts that relied on leftover-only grow. Playground goldens catch the visible ones.
- Third-stack fate unknown until Phase D investigation — firewall: Phases A-C never touch `Core.Renderer.*`.
