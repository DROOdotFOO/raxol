defmodule Raxol.UI.ColorResolver do
  @moduledoc """
  The single whole-list resolution pass that turns `Raxol.UI.ColorIntent`
  structs (and the `{:fixed, color}` wrapper) surviving in a cell list's
  `fg`/`bg` slots into concrete literal colors -- hex strings, `{r, g, b}`
  tuples, ANSI atoms, or 256-palette integers -- exactly once, as close to
  the terminal writer as this codebase gets.

  See `docs/core/RENDERING.md`'s "Region prominence" section for the model
  this implements.

  `Raxol.UI.Layout.Engine`'s `stamp_region_prominence/2` stamps a
  per-element `region_prominence` float -- computed by
  `Raxol.UI.RegionPolicy.region_prominence/4` from the region paths present
  this frame, the focused path, and any mounted dimming overlays -- into a
  transient `{:region_prominence, p}` marker in each cell's `attrs` list
  (see `Raxol.UI.Renderer`'s per-element render step). This module reads
  that marker, composes it into `effective_p` (`own_p * region_p`), and
  fades **both fg and bg, literal or intent-resolved**, toward the frame's
  terminal ground -- mirroring `Raxol.UI.CellDim.dim_fg/2` / `dim_bg/2`
  exactly (including the `:black` fg-vs-bg sentinel asymmetry documented
  there) but parametrized by the composed `p` and a module chroma exponent
  `@region_gamma` instead of CellDim's fixed `(contrast_keep 0.45,
  chroma_keep 0.65)` pair. `@region_gamma` is the closed-form solve
  `ln(0.65) / ln(0.45)` (~0.5395), chosen to reproduce CellDim's
  `chroma_keep` to floating-point precision at the one `p`
  (`Raxol.UI.Layout.Engine`'s `@overlay_keep`, 0.45) the modal dim
  composes. See the `@region_gamma` module attribute comment for the full
  derivation and `test/raxol/ui/region_prominence_test.exs` for the golden
  (RP-N-02: 0 of 964 painted cells differ on the modal_demo fixture).

  The `{:region_prominence, p}` marker is a resolver-internal implementation
  detail, never a real cell attribute: `resolve_cells/2` always strips it
  before a cell leaves this pass (see `resolve_cell/3`), so no downstream
  consumer (buffer diff, terminal writer, MCP structured screenshot, ...)
  ever sees it. `p == 1.0` (the default, and every cell's value absent a
  mounted dialog or other de-prominent region) short-circuits every
  dimming clause to identity, so the pass is neutral (RP-P-01) whenever no
  region drops below full prominence.

  ## Local-ground bookkeeping

  Cell lists arrive **flattened** -- tree containment is already erased by
  the time `render_to_cells/2` concatenates every element's cells, and
  overlapping absolute layers make "enclosing element" ambiguous. So the
  ground a `bg` intent resolves against, and the ground a `fg` intent (or
  the legibility floor) resolves against, cannot come from containment --
  it comes from **paint order**: a sparse `%{{x, y} => resolved_bg}` grid,
  folded once over the cell list exactly as `Raxol.UI.CellManager.put_cell/2`
  and `Backends.inherit_background/2` already fold overlapping cells when
  merging into the buffer. A cell reads the grid (its own under-layer, or
  the terminal ground if nothing painted there yet) *before* resolving, and
  writes its own resolved `bg` into the grid *after* -- but only if that
  `bg` is non-`nil` (opaque). A `nil` (transparent) `bg` never writes, so a
  stack of transparent cells all fall through to the deepest painted `bg`,
  identical to how the buffer itself inherits background today.

  ## What actually resolves

    * `nil` -- the unpainted/transparent sentinel, passes through unchanged
      (and never writes the grid).
    * `{:fixed, color}` -- unwraps to `color`, exempt from everything (see
      `Raxol.UI.ColorIntent` moduledoc).
    * `%Raxol.UI.ColorIntent{}` in a `bg` slot -- resolved via
      `Raxol.UI.Theming.Salience.solve/4` against the **enclosing** ground
      (the grid's under-layer at this coordinate, else the terminal
      ground), then region-dimmed (below) -- the RESULT becomes the
      **local** ground for this cell's `fg` and for every later cell
      painted at the same coordinate. bg *intent* resolution itself has no
      prominence term -- it always resolves at the intent's own tier's
      full-strength target (`tier` defaults to `:baseline` when unset); the
      region term is layered on after, identically to a literal bg (below).
    * `%Raxol.UI.ColorIntent{}` in a `fg` slot -- resolved at
      `effective_p = clamp(intent.prominence || 1.0) * clamp(region_p)`
      (`own_p` composed with the per-cell region prominence) against the
      **local** ground (this
      cell's own region-dimmed `bg`, else the grid's under-layer, else
      terminal ground), then clamped to the intent's `:floor` class against
      the **local resolved bg's actual color** (not a synthesized gray of
      its lightness) via bisection along the same fade line.
      The floor clamp runs *after* the full `effective_p` composition, so a
      region dim can never push an already-floored color back under its
      floor.
    * Any other term (atom, hex string, `{r, g, b}`, integer, ...) -- a
      literal. Passes through completely unchanged (RP-P-01, the
      byte-identity contract) when this cell's region prominence is `1.0`;
      region-dimmed otherwise, exactly like `Raxol.UI.CellDim` dims
      literals for the modal case -- literals participate in region
      dimming, not just intents.

  ## Region prominence

  Each cell's `attrs` list may carry a transient `{:region_prominence, p}`
  marker (`p :: float() in 0.0..1.0`), stamped per-element by
  `Raxol.UI.Renderer` from `Raxol.UI.Layout.Engine`'s
  `stamp_region_prominence/2` output before cells reach this module.
  `region_prominence_of/1` reads it (default `1.0` when absent); the marker
  is *always* stripped from the emitted cell's `attrs` before it leaves
  `resolve_cell/3` -- it is never a real terminal/buffer attribute like
  `:bold` or `:dim`, only a resolver-internal composition input.

  At `p == 1.0` every dimming clause below is the identity (an explicit
  guard, not just an arithmetic no-op) -- byte-identical output, matching
  the neutrality contract that holds whenever no region drops below full
  prominence. At `p < 1.0`:

    * **fg** -- an intent's `effective_p` folds in `p` before the existing
      fade+clamp pipeline runs (so the floor clamp sees the fully composed
      prominence -- no upstream stage can push an already-floored class
      back under the floor). A literal fg fades via `region_dim_fg/3`
      -- the fg-flavored half of the CellDim mirror: a painted `fg: :black`
      is dimmed as a real color (`CellDim.dim_fg/2`'s documented asymmetry).
    * **bg** -- both an intent-resolved bg and a literal bg pass through
      `region_dim_bg/3` -- `nil` (the unpainted sentinel) and the literal
      atom `:black` (the unpainted-bg sentinel, see `CellDim` moduledoc)
      both pass through completely untouched, matching `CellDim.dim_bg/2`
      exactly.
    * Both dimming paths fade **apparent lightness toward the terminal
      ground** (`ground + (apparent - ground) * p`) and **chroma by
      `p ** @region_gamma`** -- the same two-channel OKLCH interpolation
      `CellDim.dim_oklch/4` performs, parametrized instead of hardcoded.
      `@region_gamma` is chosen so the shipped modal look survives through
      the unified formula exactly (see moduledoc intro and the
      `@region_gamma` attribute comment).

  ## Reuse, not reimplementation

  The fade/clamp math is not duplicated here. `Raxol.UI.Theming.Salience`'s
  `solve/4`, `hex_to_oklch/1`, and `apparent_lightness/3` do all OKLCH/H-K
  work; `Raxol.UI.Harness.Prominence`'s `fade/3` and `wcag_ratio/2` do the
  ground-aware fade and the external WCAG contrast check. The only new code
  here is the bisection *driver* -- adapted from `Prominence.clamp_to_floor/7`
  but walking the fade line against the LOCAL bg's real hex rather than a
  gray reconstruction of the ground's lightness.

  ## The writer guard (RP-N-03)

  `resolve_cells/2` always emits literal `fg`/`bg` for every cell -- every
  clause below terminates in a literal. `enforce_resolved!/1` is the
  defense-in-depth postcondition check run as the pass's last step: if any
  cell still carries a `%ColorIntent{}` or `{:fixed, _}` (a producer bug, or
  a code path that skipped `render_to_cells/2` entirely), it raises in
  dev/test and maps the offending slot to `:default` plus a
  `[:raxol, :ui, :color_resolver, :unresolved_intent]` telemetry event in
  prod -- fail visible-but-safe, never a crashed render in production.
  """

  alias Raxol.UI.ColorIntent
  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.Theming.{Ansi16Salience, Colors, Salience, SalienceTheme}

  # Cross-package read of the terminal's classified color depth. The
  # DECISION of which color depth to render at lives here; byte emission
  # stays in raxol_terminal's renderer. `raxol_agent` is a downstream
  # package; `raxol_terminal` is a same-repo dependency of main raxol, not
  # a guaranteed-loaded sibling in every build (headless test runs,
  # LiveView, doc generation) -- guarded per CLAUDE.md's cross-package
  # discipline.
  @compile {:no_warn_undefined, Raxol.Terminal.Capabilities}

  @text_floor_ratio 4.5
  @clamp_iterations 24

  # The chroma exponent region-prominence dimming uses. `0.45 ** 0.55 ~=
  # 0.645` is close to `Raxol.UI.CellDim`'s fixed `chroma_keep` 0.65 at
  # `p = @overlay_keep` (the `Raxol.UI.Layout.Engine` modal-dim constant,
  # 0.45) -- but 0.55 alone is not tight: a synthetic sweep across the RGB
  # cube at p = 0.45 shows per-RGB-channel deviations up to 6 against
  # CellDim's exact output. This constant is instead the CLOSED-FORM solve
  # for that one anchor point -- `ln(0.65) / ln(0.45)` reproduces
  # `chroma_keep` to floating-point precision at `p = 0.45` (0 deviation
  # across the same sweep, and 0/964 painted cells differ on the
  # modal_demo golden, RP-N-02 -- see
  # `test/raxol/ui/region_prominence_test.exs`). There is no CellDim
  # ground truth for any OTHER p (nested modals, future depth-falloff), so
  # anchoring the exponent to the one p this module actually composes is
  # the most defensible choice there too.
  @region_gamma :math.log(0.65) / :math.log(0.45)

  # ANSI-16 atom -> code, matching `Raxol.Core.Renderer.Color`'s
  # `@ansi_16_map` ordering (same duplication pattern `Raxol.UI.CellDim`
  # already uses for the same reason: a small, stable, private lookup beats
  # a cross-module dependency on a private attribute).
  @ansi16_codes %{
    black: 0,
    red: 1,
    green: 2,
    yellow: 3,
    blue: 4,
    magenta: 5,
    cyan: 6,
    white: 7,
    bright_black: 8,
    bright_red: 9,
    bright_green: 10,
    bright_yellow: 11,
    bright_blue: 12,
    bright_magenta: 13,
    bright_cyan: 14,
    bright_white: 15
  }

  # Unknown atoms (`:default`, theme-custom names, ...) take the mid-gray
  # fallback, mirroring `Raxol.UI.CellDim.atom_to_rgb/1`.
  @unknown_atom_rgb {128, 128, 128}

  # --- capability-tier downgrade ---

  # Slot -> atom, the exact inverse of `@ansi16_codes` above. The `:ansi16`
  # downgrade rung always emits one of these 16 atoms (never a raw
  # `0..15` integer) so `packages/raxol_terminal`'s renderer needs no new
  # encode logic: its existing `resolve_fg_ansi/2`/`resolve_bg_ansi/2`
  # atom clause already emits the narrow `30-37`/`90-97` SGR form for
  # every one of these names, which is exactly what a genuine 16-color
  # terminal needs (an integer would hit the renderer's `0..255` clause
  # instead and emit the wide `38;5;n` form -- not guaranteed understood
  # by a true ANSI16-only terminal). This is the one representational
  # choice that keeps "the renderer only encodes, never chooses" true
  # without adding any color-depth awareness to the renderer at all.
  @ansi16_atoms Map.new(@ansi16_codes, fn {atom, code} -> {code, atom} end)

  # The 4 achromatic ANSI16 slots (black/gray/silver/white), precomputed
  # to their OKLab lightness at compile time -- the only legal landing
  # zone for a role-less color the chroma gate below classifies as gray.
  @ansi16_neutral_slots [0, 7, 8, 15]

  @ansi16_neutral_oklab (for slot <- @ansi16_neutral_slots do
                           {r, g, b} = Colors.ansi_to_rgb(slot)

                           {l, _c, _h} =
                             Salience.rgb_to_oklch(r / 255, g / 255, b / 255)

                           {slot, l}
                         end)

  # Gray-misroute fix: pure OKLab ΔE nearest-basic-color quantization
  # (`Colors.find_closest_basic_color/1`) routes a real slice of the gray
  # ramp (sRGB v in 23..97, ~30% of 0..255) onto CHROMATIC slots -- navy
  # (slot 4, chroma ~0.188), maroon (slot 1, chroma ~0.155), teal (slot 6,
  # chroma ~0.093) -- because OKLab Euclidean distance has no notion that
  # grayness should beat hue proximity, and the achromatic slots leave a
  # wide OKLab-lightness gap (black L=0, gray L=0.60, silver L=0.81, white
  # L=1.0) those chromatic slots happen to sit inside. See the PIN test in
  # `test/raxol/ui/theming/colors_test.exs`.
  #
  # A true achromatic gray's own OKLab chroma computes to exactly `0.0`
  # (verified: `Salience.rgb_to_oklch/3` on the full sRGB `v in 0..255`
  # diagonal sweep, no float noise measured above `1.0e-9`) -- so ANY
  # threshold strictly between `0.0` and the smallest misrouting
  # neighbor's chroma (teal, `~0.093`) closes the gap with zero false
  # negatives on true grays. `0.03` is chosen with headroom on both
  # sides: comfortably above the float-noise floor (by ~7 orders of
  # magnitude) so it never misses a genuine gray, and comfortably below
  # (less than a third of) the nearest chromatic neighbor's chroma, so a
  # near-neutral but intentionally tinted color (chroma above the gate)
  # still routes to its true hue family via `find_closest_basic_color/1`
  # rather than being flattened to a neutral it doesn't belong to.
  @ansi16_gray_chroma_gate 0.03

  # Compile-time dev/test vs prod split -- the pattern already used by
  # `Raxol.Performance.DevHints`/`DevProfiler` (`@mix_env Mix.env()`) and
  # `Dispatcher.test_env?/0`. `enforce_resolved!/2`'s explicit-flag arity
  # keeps both branches unit-testable regardless of the compiled `MIX_ENV`.
  @dev_guard? Mix.env() in [:dev, :test]

  @type cell :: {integer(), integer(), term(), term(), term(), list()}

  @doc """
  The chroma exponent region-prominence dimming uses -- see the
  `@region_gamma` module attribute comment for the RP-N-02 rationale.
  Exposed so tests/callers can compute the exact expected region-dimmed
  chroma for a given `p` without duplicating the constant.
  """
  @spec region_gamma() :: float()
  def region_gamma, do: @region_gamma

  @doc """
  Resolves every `ColorIntent`/`{:fixed, _}` in `cells`' `fg`/`bg` slots to
  literal colors, folding a paint-order local-ground grid across the whole
  list. Literal-only input passes through unchanged.

  ## Options

    * `:ground` - ground (background) OKLCH lightness. Default:
      `Raxol.UI.Theming.SalienceTheme.detect_ground/0` -- **never** a
      hardcoded constant; the ground is always live-detected, never
      assumed. A caller that needs a fixed ground for a test passes it
      explicitly here rather than this module defaulting to one.
    * `:color_depth` - the capability-tier downgrade rung
      (`:truecolor | :ansi256 | :ansi16 | :none`). Default: a guarded lazy
      read of
      `Raxol.Terminal.Capabilities.color_depth/0` that falls back to
      `:truecolor` (NOT that function's own `:ansi16` no-record default)
      whenever no capability record has been cached for this session --
      see `default_color_depth/0` for the full rationale. A caller that
      needs to force a rung (tests; an app that already knows its
      terminal) passes it explicitly here.
  """
  @spec resolve_cells([cell()], keyword()) :: [cell()]
  def resolve_cells(cells, opts \\ []) do
    ground = Keyword.get_lazy(opts, :ground, &SalienceTheme.detect_ground/0)
    color_depth = Keyword.get_lazy(opts, :color_depth, &default_color_depth/0)

    {resolved, _grid} =
      Enum.map_reduce(cells, %{}, fn cell, grid ->
        resolve_cell(cell, grid, ground, color_depth)
      end)

    enforce_resolved!(resolved)
  end

  # The `:color_depth` lazy default. Deliberately does NOT delegate
  # straight to `Raxol.Terminal.Capabilities.color_depth/0` -- that
  # function's own no-record answer is `:ansi16` (the struct's documented
  # Core-floor default), which would downgrade every render the instant
  # this module started calling it, breaking every existing golden/test
  # that never primes a capability record (the overwhelmingly common case
  # in `MIX_ENV=test`, headless sessions, and LiveView). This resolver
  # must stay byte-identical to plain literal-color rendering whenever
  # nothing has actually been detected -- so it checks presence first via
  # `cached/0` and only asks `color_depth/0` when a real record exists;
  # absence defaults to `:truecolor`, matching what this module
  # unconditionally assumes absent a detected terminal. Only an ACTUALLY
  # cached record (a real detected terminal) can downgrade the tier.
  @spec default_color_depth() :: atom()
  defp default_color_depth do
    with true <- Code.ensure_loaded?(Raxol.Terminal.Capabilities),
         {:ok, caps} <- Raxol.Terminal.Capabilities.cached() do
      Map.get(caps, :color_depth, :truecolor)
    else
      _ -> :truecolor
    end
  end

  @doc """
  The RP-N-03 writer guard: any cell whose `fg`/`bg` is still a
  `%ColorIntent{}` or `{:fixed, _}` after resolution raises (dev/test) or is
  mapped to `:default` with a telemetry event (prod). Called automatically
  as the last step of `resolve_cells/2`; exposed publicly so it can be
  exercised directly (e.g. injecting an unresolved intent to prove the
  guard fires -- RP-N-03's falsifier).
  """
  @spec enforce_resolved!([cell()]) :: [cell()]
  def enforce_resolved!(cells), do: enforce_resolved!(cells, @dev_guard?)

  @doc false
  @spec enforce_resolved!([cell()], boolean()) :: [cell()]
  def enforce_resolved!(cells, dev_mode?) do
    Enum.map(cells, fn {x, y, char, fg, bg, attrs} ->
      {x, y, char, guard_term(fg, dev_mode?), guard_term(bg, dev_mode?), attrs}
    end)
  end

  # --- the whole-list fold ---

  defp resolve_cell({x, y, char, fg, bg, attrs}, grid, ground, color_depth) do
    region_p = clamp01(region_prominence_of(attrs))
    clean_attrs = strip_region_marker(attrs)

    under = Map.get(grid, {x, y})

    # See `grid_bg_floor_fg/3` below for the full rationale. Must run
    # BEFORE the `match?(%ColorIntent{}, fg)` check below so a promoted
    # `nil` participates in intent resolution.
    fg = grid_bg_floor_fg(fg, bg, under)

    # `ref_al`/`ref_hex` decompose a literal color back into OKLCH -- real
    # work, and (per `literal_ref/1`'s moduledoc note) not fully total over
    # every literal shape this codebase's style maps produce (3-digit hex
    # shorthand, `"#RRGGBBAA"`, ...). Computed lazily, only when an actual
    # `ColorIntent` needs a ground reference to resolve against: no
    # producer currently emits a `bg` intent (only `fg`, via the attr-less
    # default below), so this specific call stays unreachable until
    # something starts painting an intent-typed background.
    enclosing_al =
      if match?(%ColorIntent{}, bg), do: ref_al(under) || ground, else: nil

    # `resolve_bg/5` layers the region dim and the capability-tier
    # downgrade on top of intent resolution (or straight onto a literal) --
    # the RESULT is what actually gets painted, so it is what the grid
    # records and what `fg`'s local ground reads (LOCAL ground is by
    # definition the bg the compositor lands). Downgrading BEFORE the
    # grid write is deliberate: a descendant's local-ground read should
    # reflect what will actually be painted on THIS terminal, not an
    # idealized truecolor value nothing downstream will ever show.
    bg_resolved = resolve_bg(bg, enclosing_al, ground, region_p, color_depth)

    {local_al, local_bg_hex} =
      if match?(%ColorIntent{}, fg) do
        {
          ref_al(bg_resolved) || ref_al(under) || ground,
          ref_hex(bg_resolved) || ref_hex(under)
        }
      else
        {nil, nil}
      end

    fg_resolved =
      resolve_fg(fg, local_al, local_bg_hex, ground, region_p, color_depth)

    grid =
      if is_nil(bg_resolved),
        do: grid,
        else: Map.put(grid, {x, y}, bg_resolved)

    {{x, y, char, fg_resolved, bg_resolved, clean_attrs}, grid}
  end

  # The only two producers of a real intent are this function and
  # `Raxol.UI.StyleProcessor`'s `default_fg_intent/2` -- both emit the SAME
  # baseline-tier, `:text`-floored intent for an otherwise-unpainted
  # foreground, at two different visibility levels. `default_fg_intent/2`
  # covers an element's OWN resolved `bg` attr; it cannot see the flattened
  # paint-order grid, so an element whose own bg is unpainted but that sits
  # visually OVER an ancestor's/sibling's already-painted bg (the grid's
  # `under` entry at this coordinate) falls through to this function
  # instead.
  #
  # This function promotes exactly that nil/nil cell's fg to the SAME
  # baseline-tier, `:text`-floored intent `default_fg_intent/2` already
  # emits for an explicitly painted own bg. Resolution then falls through
  # the EXISTING local-ground fallback chain in `resolve_cell/4`
  # unmodified -- `bg_resolved` is still nil here (this cell paints
  # nothing), so `ref_hex(bg_resolved) || ref_hex(under)` already lands on
  # `under`, and `ref_al` the same way.
  #
  # The nil-fg-over-nil-bg-over-NOTHING-painted case (`under` also `nil`)
  # is left untouched -- terminal-default fg passthrough must keep holding
  # even when no ground was ever detected/cached.
  defp grid_bg_floor_fg(nil, nil, under) when not is_nil(under) do
    %ColorIntent{h: nil, c: 0.0, tier: :baseline, floor: :text}
  end

  defp grid_bg_floor_fg(fg, _bg, _under), do: fg

  # The `{:region_prominence, p}` marker `Raxol.UI.Renderer` stamps into a
  # cell's `attrs` (see moduledoc) -- resolver-internal, never a
  # real cell attribute. Defaults to `1.0` (full prominence, the identity)
  # when absent, matching every element's default before any dialog mounts.
  defp region_prominence_of(attrs) do
    Enum.find_value(attrs, 1.0, fn
      {:region_prominence, p} when is_number(p) -> p
      _ -> nil
    end)
  end

  defp strip_region_marker(attrs) do
    Enum.reject(attrs, &match?({:region_prominence, _}, &1))
  end

  # --- bg resolution, region-dimmed, then capability-tier downgraded ---

  defp resolve_bg(nil, _enclosing_al, _ground, _region_p, _color_depth),
    do: nil

  defp resolve_bg(
         {:fixed, color},
         _enclosing_al,
         ground,
         _region_p,
         color_depth
       ),
       do: downgrade_color(color, nil, 1.0, color_depth, ground)

  defp resolve_bg(
         %ColorIntent{} = intent,
         enclosing_al,
         ground,
         region_p,
         color_depth
       ) do
    tier = intent.tier || :baseline
    c = intent.c || 0.0
    h = intent.h || 0

    resolved =
      tier
      |> Salience.solve(c, h, ground: enclosing_al, polarity: :auto)
      |> region_dim_bg(region_p, ground)

    # bg intents carry no `role` -- the role-pin path is for fg only (a
    # semantic role names what TEXT means, not what a surface wash is), so
    # a bg always takes the role-less-quantize path: a surface wash (e.g.
    # "a modal surface one step off the ground") has nothing to pin
    # against.
    downgrade_color(resolved, nil, 1.0, color_depth, ground)
  end

  defp resolve_bg(literal, _enclosing_al, ground, region_p, color_depth) do
    literal
    |> region_dim_bg(region_p, ground)
    |> downgrade_color(nil, 1.0, color_depth, ground)
  end

  # --- fg resolution, region-composed, then capability-tier downgraded ---

  defp resolve_fg(
         nil,
         _local_al,
         _local_bg_hex,
         _ground,
         _region_p,
         _color_depth
       ),
       do: nil

  defp resolve_fg(
         {:fixed, color},
         _local_al,
         _local_bg_hex,
         ground,
         _region_p,
         color_depth
       ),
       do: downgrade_color(color, nil, 1.0, color_depth, ground)

  defp resolve_fg(
         %ColorIntent{} = intent,
         local_al,
         local_bg_hex,
         ground,
         region_p,
         color_depth
       ) do
    tier = intent.tier || :baseline
    c = intent.c || 0.0
    h = intent.h || 0

    # effective_p composes the component's own prominence with the
    # per-cell region prominence, threaded from the cell's `attrs` marker
    # (see `region_prominence_of/1`). Reused below as the ANSI16 role-pin's
    # "prominence bucket" (`Ansi16Salience.slot/3`'s loud/soft threshold)
    # -- the same composed value that decided how far this color faded
    # decides which tier of the role's slot pair it pins to, so the two
    # degradations (fade vs. tier-fold) never disagree about how prominent
    # this cell currently is.
    own_p = clamp01(intent.prominence || 1.0)
    effective_p = clamp01(own_p * region_p)

    # The full-strength (t = 1.0) target -- solved once against the LOCAL
    # ground (this cell's own resolved bg apparent lightness, or the frame
    # ground when nothing local painted).
    target_hex = Salience.solve(tier, c, h, ground: local_al, polarity: :auto)

    faded_hex =
      if effective_p >= 1.0,
        do: target_hex,
        else: Prominence.fade(target_hex, effective_p, local_al)

    against_hex = local_bg_hex || ground_hex(ground)

    # The floor clamp runs against the FULLY composed effective_p -- a
    # region dim can never push an already-floored color back under its
    # floor, because the floor check happens after this composition, not
    # before it.
    resolved =
      clamp_output(
        faded_hex,
        target_hex,
        local_al,
        against_hex,
        effective_p,
        intent.floor
      )

    downgrade_color(resolved, intent.role, effective_p, color_depth, ground)
  end

  defp resolve_fg(
         literal,
         _local_al,
         _local_bg_hex,
         ground,
         region_p,
         color_depth
       ) do
    literal
    |> region_dim_fg(region_p, ground)
    |> downgrade_color(nil, 1.0, color_depth, ground)
  end

  # --- capability-tier downgrade ---
  #
  # The DECISION of which slot/index/hex a color downgrades to lives here,
  # at the resolver choke point -- byte EMISSION stays in raxol_terminal's
  # renderer. Runs as the LAST step of fg/bg resolution, after every
  # region-prominence fade and legibility-floor clamp has already produced
  # the color that would paint on a truecolor terminal -- downgrading
  # operates on that ground truth, an honest contract (the tiers below
  # only choose how to EXPRESS the resolved color on a smaller palette,
  # never a different color).

  defp downgrade_color(nil, _role, _effective_p, _color_depth, _ground),
    do: nil

  defp downgrade_color(color, _role, _effective_p, :truecolor, _ground),
    do: color

  defp downgrade_color(_color, _role, _effective_p, :none, _ground),
    do: nil

  defp downgrade_color(color, _role, _effective_p, :ansi256, _ground),
    do: downgrade_ansi256(color)

  defp downgrade_color(color, role, effective_p, :ansi16, ground),
    do: downgrade_ansi16(color, role, effective_p, ground)

  # :ansi256 rung -- only a truecolor hex/{r,g,b} SOURCE shape is
  # requantized (truecolor hex -> nearest-256 via OKLab; not every literal
  # shape reaching this stage needs requantizing). An ANSI atom or an
  # already-256-indexed integer is already
  # a valid, renderable literal on a 256-color terminal --
  # `packages/raxol_terminal/renderer.ex`'s atom/integer encode clauses
  # handle either unchanged -- so requantizing it would spend a lossy
  # RGB round-trip for no benefit.
  defp downgrade_ansi256(color) do
    case rgb_of(color) do
      nil -> color
      {r, g, b} -> Colors.find_closest_256_color({r, g, b})
    end
  end

  # :ansi16 rung -- same "only requantize a truecolor shape" rule as
  # `downgrade_ansi256/1` above, one rung down.
  defp downgrade_ansi16(color, role, effective_p, ground) do
    case rgb_of(color) do
      nil -> color
      rgb -> ansi16_slot(rgb, role, effective_p, ground)
    end
  end

  # A `role` present means this color came from a `%ColorIntent{}` a
  # producer explicitly tagged as semantic (`:error`, `:accent`, ...) --
  # the honest 16-color path: nearest-RGB against a genuinely unknown user
  # palette is a category lie (the
  # user's slot 1 could be any hue), so semantic colors are PINNED by
  # category + polarity + prominence-bucket instead of measured by
  # distance. `Ansi16Salience.slot/3` intentionally has no clause for a
  # role outside its closed `roles/0` set -- raises rather than guessing,
  # matching that module's own documented fail-loud contract.
  defp ansi16_slot(_rgb, role, effective_p, ground) when not is_nil(role) do
    polarity = Ansi16Salience.polarity(ground)
    slot = Ansi16Salience.slot(role, polarity, effective_p)
    ansi16_atom(slot)
  end

  # Role-less: the chroma gate (see `@ansi16_gray_chroma_gate`'s comment
  # for the full derivation) -- a near-achromatic color NEVER lands on a
  # chromatic slot (the gray-misroute this whole rung exists to fix);
  # anything with real chroma quantizes normally via nearest-color OKLab
  # ΔE (`Colors.find_closest_basic_color/1`), which IS honest here because
  # the ANSI16 basic-color RGB values are fixed constants, not a per-user
  # unknown -- a known palette, distinct from a genuinely-unknown
  # user-themed slot.
  defp ansi16_slot({r, g, b}, nil, _effective_p, _ground) do
    {l, c, _h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)

    if c < @ansi16_gray_chroma_gate do
      ansi16_atom(nearest_neutral_slot(l))
    else
      ansi16_atom(Colors.find_closest_basic_color({r, g, b}))
    end
  end

  defp nearest_neutral_slot(target_l) do
    @ansi16_neutral_oklab
    |> Enum.min_by(fn {_slot, l} -> abs(l - target_l) end)
    |> elem(0)
  end

  defp ansi16_atom(slot), do: Map.fetch!(@ansi16_atoms, slot)

  # A hex string or `{r, g, b}` tuple is the only "truecolor source" shape
  # this stage requantizes (mirrors `literal_ref_unsafe/1`'s scope --
  # 3-digit shorthand hex and `"#RRGGBBAA"` alpha hex are out of scope
  # there too). Everything else (an ANSI atom, an already-indexed
  # integer, or any other literal shape) returns `nil` so the caller
  # passes it through unchanged -- it is already a discrete-palette
  # literal with nothing to quantize.
  defp rgb_of("#" <> hex_digits = full) when byte_size(hex_digits) == 6,
    do: Colors.hex_to_rgb(full)

  defp rgb_of({r, g, b}) when is_integer(r) and is_integer(g) and is_integer(b),
    do: {r, g, b}

  defp rgb_of(_other), do: nil

  # --- output-contrast floor clamp, adapted from
  # `Prominence.clamp_to_floor/7` -- the same bisection-along-the-fade-line
  # shape, but checked against the LOCAL resolved bg's real hex, not a
  # gray reconstruction of the ground's lightness. ---

  defp clamp_output(faded_hex, _target_hex, _local_al, _against_hex, _p, :none),
    do: faded_hex

  defp clamp_output(
         faded_hex,
         target_hex,
         local_al,
         against_hex,
         effective_p,
         floor_class
       ) do
    ratio = floor_ratio_for(floor_class)

    cond do
      Prominence.wcag_ratio(faded_hex, against_hex) >= ratio ->
        faded_hex

      # target_hex is already the t = 1.0 ceiling (full-strength color) --
      # if even that misses the floor, this is a genuinely low-contrast
      # seed against this ground: best-effort ceiling + telemetry, never
      # silent, never a raise.
      Prominence.wcag_ratio(target_hex, against_hex) < ratio ->
        :telemetry.execute(
          [:raxol, :ui, :prominence, :floor_unreachable],
          %{ratio: ratio},
          %{local_al: local_al, effective_p: effective_p, floor: floor_class}
        )

        target_hex

      true ->
        bisect_floor(
          target_hex,
          local_al,
          against_hex,
          ratio,
          effective_p,
          1.0,
          @clamp_iterations
        )
    end
  end

  defp bisect_floor(target_hex, local_al, _against_hex, _ratio, _lo, hi, 0),
    do: Prominence.fade(target_hex, hi, local_al)

  defp bisect_floor(target_hex, local_al, against_hex, ratio, lo, hi, n) do
    mid = (lo + hi) / 2
    candidate = Prominence.fade(target_hex, mid, local_al)

    if Prominence.wcag_ratio(candidate, against_hex) >= ratio do
      bisect_floor(target_hex, local_al, against_hex, ratio, lo, mid, n - 1)
    else
      bisect_floor(target_hex, local_al, against_hex, ratio, mid, hi, n - 1)
    end
  end

  defp floor_ratio_for(:ui), do: Prominence.floor_ratio()
  defp floor_ratio_for(:text), do: @text_floor_ratio
  defp floor_ratio_for({:ratio, r}) when is_number(r), do: r

  # A pure-gray hex at exactly `ground`'s apparent lightness, built by
  # reusing `Prominence.fade/3` rather than calling `Salience.oklch_to_hex/3`
  # directly (out of scope for this module -- see moduledoc "Reuse, not
  # reimplementation"): fading ANY seed hex to `t = 0.0` toward `ground`
  # collapses both its apparent lightness AND its chroma to `(ground, 0)`,
  # so the seed's own hue is irrelevant and the result is exactly the
  # achromatic hex at `ground`.
  defp ground_hex(ground), do: Prominence.fade("#000000", 0.0, ground)

  # --- region-prominence dimming ---
  #
  # Mirrors `Raxol.UI.CellDim.dim_fg/2` / `dim_bg/2` exactly -- same
  # `:black` fg-vs-bg sentinel asymmetry, same OKLCH two-channel
  # interpolation -- but parametrized by the composed region prominence `p`
  # and `@region_gamma` instead of CellDim's fixed (0.45, 0.65) pair, and
  # faded toward the frame's terminal `ground` (the SAME ground CellDim's
  # `ground_apparent_lightness/0` reads, not the per-cell local-ground grid
  # intent resolution builds -- CellDim has no local-ground concept
  # either, so this is the correct parity target for RP-N-02).

  # `p >= 1.0` is the identity for every color shape, including shapes the
  # clauses below don't special-case -- checked first so no OKLCH round-trip
  # runs when a cell's region prominence is full (the common case absent an
  # active dialog, RP-P-01/neutrality).
  defp region_dim_fg(color, p, _ground) when p >= 1.0, do: color

  # A painted `fg: :black` is a real color under CellDim's documented
  # asymmetry -- dimmed, not passed through (see `CellDim.dim_fg/2`).
  defp region_dim_fg(:black, p, ground) do
    {r, g, b} = ansi16_rgb(:black)
    region_dim_rgb(r, g, b, p, ground)
  end

  defp region_dim_fg(color, p, ground), do: region_dim_literal(color, p, ground)

  # `nil` (unpainted bg) and `:black` (the unpainted-bg sentinel,
  # `CellDim`'s moduledoc) both pass through unconditionally -- there is
  # nothing to dim, and painting one would turn a transparent cell opaque.
  defp region_dim_bg(nil, _p, _ground), do: nil
  defp region_dim_bg(:black, _p, _ground), do: :black
  defp region_dim_bg(color, p, _ground) when p >= 1.0, do: color
  defp region_dim_bg(color, p, ground), do: region_dim_literal(color, p, ground)

  defp region_dim_literal(nil, _p, _ground), do: nil

  defp region_dim_literal({r, g, b}, p, ground)
       when is_integer(r) and is_integer(g) and is_integer(b) do
    region_dim_rgb(r, g, b, p, ground)
  end

  # 256-color palette indices have no general reverse mapping to a hue
  # without inventing one -- pass through unchanged, matching
  # `CellDim.dim_color/2`'s integer clause (via its `other` catch-all).
  defp region_dim_literal(code, _p, _ground) when is_integer(code), do: code

  defp region_dim_literal(color, p, ground) when is_atom(color) do
    {r, g, b} = ansi16_rgb(color)
    region_dim_rgb(r, g, b, p, ground)
  end

  # `Salience.hex_to_oklch/1` is total only over plain 6-digit hex (its
  # only clauses are a `%{r,g,b}` map and an exact 6-byte binary after the
  # leading `#` is stripped) -- it has no clause for the 3-digit shorthand
  # or `"#RRGGBBAA"` alpha shapes this codebase's style maps ship (see
  # `literal_ref/1`'s comment, the other caller that already rescues this),
  # and a syntactically-6-char but non-hex string (`"#gggggg"`) raises from
  # `String.to_integer/2` inside it. A cell's region prominence is decided
  # by which regions are mounted this frame, never by what shape of hex a
  # producer painted -- so a fg/bg literal reaching this dimming stage must
  # degrade the same way `literal_ref/1` already does for the identical
  # input space: an unparseable hex passes through UNDIMMED rather than
  # crashing the whole `resolve_cells/2` pass.
  defp region_dim_literal("#" <> _ = hex, p, ground) do
    case safe_hex_to_oklch(hex) do
      {:ok, {l, c, h}} ->
        {new_l, new_c, new_h} = region_dim_oklch(l, c, h, p, ground)
        Salience.oklch_to_hex(new_l, new_c, new_h)

      :error ->
        hex
    end
  end

  defp region_dim_literal(other, _p, _ground), do: other

  defp safe_hex_to_oklch(hex) do
    {:ok, Salience.hex_to_oklch(hex)}
  rescue
    _ -> :error
  end

  defp region_dim_rgb(r, g, b, p, ground) do
    {l, c, h} = Salience.rgb_to_oklch(r / 255, g / 255, b / 255)
    {new_l, new_c, new_h} = region_dim_oklch(l, c, h, p, ground)
    Salience.oklch_to_rgb(new_l, new_c, new_h)
  end

  # The region-dim formula: `faded_AL = g + (a - g) * p`, `faded_C = C * p
  # ** γ`. Solves back to a nominal `l` landing on the new apparent
  # lightness, exactly as `CellDim.dim_oklch/4` does.
  defp region_dim_oklch(l, c, h, p, ground) do
    apparent_l = Salience.apparent_lightness(l, c, h)
    new_apparent_l = ground + (apparent_l - ground) * p
    new_c = c * :math.pow(p, @region_gamma)
    new_l = Salience.solve_lightness(new_apparent_l, new_c, h)
    {new_l, new_c, h}
  end

  defp ansi16_rgb(atom) do
    case Map.fetch(@ansi16_codes, atom) do
      {:ok, code} -> Colors.ansi_to_rgb(code)
      :error -> @unknown_atom_rgb
    end
  end

  # --- literal color -> {hex, apparent_lightness} (grid reads) ---

  defp ref_al(nil), do: nil
  defp ref_al(term), do: literal_ref(term) |> elem_or_nil(1)

  defp ref_hex(nil), do: nil
  defp ref_hex(term), do: literal_ref(term) |> elem_or_nil(0)

  defp elem_or_nil(nil, _index), do: nil
  defp elem_or_nil(tuple, index), do: elem(tuple, index)

  # Never raises: an unparseable literal (this codebase's style maps ship
  # 3-digit shorthand hex, `"#RRGGBBAA"` alpha hex, and other shapes
  # `Salience.hex_to_oklch/1` has no clause for) degrades to `nil` -- the
  # same "detection absence degrades, never crashes" contract this module
  # applies to a non-numeric ground too. `resolve_cell/3` only calls this
  # at all when an actual `ColorIntent` needs a ground reference -- which
  # is reachable today whenever the attr-less default producer
  # (`grid_bg_floor_fg/3` / `StyleProcessor.default_fg_intent/2`) emits an
  # intent, so this is a live rescue, not dead code.
  defp literal_ref(term) do
    literal_ref_unsafe(term)
  rescue
    _ -> nil
  end

  defp literal_ref_unsafe("#" <> hex_digits = full)
       when byte_size(hex_digits) == 6 do
    {l, c, h} = Salience.hex_to_oklch(full)
    {full, Salience.apparent_lightness(l, c, h)}
  end

  defp literal_ref_unsafe({r, g, b})
       when is_integer(r) and is_integer(g) and is_integer(b) do
    rgb_ref(r, g, b)
  end

  defp literal_ref_unsafe(code) when is_integer(code) and code in 0..255 do
    {r, g, b} = Colors.ansi_to_rgb(code)
    rgb_ref(r, g, b)
  end

  defp literal_ref_unsafe(atom) when is_atom(atom) and not is_nil(atom) do
    {r, g, b} = ansi16_rgb(atom)
    rgb_ref(r, g, b)
  end

  defp literal_ref_unsafe(_other), do: nil

  defp rgb_ref(r, g, b) do
    hex = Colors.rgb_to_hex(r, g, b)
    {l, c, h} = Salience.hex_to_oklch(%{r: r, g: g, b: b})
    {hex, Salience.apparent_lightness(l, c, h)}
  end

  # --- misc ---

  defp clamp01(p) when p < 0.0, do: 0.0
  defp clamp01(p) when p > 1.0, do: 1.0
  defp clamp01(p), do: p

  defp guard_term(%ColorIntent{} = bad, dev_mode?),
    do: react_to_unresolved(bad, dev_mode?)

  defp guard_term({:fixed, _} = bad, dev_mode?),
    do: react_to_unresolved(bad, dev_mode?)

  defp guard_term(term, _dev_mode?), do: term

  defp react_to_unresolved(bad, true) do
    raise ArgumentError,
          "Raxol.UI.ColorResolver: unresolved color reached the terminal " <>
            "writer: #{inspect(bad)} (RP-N-03) -- every %ColorIntent{}/" <>
            "{:fixed, _} must be resolved before cells leave render_to_cells/2"
  end

  defp react_to_unresolved(bad, false) do
    :telemetry.execute(
      [:raxol, :ui, :color_resolver, :unresolved_intent],
      %{count: 1},
      %{value: bad}
    )

    :default
  end
end
