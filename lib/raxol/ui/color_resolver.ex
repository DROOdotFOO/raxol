defmodule Raxol.UI.ColorResolver do
  @moduledoc """
  The single whole-list resolution pass that turns `Raxol.UI.ColorIntent`
  structs (and the `{:fixed, color}` wrapper) surviving in a cell list's
  `fg`/`bg` slots into concrete literal colors -- hex strings, `{r, g, b}`
  tuples, ANSI atoms, or 256-palette integers -- exactly once, as close to
  the terminal writer as this codebase gets.

  See `docs/proposals/in-flight/region-prominence-propagation.md` §3.3/§3.5
  for the full design. This module implements **Phase 0** only (§9): the
  resolver is wired into `Raxol.UI.Renderer.render_to_cells/2`, but no
  producer in this codebase emits a `ColorIntent` yet and there is no region
  prominence map. Every real render is therefore 100% literal colors, and
  `resolve_cells/2` is the identity transform on such input by construction
  -- literal terms flow through every clause here unchanged.

  ## Local-ground bookkeeping (§3.5)

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
      ground) -- the resolved bg becomes the **local** ground for this
      cell's `fg` and for every later cell painted at the same coordinate.
      Per the documented step-1 formula (§3.3), bg resolution has no
      prominence term -- it always resolves at the intent's own tier's
      full-strength target (`tier` defaults to `:baseline` when unset).
    * `%Raxol.UI.ColorIntent{}` in a `fg` slot -- resolved at
      `effective_p = intent.prominence || 1.0` (Phase 0 has no region/
      overlay map, so `effective_p` is `own_p` alone -- see §3.3 step 2 and
      §9's Phase 0 scope note) against the **local** ground (this cell's own
      resolved `bg`, else the grid's under-layer, else terminal ground),
      then clamped to the intent's `:floor` class against the **local
      resolved bg's actual color** (not a synthesized gray of its
      lightness -- F2, §3.4) via bisection along the same fade line.
    * Any other term (atom, hex string, `{r, g, b}`, integer, ...) -- a
      literal, passes through completely unchanged. This is the byte-
      identity contract Phase 0 is graded on (RP-P-01).

  ## Reuse, not reimplementation

  The fade/clamp math is not duplicated here. `Raxol.UI.Theming.Salience`'s
  `solve/4`, `hex_to_oklch/1`, and `apparent_lightness/3` do all OKLCH/H-K
  work; `Raxol.UI.Harness.Prominence`'s `fade/3` and `wcag_ratio/2` do the
  ground-aware fade and the external WCAG contrast check. The only new code
  here is the bisection *driver* -- adapted from `Prominence.clamp_to_floor/7`
  but walking the fade line against the LOCAL bg's real hex rather than a
  gray reconstruction of the ground's lightness, per F2 (§3.4).

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
  alias Raxol.UI.Theming.{Colors, Salience, SalienceTheme}

  @text_floor_ratio 4.5
  @clamp_iterations 24

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

  # Compile-time dev/test vs prod split -- the pattern already used by
  # `Raxol.Performance.DevHints`/`DevProfiler` (`@mix_env Mix.env()`) and
  # `Dispatcher.test_env?/0`. `enforce_resolved!/2`'s explicit-flag arity
  # keeps both branches unit-testable regardless of the compiled `MIX_ENV`.
  @dev_guard? Mix.env() in [:dev, :test]

  @type cell :: {integer(), integer(), term(), term(), term(), list()}

  @doc """
  Resolves every `ColorIntent`/`{:fixed, _}` in `cells`' `fg`/`bg` slots to
  literal colors, folding a paint-order local-ground grid across the whole
  list (§3.5). Literal-only input passes through unchanged.

  ## Options

    * `:ground` - ground (background) OKLCH lightness. Default:
      `Raxol.UI.Theming.SalienceTheme.detect_ground/0` -- **never** a
      hardcoded constant (this is the F1 discipline the design doc opens
      with; a caller that needs a fixed ground for a test passes it
      explicitly here rather than this module defaulting to one).
  """
  @spec resolve_cells([cell()], keyword()) :: [cell()]
  def resolve_cells(cells, opts \\ []) do
    ground = Keyword.get_lazy(opts, :ground, &SalienceTheme.detect_ground/0)

    {resolved, _grid} =
      Enum.map_reduce(cells, %{}, fn cell, grid ->
        resolve_cell(cell, grid, ground)
      end)

    enforce_resolved!(resolved)
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

  # --- the whole-list fold (§3.5) ---

  defp resolve_cell({x, y, char, fg, bg, attrs}, grid, ground) do
    under = Map.get(grid, {x, y})

    # `ref_al`/`ref_hex` decompose a literal color back into OKLCH -- real
    # work, and (per `literal_ref/1`'s moduledoc note) not fully total over
    # every literal shape this codebase's style maps produce (3-digit hex
    # shorthand, `"#RRGGBBAA"`, ...). Phase 0 has no intent producer, so
    # every real cell's fg/bg is a literal end to end -- computed lazily,
    # ONLY when an actual `ColorIntent` needs a ground/local-bg reference to
    # resolve against, this is unreachable on today's all-literal renders
    # (RP-P-01), not merely rescued.
    enclosing_al =
      if match?(%ColorIntent{}, bg), do: ref_al(under) || ground, else: nil

    bg_resolved = resolve_bg(bg, enclosing_al)

    {local_al, local_bg_hex} =
      if match?(%ColorIntent{}, fg) do
        {
          ref_al(bg_resolved) || ref_al(under) || ground,
          ref_hex(bg_resolved) || ref_hex(under)
        }
      else
        {nil, nil}
      end

    fg_resolved = resolve_fg(fg, local_al, local_bg_hex, ground)

    grid =
      if is_nil(bg_resolved),
        do: grid,
        else: Map.put(grid, {x, y}, bg_resolved)

    {{x, y, char, fg_resolved, bg_resolved, attrs}, grid}
  end

  # --- bg resolution (§3.3 step 1 / C5) ---

  defp resolve_bg(nil, _enclosing_al), do: nil
  defp resolve_bg({:fixed, color}, _enclosing_al), do: color

  defp resolve_bg(%ColorIntent{} = intent, enclosing_al) do
    tier = intent.tier || :baseline
    c = intent.c || 0.0
    h = intent.h || 0

    Salience.solve(tier, c, h, ground: enclosing_al, polarity: :auto)
  end

  defp resolve_bg(literal, _enclosing_al), do: literal

  # --- fg resolution (§3.3 steps 2-4 / C1-C3, F2) ---

  defp resolve_fg(nil, _local_al, _local_bg_hex, _ground), do: nil
  defp resolve_fg({:fixed, color}, _local_al, _local_bg_hex, _ground), do: color

  defp resolve_fg(%ColorIntent{} = intent, local_al, local_bg_hex, ground) do
    tier = intent.tier || :baseline
    c = intent.c || 0.0
    h = intent.h || 0

    # Phase 0: no region/overlay map exists yet, so effective_p is own_p
    # alone (§3.3's Π region_p / Π overlay_p terms are both 1.0 -- see the
    # design doc §9 Phase 0 scope note).
    effective_p = clamp01(intent.prominence || 1.0)

    # The full-strength (t = 1.0) target -- solved once against the LOCAL
    # ground, per §3.3 step 3's `AL(bg or ground)`.
    target_hex = Salience.solve(tier, c, h, ground: local_al, polarity: :auto)

    faded_hex =
      if effective_p >= 1.0,
        do: target_hex,
        else: Prominence.fade(target_hex, effective_p, local_al)

    against_hex = local_bg_hex || ground_hex(ground)

    clamp_output(
      faded_hex,
      target_hex,
      local_al,
      against_hex,
      effective_p,
      intent.floor
    )
  end

  defp resolve_fg(literal, _local_al, _local_bg_hex, _ground), do: literal

  # --- F2 output-contrast clamp (§3.4), adapted from
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
      # silent, never a raise (§6 "Mid-gray ground" row).
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
  # SAME "detection absence degrades, never crashes" contract §6 documents
  # for a non-numeric ground. `resolve_cell/3` only calls this at all when
  # an actual `ColorIntent` needs a ground reference, so on Phase 0's
  # all-literal renders this is unreachable code, not a rescued hot path.
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
    case Map.fetch(@ansi16_codes, atom) do
      {:ok, code} ->
        {r, g, b} = Colors.ansi_to_rgb(code)
        rgb_ref(r, g, b)

      :error ->
        {r, g, b} = @unknown_atom_rgb
        rgb_ref(r, g, b)
    end
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
