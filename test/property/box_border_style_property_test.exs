defmodule Raxol.Property.BoxBorderStyleTest do
  @moduledoc """
  Property tests for box style preservation and border_fg/border_bg support.

  Two distinct bugs (#216):
    (a) Layout engine stores box style under attrs.style (nested), but
        StyleProcessor reads top-level :style -- the style is invisible.
    (b) BorderRenderer.resolve_colors/1 ignores border_fg/border_bg,
        forcing users to set :fg (which cascades to children).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Raxol.Test.PropertyGenerators

  alias Raxol.UI.BorderRenderer
  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.StyleProcessor

  # -- Property 4: box style accessible at top level --

  describe "box style nesting (#216a)" do
    property "box layout output has top-level :style, not only attrs.style" do
      check all(box <- box_gen(), max_runs: 300) do
        results = Engine.process_element(box, layout_space(), [])
        box_output = Enum.find(results, &(&1.type == :box))

        assert box_output != nil, "process_element produced no :box element"

        top_level_style = Map.get(box_output, :style, %{})
        input_style = box.style

        assert top_level_style != %{},
               "box style buried in attrs.style, invisible to StyleProcessor"

        assert Map.get(top_level_style, :fg) == Map.get(input_style, :fg),
               "box fg not at top level: expected #{inspect(Map.get(input_style, :fg))}, got #{inspect(Map.get(top_level_style, :fg))}"

        assert Map.get(top_level_style, :bg) == Map.get(input_style, :bg),
               "box bg not at top level: expected #{inspect(Map.get(input_style, :bg))}, got #{inspect(Map.get(top_level_style, :bg))}"
      end
    end

    property "box border_fg/border_bg survive to top-level style" do
      check all(box <- box_gen(), max_runs: 300) do
        results = Engine.process_element(box, layout_space(), [])
        box_output = Enum.find(results, &(&1.type == :box))

        top_level_style = Map.get(box_output, :style, %{})
        input_style = box.style

        assert Map.get(top_level_style, :border_fg) == Map.get(input_style, :border_fg),
               "box border_fg lost in layout engine"

        assert Map.get(top_level_style, :border_bg) == Map.get(input_style, :border_bg),
               "box border_bg lost in layout engine"
      end
    end
  end

  # -- Property 5: StyleProcessor can read box style --

  describe "StyleProcessor reads box style (#216a)" do
    property "flatten_merged_style extracts fg/bg from box element" do
      check all(
              fg <- member_of(named_colors()),
              bg <- member_of(named_colors()),
              max_runs: 300
            ) do
        # Simulate what the layout engine currently produces (buggy: style nested)
        # After fix, style should also be at top level
        box_output = %{
          type: :box,
          x: 0,
          y: 0,
          width: 80,
          height: 24,
          style: %{fg: fg, bg: bg},
          attrs: %{border: :single, padding: 0, style: %{fg: fg, bg: bg}}
        }

        merged = StyleProcessor.flatten_merged_style(%{}, box_output, :default)
        merged_fg = Map.get(merged, :fg) || Map.get(merged, :foreground)

        assert merged_fg == fg,
               "StyleProcessor cannot see fg=#{inspect(fg)} on box element, got #{inspect(merged_fg)}"
      end
    end
  end

  # -- Property 6: border_fg/border_bg used for border cells --

  describe "BorderRenderer border_fg/border_bg (#216b)" do
    property "render_horizontal_line uses border_fg when present" do
      check all(
              fg <- member_of(named_colors()),
              border_fg <- member_of(named_colors()),
              fg != border_fg,
              max_runs: 300
            ) do
        style = %{fg: fg, border_fg: border_fg}
        cells = BorderRenderer.render_horizontal_line(0, 0, 10, "-", style, :default)

        for {_x, _y, _char, cell_fg, _bg, _attrs} <- cells do
          assert cell_fg == border_fg,
                 "border cell should use border_fg=#{inspect(border_fg)}, got #{inspect(cell_fg)}"
        end
      end
    end

    property "render_horizontal_line uses border_bg when present" do
      check all(
              bg <- member_of(named_colors()),
              border_bg <- member_of(named_colors()),
              bg != border_bg,
              max_runs: 300
            ) do
        style = %{bg: bg, border_bg: border_bg, fg: :white}
        cells = BorderRenderer.render_horizontal_line(0, 0, 10, "-", style, :default)

        for {_x, _y, _char, _fg, cell_bg, _attrs} <- cells do
          assert cell_bg == border_bg,
                 "border cell should use border_bg=#{inspect(border_bg)}, got #{inspect(cell_bg)}"
        end
      end
    end

    property "render_box_borders uses border_fg when present" do
      check all(
              fg <- member_of(named_colors()),
              border_fg <- member_of(named_colors()),
              fg != border_fg,
              border_type <- border_type_gen(),
              border_type != :none,
              max_runs: 300
            ) do
        style = %{fg: fg, border_fg: border_fg, bg: :black}
        chars = BorderRenderer.get_border_chars(border_type)
        cells = BorderRenderer.render_box_borders(0, 0, 10, 5, chars, style)

        for {_x, _y, _char, cell_fg, _bg, _attrs} <- cells do
          assert cell_fg == border_fg,
                 "box border cell should use border_fg=#{inspect(border_fg)}, got #{inspect(cell_fg)}"
        end
      end
    end

    property "render_horizontal_line falls back to fg when no border_fg" do
      check all(
              fg <- member_of(named_colors()),
              max_runs: 200
            ) do
        style = %{fg: fg, bg: :black}
        cells = BorderRenderer.render_horizontal_line(0, 0, 10, "-", style, :default)

        for {_x, _y, _char, cell_fg, _bg, _attrs} <- cells do
          assert cell_fg == fg,
                 "without border_fg, should fall back to fg=#{inspect(fg)}, got #{inspect(cell_fg)}"
        end
      end
    end

    # region-prominence-propagation.md §3.1/§9 Phase 3: a border with no
    # explicit color anywhere in the chain (no :border_fg/:fg/:foreground)
    # must resolve to nil -- terminal default -- not a forced :white. See
    # `Raxol.UI.BorderRenderer.resolve_colors/1`.
    test "render_horizontal_line with no color attrs emits nil fg, not :white" do
      style = %{}
      cells = BorderRenderer.render_horizontal_line(0, 0, 10, "-", style, :default)

      for {_x, _y, _char, cell_fg, _bg, _attrs} <- cells do
        assert cell_fg == nil,
               "attr-less border should resolve to nil (terminal default), got #{inspect(cell_fg)}"
      end
    end

    test "render_box_borders with no color attrs emits nil fg, not :white" do
      style = %{}
      chars = BorderRenderer.get_border_chars(:single)
      cells = BorderRenderer.render_box_borders(0, 0, 10, 5, chars, style)

      for {_x, _y, _char, cell_fg, _bg, _attrs} <- cells do
        assert cell_fg == nil,
               "attr-less border should resolve to nil (terminal default), got #{inspect(cell_fg)}"
      end
    end
  end
end
