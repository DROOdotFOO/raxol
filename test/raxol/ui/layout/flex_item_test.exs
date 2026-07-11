defmodule Raxol.UI.Layout.FlexItemTest do
  @moduledoc """
  Contract tests for FlexItem. Downstream nodes (solver, percentages,
  min-content) code against exactly these behaviors.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.FlexItem

  @container %{width: 100, height: 40}

  defp resolve(child, opts \\ []) do
    axis = Keyword.get(opts, :axis, :horizontal)
    container = Keyword.get(opts, :container, @container)
    content = Keyword.get(opts, :content, fn -> 7 end)
    FlexItem.resolve(child, axis, container, content)
  end

  describe "flex shorthand (terminal-pragmatic)" do
    test "flex: 1 -> grow 1, shrink 1, basis 0, min_main 0" do
      item = resolve(%{style: %{flex: 1}})
      assert %{grow: 1, shrink: 1, base_size: 0, min_main: 0} = item
    end

    test "explicit min_width beats the flex-int min override" do
      item = resolve(%{style: %{flex: 1, min_width: 5}})
      assert item.min_main == 5
      assert item.base_size == 0
    end

    test "tuple form does not override min" do
      item = resolve(%{style: %{flex: {2, 0, 30}}})
      assert %{grow: 2, shrink: 0, base_size: 30, min_main: 0} = item
    end

    test "map form and legacy attrs.flex" do
      a = resolve(%{style: %{flex: %{grow: 3}}})
      b = resolve(%{style: %{}, attrs: %{flex: %{grow: 3}}})
      assert a.grow == 3 and b.grow == 3
      # style form wins over legacy attrs
      c = resolve(%{style: %{flex: %{grow: 5}}, attrs: %{flex: %{grow: 1}}})
      assert c.grow == 5
    end

    test "negative flex factor clamps to 0 (no raise)" do
      item = resolve(%{style: %{flex: -2}})
      assert item.grow == 0
    end
  end

  describe "basis resolution" do
    test "auto basis measures content" do
      item = resolve(%{style: %{}}, content: fn -> 13 end)
      assert item.base_size == 13
    end

    test "auto basis with explicit width uses the width, not content" do
      item =
        resolve(%{style: %{width: 25}},
          content: fn -> raise "must not measure" end
        )

      assert item.base_size == 25
    end

    test "percentage basis against definite container" do
      item = resolve(%{style: %{flex: {0, 1, {:pct, 50}}}})
      assert item.base_size == 50
    end

    test "percentage basis against indefinite container falls back to auto/content" do
      item =
        resolve(%{style: %{flex: {0, 1, {:pct, 50}}}},
          container: %{width: nil, height: 40},
          content: fn -> 9 end
        )

      assert item.base_size == 9
    end
  end

  describe "percentages" do
    test "pct width and pct min/max resolve and round" do
      item = resolve(%{style: %{width: {:pct, 33}, max_width: {:pct, 50}}})
      assert item.base_size == 33
      assert item.max_main == 50
    end

    test "pct cross size against definite cross dimension" do
      item = resolve(%{style: %{height: {:pct, 50}}})
      assert item.cross_size == 20
    end

    test "negative pct clamps to 0 with telemetry, not raise" do
      item = resolve(%{style: %{width: {:pct, -10}}}, content: fn -> 3 end)
      assert item.base_size == 0
    end
  end

  describe "margins" do
    test "int, {h,v}, 4-tuple normalize; auto preserved" do
      assert resolve(%{style: %{margin: 2}}).margin == {2, 2, 2, 2}
      assert resolve(%{style: %{margin: {1, 3}}}).margin == {1, 3, 1, 3}

      assert resolve(%{style: %{margin: {1, 2, 3, :auto}}}).margin ==
               {1, 2, 3, :auto}
    end

    test "margin pct resolves against container WIDTH for all sides (spec)" do
      item = resolve(%{style: %{margin: {{:pct, 10}, 0, {:pct, 10}, 0}}})
      assert item.margin == {10, 0, 10, 0}
    end

    test "outer_main counts axis margins, auto as 0" do
      item = resolve(%{style: %{width: 10, margin: {0, 4, 0, :auto}}})
      assert FlexItem.outer_main(item, 10, :horizontal) == 14
      assert FlexItem.main_margins(item, :horizontal) == {:auto, 4}
    end

    test "cross_margins maps the perpendicular sides" do
      item = resolve(%{style: %{margin: {1, 2, 3, 4}}})
      assert FlexItem.cross_margins(item, :horizontal) == {1, 3}
      assert FlexItem.cross_margins(item, :vertical) == {4, 2}
    end
  end

  describe "clamping" do
    test "clamp_main and hypothetical_main" do
      item = resolve(%{style: %{width: 60, min_width: 20, max_width: 50}})
      assert FlexItem.clamp_main(item, 5) == 20
      assert FlexItem.clamp_main(item, 200) == 50
      assert FlexItem.hypothetical_main(item) == 50
    end

    test "max defaults to infinity" do
      item = resolve(%{style: %{width: 10}})
      assert FlexItem.clamp_main(item, 10_000) == 10_000
    end
  end

  describe "vertical main axis (column)" do
    test "height is main, width is cross; min/max follow" do
      item =
        resolve(%{style: %{height: 8, width: 30, min_height: 4, max_width: 35}},
          axis: :vertical
        )

      assert item.base_size == 8
      assert item.min_main == 4
      assert item.cross_size == 30
      assert item.max_cross == 35
    end
  end

  describe "telemetry on invalid values" do
    test "invalid style emits event and clamps" do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        "flex-item-test-#{inspect(ref)}",
        [:raxol, :layout, :invalid_style],
        fn _e, _m, meta, _ -> send(pid, {:invalid, meta.key}) end,
        nil
      )

      resolve(%{style: %{width: -5}})
      assert_receive {:invalid, :dimension}
      :telemetry.detach("flex-item-test-#{inspect(ref)}")
    end
  end
end
