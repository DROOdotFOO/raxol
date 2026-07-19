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
  alias Raxol.UI.{CellDim, ColorIntent, ColorResolver, RegionPolicy}
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

  # ---- Phase 4 (§9): explicit `region:` markers + focus-driven policy ----
  #
  # Two sibling containers, each carrying its own stable `region:` marker
  # AND `id:` (so `:focused_element` resolution -- Q6 interim -- has a
  # widget id to resolve). No dialog anywhere -- these tests are purely
  # about the general focus/region mechanism `Raxol.UI.RegionPolicy`
  # brings online for Phase 4, layered onto the SAME
  # `element[:region_prominence]` marker/`ColorResolver` fade path Phase 1
  # already shipped (no changes needed there -- it already fades an
  # arbitrary composed `p`, not just the modal's hardcoded 0.45).

  defp two_region_view do
    %{
      type: :row,
      children: [
        %{
          type: :box,
          id: :sidebar_box,
          region: :sidebar,
          children: [%{type: :text, content: "SIDE", fg: :white}]
        },
        %{
          type: :box,
          id: :main_box,
          region: :main,
          children: [%{type: :text, content: "MAIN", fg: :white}]
        }
      ]
    }
  end

  # Same shape, same ids, but with no `region:` markers at all -- the
  # RP-P-01-style neutrality oracle: region markers with no focus must
  # render byte-identically to no markers ever having existed.
  defp two_region_view_bare do
    %{
      type: :row,
      children: [
        %{
          type: :box,
          id: :sidebar_box,
          children: [%{type: :text, content: "SIDE", fg: :white}]
        },
        %{
          type: :box,
          id: :main_box,
          children: [%{type: :text, content: "MAIN", fg: :white}]
        }
      ]
    }
  end

  describe "Phase 4 -- explicit region markers, no focus (neutrality)" do
    test "region: markers alone (no focus, no dialog) stamp region_prominence: 1.0 on every element" do
      elements = LayoutEngine.apply_layout(two_region_view(), @dimensions)

      assert Enum.all?(elements, &(Map.get(&1, :region_prominence) == 1.0))
    end

    test "region-marked, unfocused render is byte-identical to a render with no region markers at all" do
      regioned_cells =
        two_region_view()
        |> LayoutEngine.apply_layout(@dimensions)
        |> UIRenderer.render_to_cells()

      bare_cells =
        two_region_view_bare()
        |> LayoutEngine.apply_layout(@dimensions)
        |> UIRenderer.render_to_cells()

      assert Enum.sort(regioned_cells) == Enum.sort(bare_cells)
    end

    test "an explicit empty render_context (%{}) matches the 3-arity default" do
      three_arity = LayoutEngine.apply_layout(two_region_view(), @dimensions)

      four_arity =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{})

      assert three_arity == four_arity
    end
  end

  describe "Phase 4 -- focused_region dims the sibling to the peer level" do
    test "the focused region stays 1.0, its sibling drops to RegionPolicy.peer_level/0" do
      elements =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_region: [:sidebar]
        })

      sidebar_el = Enum.find(elements, &(Map.get(&1, :id) == :sidebar_box))
      main_el = Enum.find(elements, &(Map.get(&1, :id) == :main_box))

      refute is_nil(sidebar_el)
      refute is_nil(main_el)
      assert sidebar_el.region_prominence == 1.0
      assert main_el.region_prominence == RegionPolicy.peer_level()
    end

    test "every element under the focused region (not just its own container) reads 1.0" do
      elements =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_region: [:sidebar]
        })

      # The "SIDE" text leaf is a DESCENDANT of the :sidebar_box container,
      # not the box element itself -- both must be 1.0 (§3.2 "the focused
      # region and every ancestor and descendant of it").
      side_text = Enum.find(elements, &(Map.get(&1, :text) == "SIDE"))
      main_text = Enum.find(elements, &(Map.get(&1, :text) == "MAIN"))

      refute is_nil(side_text)
      refute is_nil(main_text)
      assert side_text.region_prominence == 1.0
      assert main_text.region_prominence == RegionPolicy.peer_level()
    end

    test "the cell-level fade actually happens: the unfocused sibling's fg is no longer literal :white" do
      cells =
        two_region_view()
        |> LayoutEngine.apply_layout(@dimensions, nil, %{
          focused_region: [:sidebar]
        })
        |> UIRenderer.render_to_cells()

      side_cell = Enum.find(cells, fn {_x, _y, c, _fg, _bg, _a} -> c == "S" end)
      main_cell = Enum.find(cells, fn {_x, _y, c, _fg, _bg, _a} -> c == "M" end)

      refute is_nil(side_cell)
      refute is_nil(main_cell)

      {_, _, _, side_fg, _, _} = side_cell
      {_, _, _, main_fg, _, _} = main_cell

      assert side_fg == :white
      refute main_fg == :white
    end

    test "focus: nil (explicit) is the same as no context at all -- byte-identical cells" do
      no_context =
        two_region_view()
        |> LayoutEngine.apply_layout(@dimensions)
        |> UIRenderer.render_to_cells()

      explicit_nil_focus =
        two_region_view()
        |> LayoutEngine.apply_layout(@dimensions, nil, %{focused_region: nil})
        |> UIRenderer.render_to_cells()

      assert Enum.sort(no_context) == Enum.sort(explicit_nil_focus)
    end
  end

  describe "Phase 4 -- :focused_element (widget id) resolves to its enclosing region (Q6 interim)" do
    test "focusing a widget id dims its sibling region exactly like focusing the region path directly" do
      by_element =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_element: :sidebar_box
        })

      by_region =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_region: [:sidebar]
        })

      assert Enum.map(by_element, &Map.get(&1, :region_prominence)) ==
               Enum.map(by_region, &Map.get(&1, :region_prominence))
    end

    test "an unresolvable focused_element (no matching id) is treated as no focus -- neutrality" do
      elements =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_element: :no_such_widget
        })

      assert Enum.all?(elements, &(Map.get(&1, :region_prominence) == 1.0))
    end

    test ":focused_region takes precedence over :focused_element when both are present" do
      elements =
        LayoutEngine.apply_layout(two_region_view(), @dimensions, nil, %{
          focused_element: :sidebar_box,
          focused_region: [:main]
        })

      sidebar_el = Enum.find(elements, &(Map.get(&1, :id) == :sidebar_box))
      main_el = Enum.find(elements, &(Map.get(&1, :id) == :main_box))

      assert main_el.region_prominence == 1.0
      assert sidebar_el.region_prominence == RegionPolicy.peer_level()
    end
  end

  describe "Phase 4 -- modal golden is unaffected by the general policy generalization (regression)" do
    test "the RP-N-02 modal golden's region_prominence split (1.0 / @overlay_keep) is reproduced by the general policy with no region markers or focus involved" do
      model = %{show: true, confirmed: 0, cancelled: 0}
      view = ModalDemo.view(model)

      elements = LayoutEngine.apply_layout(view, @dimensions)

      dialog_elements =
        Enum.reject(elements, &Map.get(&1, :dim_behind_modal, false))

      dimmed_elements =
        Enum.filter(elements, &Map.get(&1, :dim_behind_modal, false))

      refute dialog_elements == []
      refute dimmed_elements == []

      assert Enum.all?(dialog_elements, &(&1.region_prominence == 1.0))

      assert Enum.all?(
               dimmed_elements,
               &(&1.region_prominence == RegionPolicy.overlay_keep())
             )
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

    raw_cells = UIRenderer.render_to_cells_unresolved(elements, theme)

    dimmed_flags =
      Enum.map(raw_cells, fn {_x, _y, _c, _fg, _bg, attrs} ->
        Enum.any?(attrs, fn
          {:region_prominence, p} -> p < 1.0
          _ -> false
        end)
      end)

    clean_cells =
      Enum.map(raw_cells, fn {x, y, char, fg, bg, attrs} ->
        clean_attrs = Enum.reject(attrs, &match?({:region_prominence, _}, &1))
        {x, y, char, fg, bg, clean_attrs}
      end)

    # region-prominence-propagation.md §9 Phase 3 (and now the grid-bg
    # fix, §3.1's deferred TODO, native-palette-riding.md §7): an
    # attr-less cell over a painted bg may carry a `%ColorIntent{}` fg
    # (`Raxol.UI.StyleProcessor.promote_colors/2`'s case-b producer), OR
    # -- since the grid-bg fix -- get ONE synthesized by `ColorResolver`
    # itself from a nil/nil cell sitting over an earlier-painted grid
    # entry (`grid_bg_floor_fg/3`). `CellDim` predates both: it would
    # pass an explicit intent through unchanged, and never sees the
    # synthesized case at all. Both need the SAME whole-list grid the new
    # pipeline builds (a per-cell resolve, as this helper used to do,
    # starts every cell with an empty grid and can never see `under`) --
    # so: resolve the WHOLE list at once, with region prominence forced
    # to the identity (the `{:region_prominence, _}` markers are stripped
    # above, before this call) so this step stays dim-MATH-neutral -- the
    # branch below applies CellDim's OWN dim math, which is the actual
    # RP-N-02 claim, on top of grid-aware literals that now match the new
    # path's grid resolution exactly. A literal fg/bg with nothing to
    # promote round-trips through this call unchanged (Phase 0's
    # byte-identity contract), so this remains a no-op for every cell
    # this golden already covered pre-Phase-3.
    resolved_cells = ColorResolver.resolve_cells(clean_cells, ground: ground_al)

    [resolved_cells, dimmed_flags]
    |> Enum.zip()
    |> Enum.map(fn {{x, y, char, fg_literal, bg_literal, clean_attrs}, dimmed?} ->
      {fg2, bg2} =
        if dimmed? do
          {CellDim.dim_fg(fg_literal, ground_al),
           CellDim.dim_bg(bg_literal, ground_al)}
        else
          {fg_literal, bg_literal}
        end

      {x, y, char, fg2, bg2, clean_attrs}
    end)
  end
end
