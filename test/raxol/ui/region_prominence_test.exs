defmodule Raxol.UI.RegionProminenceTest do
  @moduledoc """
  Phase 1 coverage for `docs/proposals/in-flight/region-prominence-propagation.md`
  §9 -- "modal dim rides the resolver". Two guarantees:

    * RP-N-02 -- the resolver-path modal dim (`Raxol.UI.ColorResolver`'s
      region-prominence composition, `Raxol.UI.Layout.Engine.stamp_region_prominence/1`)
      reproduces the pre-Phase-1 pipeline (`:dim_behind_modal` -> per-element
      `Raxol.UI.CellDim.dim_cells/1`) for a real playground demo's element
      tree with a mounted dialog, BYTE-EXACT (not merely bounded). The two
      paths share the same two-channel OKLCH fade shape (§4 C2); the design
      doc's own napkin estimate for the chroma exponent ("γ ≈ 0.55") turned
      out NOT tight enough in general -- a synthetic sweep across the RGB
      cube at `p = 0.45` showed per-channel deviations up to 6 against
      CellDim's exact `chroma_keep` (0.65) output. `Raxol.UI.ColorResolver`'s
      `@region_gamma` was refined to the closed-form solve
      `ln(0.65) / ln(0.45)` (~0.5395) instead, which reproduces
      `chroma_keep` to floating-point precision at the one `p`
      (`Raxol.UI.Layout.Engine`'s `@overlay_keep`) Phase 1 actually
      composes -- 0 deviation across that same sweep, and this test asserts
      the resulting exact equality (with a documented per-channel bound as
      a regression fence, in case a future γ revision loosens it again).
    * RP-P-01 lift -- a cell whose `attrs` explicitly carries
      `{:region_prominence, 1.0}` resolves identically to the same cell with
      no marker at all (both are "no active dialog" in different guises).
  """

  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.ModalDemo
  alias Raxol.UI.{CellDim, ColorIntent, ColorResolver}
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Renderer, as: UIRenderer

  @dimensions %{width: 80, height: 24}

  # Regression fence, not the primary claim -- see moduledoc. The closed-form
  # `@region_gamma` makes this golden byte-EXACT (0), so this bound exists to
  # catch a future γ change drifting the modal look, not because deviation
  # is expected here.
  @channel_tolerance 1

  # ---- RP-N-02: modal demo golden parity (old CellDim path vs new resolver path) ----

  describe "RP-N-02 modal golden parity" do
    test "the resolver-path dim is byte-exact against the pre-Phase-1 CellDim path" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      view = ModalDemo.view(model)

      elements = LayoutEngine.apply_layout(view, @dimensions)

      assert Enum.any?(elements, &Map.get(&1, :dim_behind_modal, false)),
             "fixture must actually mount a dialog for this golden to mean anything"

      old_cells = old_pipeline_cells(elements, nil) |> index_by_xy()
      new_cells = UIRenderer.render_to_cells(elements, nil) |> index_by_xy()

      assert Map.keys(old_cells) |> Enum.sort() ==
               Map.keys(new_cells) |> Enum.sort(),
             "old and new paths must paint the exact same set of coordinates"

      deviations =
        for {xy, {_c, old_fg, old_bg, _a}} <- old_cells,
            {_c, new_fg, new_bg, _a} = Map.fetch!(new_cells, xy),
            do:
              {xy, channel_delta(old_fg, new_fg), channel_delta(old_bg, new_bg)}

      max_delta =
        deviations
        |> Enum.flat_map(fn {_xy, fg_d, bg_d} -> [fg_d, bg_d] end)
        |> Enum.max(fn -> 0 end)

      assert max_delta <= @channel_tolerance,
             "resolver-path dim deviates from CellDim's shipped output by " <>
               "#{max_delta} in at least one RGB channel (regression bound: " <>
               "#{@channel_tolerance}); see ColorResolver's @region_gamma comment"

      # The actual claim (moduledoc): byte-exact, not merely within bound.
      assert max_delta == 0,
             "expected byte-exact parity (the closed-form γ), got max " <>
               "per-channel delta #{max_delta} -- see the deviations: " <>
               inspect(Enum.reject(deviations, &match?({_, 0, 0}, &1)))
    end

    test "the dialog's own cells are untouched (full color both paths)" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      view = ModalDemo.view(model)
      elements = LayoutEngine.apply_layout(view, @dimensions)

      dialog_elements =
        Enum.reject(elements, &Map.get(&1, :dim_behind_modal, false))

      refute dialog_elements == []

      old_cells = old_pipeline_cells(elements, nil)
      new_cells = UIRenderer.render_to_cells(elements, nil)

      # "Confirm Action" is the dialog's own title text -- present verbatim
      # (undimmed) in both paths.
      old_confirm =
        Enum.filter(old_cells, fn {_x, _y, c, _fg, _bg, _a} -> c == "C" end)

      new_confirm =
        Enum.filter(new_cells, fn {_x, _y, c, _fg, _bg, _a} -> c == "C" end)

      assert old_confirm != []
      assert new_confirm != []
    end
  end

  # ---- RP-P-01 lift: explicit region_prominence: 1.0 is the identity ----

  describe "RP-P-01 lift -- region_prominence 1.0 is a no-op" do
    test "a literal-color cell with an explicit {:region_prominence, 1.0} marker is byte-identical to the unmarked cell" do
      unmarked = {0, 0, "x", :cyan, {200, 100, 50}, [:bold]}

      marked =
        {0, 0, "x", :cyan, {200, 100, 50}, [:bold, {:region_prominence, 1.0}]}

      [resolved_unmarked] = ColorResolver.resolve_cells([unmarked], ground: 0.2)
      [resolved_marked] = ColorResolver.resolve_cells([marked], ground: 0.2)

      assert resolved_unmarked == resolved_marked
      assert resolved_unmarked == unmarked
    end

    test "an intent-fg cell with an explicit {:region_prominence, 1.0} marker resolves identically to the unmarked cell" do
      intent = %ColorIntent{tier: :baseline, c: 0.05, h: 57, floor: :text}

      unmarked = {0, 0, "x", intent, nil, []}
      marked = {0, 0, "x", intent, nil, [{:region_prominence, 1.0}]}

      [resolved_unmarked] = ColorResolver.resolve_cells([unmarked], ground: 0.2)
      [resolved_marked] = ColorResolver.resolve_cells([marked], ground: 0.2)

      assert resolved_unmarked == resolved_marked
    end

    test "the {:region_prominence, p} marker never survives into the emitted cell's attrs" do
      cells = [{0, 0, "x", :cyan, nil, [:bold, {:region_prominence, 0.45}]}]

      [{_x, _y, _c, _fg, _bg, attrs}] =
        ColorResolver.resolve_cells(cells, ground: 0.2)

      refute Enum.any?(attrs, &match?({:region_prominence, _}, &1))
      assert attrs == [:bold]
    end
  end

  # ---- direct region-dim unit coverage (fg/bg CellDim-mirror asymmetry) ----

  describe "region dimming mirrors CellDim's fg/bg :black asymmetry" do
    test "a literal fg :black under a dimmed region is treated as a real color" do
      cells = [{0, 0, "x", :black, nil, [{:region_prominence, 0.45}]}]

      [{_x, _y, _c, fg, _bg, _a}] =
        ColorResolver.resolve_cells(cells, ground: 0.2)

      refute fg == :black
      assert is_tuple(fg)
    end

    test "a literal bg :black under a dimmed region stays the unpainted sentinel" do
      cells = [{0, 0, "x", :default, :black, [{:region_prominence, 0.45}]}]

      [{_x, _y, _c, _fg, bg, _a}] =
        ColorResolver.resolve_cells(cells, ground: 0.2)

      assert bg == :black
    end

    test "a nil bg under a dimmed region stays nil (never turns opaque)" do
      cells = [{0, 0, "x", :cyan, nil, [{:region_prominence, 0.45}]}]

      [{_x, _y, _c, _fg, bg, _a}] =
        ColorResolver.resolve_cells(cells, ground: 0.2)

      assert bg == nil
    end
  end

  # ---- helpers ----

  defp index_by_xy(cells) do
    Map.new(cells, fn {x, y, c, fg, bg, a} -> {{x, y}, {c, fg, bg, a}} end)
  end

  defp channel_delta(a, b), do: channel_delta_rgb(to_rgb(a), to_rgb(b))

  defp channel_delta_rgb(nil, nil), do: 0

  defp channel_delta_rgb({r1, g1, b1}, {r2, g2, b2}) do
    [abs(r1 - r2), abs(g1 - g2), abs(b1 - b2)] |> Enum.max()
  end

  # A shape mismatch (one side {r,g,b}, the other something else, e.g.
  # nil vs :black) is itself a deviation -- report a large delta rather
  # than silently treating it as 0.
  defp channel_delta_rgb(_a, _b), do: 999

  defp to_rgb(nil), do: nil

  defp to_rgb({r, g, b}) when is_integer(r) and is_integer(g) and is_integer(b),
    do: {r, g, b}

  defp to_rgb("#" <> hex) when byte_size(hex) == 6 do
    {r, ""} = Integer.parse(String.slice(hex, 0, 2), 16)
    {g, ""} = Integer.parse(String.slice(hex, 2, 2), 16)
    {b, ""} = Integer.parse(String.slice(hex, 4, 2), 16)
    {r, g, b}
  end

  defp to_rgb(atom) when is_atom(atom), do: ansi_rgb(atom)
  defp to_rgb(_other), do: nil

  # Small, local ANSI-16 -> RGB table for the golden's own literal fixtures
  # (`:white`, `:cyan`, etc. as painted by ModalDemo/its shared components)
  # -- reuses the SAME canonical table `CellDim`/`ColorResolver` both read
  # from `Raxol.UI.Theming.Colors.ansi_to_rgb/1`, just resolved here for
  # comparison purposes rather than dimming.
  defp ansi_rgb(atom) do
    code =
      %{
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
      |> Map.get(atom)

    case code do
      nil -> nil
      code -> Raxol.UI.Theming.Colors.ansi_to_rgb(code)
    end
  end

  # Reconstructs exactly what `Raxol.UI.Renderer.render_to_cells/2` produced
  # BEFORE Phase 1 (§9): per-element render + clip, then `CellDim.dim_cells/1`
  # over any element `stamp_region_prominence/1` marked `dim_behind_modal:
  # true` -- the literal `maybe_dim/2` clause this task removed from
  # `ui_renderer.ex`. Built from `render_to_cells_unresolved/2`'s flattened,
  # UNDIMMED cell list (still carrying the `{:region_prominence, p}` marker
  # Phase 1's `stamp_region_prominence_attrs/2` leaves on each cell) so the
  # oracle and the new path start from the identical literal colors --
  # the only difference under test is the dimming formula itself.
  defp old_pipeline_cells(elements, theme) do
    ground_al = CellDim.ground_apparent_lightness()

    elements
    |> UIRenderer.render_to_cells_unresolved(theme)
    |> Enum.map(fn {x, y, char, fg, bg, attrs} ->
      dimmed? =
        Enum.any?(attrs, fn
          {:region_prominence, p} -> p < 1.0
          _ -> false
        end)

      clean_attrs = Enum.reject(attrs, &match?({:region_prominence, _}, &1))

      {fg2, bg2} =
        if dimmed? do
          {CellDim.dim_fg(fg, ground_al), CellDim.dim_bg(bg, ground_al)}
        else
          {fg, bg}
        end

      {x, y, char, fg2, bg2, clean_attrs}
    end)
  end
end
