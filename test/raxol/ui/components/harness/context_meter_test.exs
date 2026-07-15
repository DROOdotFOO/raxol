defmodule Raxol.UI.Components.Harness.ContextMeterTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.ContextMeter

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  defp bar_el(rendered), do: Enum.at(rendered.children, 1)
  defp count_el(rendered), do: Enum.at(rendered.children, 2)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ContextMeter.init(id: :cm1)
      assert state.used == 0
      assert state.total == 1
      assert state.width == 20
      assert state.warn_threshold == 0.75
      assert state.danger_threshold == 0.9
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               ContextMeter.init(
                 id: :cm2,
                 used: 8_000,
                 total: 16_000,
                 width: 10,
                 warn_threshold: 0.5,
                 danger_threshold: 0.8
               )

      assert state.used == 8_000
      assert state.total == 16_000
      assert state.width == 10
      assert state.warn_threshold == 0.5
      assert state.danger_threshold == 0.8
    end
  end

  describe "render/2" do
    test "renders a row with label, bar, and token count" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 1_000, total: 16_000)
      rendered = ContextMeter.render(state, default_context())

      assert rendered.type == :row
      assert length(rendered.children) == 3
      assert Enum.at(rendered.children, 0).content == "Context "
      assert count_el(rendered).content == " 1000/16000"
    end

    test "colors green below the warn threshold" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 1_000, total: 16_000)
      rendered = ContextMeter.render(state, default_context())
      assert bar_el(rendered).fg == :green
    end

    test "colors yellow between warn and danger thresholds" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 13_000, total: 16_000)
      rendered = ContextMeter.render(state, default_context())
      assert bar_el(rendered).fg == :yellow
    end

    test "colors red at or above the danger threshold" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 15_000, total: 16_000)
      rendered = ContextMeter.render(state, default_context())
      assert bar_el(rendered).fg == :red
    end

    test "clamps display when used exceeds total" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 20_000, total: 16_000)
      rendered = ContextMeter.render(state, default_context())
      assert bar_el(rendered).fg == :red
      assert bar_el(rendered).content =~ "100%"
    end

    test "does not crash on a zero total and reads as empty/green" do
      {:ok, state} = ContextMeter.init(id: :cm, used: 0, total: 0)
      rendered = ContextMeter.render(state, default_context())
      assert bar_el(rendered).fg == :green
      assert bar_el(rendered).content =~ "0%"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = ContextMeter.init(id: :cm)
      {new_state, []} = ContextMeter.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
