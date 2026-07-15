defmodule Raxol.UI.Components.Harness.SpendMeterTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.SpendMeter

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  defp bar_el(rendered), do: Enum.at(rendered.children, 1)
  defp amount_el(rendered), do: Enum.at(rendered.children, 2)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = SpendMeter.init(id: :sm1)
      assert state.spent == 0
      assert state.cap == 1
      assert state.width == 20
      assert state.warn_threshold == 0.75
      assert state.danger_threshold == 0.9
    end
  end

  describe "render/2" do
    test "renders a row with label, bar, and dollar amounts" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 1.5, cap: 5.0)
      rendered = SpendMeter.render(state, default_context())

      assert rendered.type == :row
      assert length(rendered.children) == 3
      assert Enum.at(rendered.children, 0).content == "Spend "
      assert amount_el(rendered).content == " $1.50/$5.00"
    end

    test "colors green well under the cap" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 1.0, cap: 5.0)
      rendered = SpendMeter.render(state, default_context())
      assert bar_el(rendered).fg == :green
    end

    test "colors yellow between warn and danger thresholds" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 4.0, cap: 5.0)
      rendered = SpendMeter.render(state, default_context())
      assert bar_el(rendered).fg == :yellow
    end

    test "colors red at or over the cap" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 5.5, cap: 5.0)
      rendered = SpendMeter.render(state, default_context())
      assert bar_el(rendered).fg == :red
    end

    test "does not crash on a zero cap and reads any spend as over-cap" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 0.05, cap: 0)
      rendered = SpendMeter.render(state, default_context())
      assert bar_el(rendered).fg == :red
      assert amount_el(rendered).content == " $0.05/$0.00"
    end

    test "reads zero spend against a zero cap as green" do
      {:ok, state} = SpendMeter.init(id: :sm, spent: 0, cap: 0)
      rendered = SpendMeter.render(state, default_context())
      assert bar_el(rendered).fg == :green
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = SpendMeter.init(id: :sm)
      {new_state, []} = SpendMeter.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
