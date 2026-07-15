defmodule Raxol.UI.Components.Harness.DriftIndicatorTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.DriftIndicator

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}
  defp bar_el(rendered), do: Enum.at(rendered.children, 1)
  defp family_el(rendered), do: Enum.at(rendered.children, 2)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = DriftIndicator.init(id: :di1)
      assert state.score == 0
      assert state.family == ""
      assert state.warn_threshold == 50
      assert state.danger_threshold == 75
    end
  end

  describe "render/2" do
    test "renders a row with label, bar, and family name" do
      {:ok, state} =
        DriftIndicator.init(id: :di, score: 10, family: "claude-opus")

      rendered = DriftIndicator.render(state, default_context())

      assert rendered.type == :row
      assert Enum.at(rendered.children, 0).content == "Drift "
      assert family_el(rendered).content == " claude-opus"
    end

    test "colors green for low drift" do
      {:ok, state} = DriftIndicator.init(id: :di, score: 10)
      rendered = DriftIndicator.render(state, default_context())
      assert bar_el(rendered).fg == :green
    end

    test "colors yellow for mid drift" do
      {:ok, state} = DriftIndicator.init(id: :di, score: 60)
      rendered = DriftIndicator.render(state, default_context())
      assert bar_el(rendered).fg == :yellow
    end

    test "colors red for high drift" do
      {:ok, state} = DriftIndicator.init(id: :di, score: 90)
      rendered = DriftIndicator.render(state, default_context())
      assert bar_el(rendered).fg == :red
    end

    test "clamps a negative score to 0 (green)" do
      {:ok, state} = DriftIndicator.init(id: :di, score: -20)
      rendered = DriftIndicator.render(state, default_context())
      assert bar_el(rendered).fg == :green
      assert bar_el(rendered).content =~ "0%"
    end

    test "clamps a score above 100 to 100 (red)" do
      {:ok, state} = DriftIndicator.init(id: :di, score: 250)
      rendered = DriftIndicator.render(state, default_context())
      assert bar_el(rendered).fg == :red
      assert bar_el(rendered).content =~ "100%"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = DriftIndicator.init(id: :di)
      {new_state, []} = DriftIndicator.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
