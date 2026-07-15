defmodule Raxol.UI.Components.Harness.StatusBarTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.StatusBar

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = StatusBar.init(id: :hsb1)
      assert state.id == :hsb1
      assert state.model == ""
      assert state.turn_state == :idle
      assert state.context_pct == 0
      assert state.cost == 0
      assert state.separator == " | "
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               StatusBar.init(
                 id: :hsb2,
                 model: "claude-opus-4-6",
                 turn_state: :working,
                 context_pct: 42,
                 cost: 1.23
               )

      assert state.model == "claude-opus-4-6"
      assert state.turn_state == :working
      assert state.context_pct == 42
      assert state.cost == 1.23
    end
  end

  describe "render/2" do
    test "delegates to Display.StatusBar with model/status/context/cost items" do
      {:ok, state} =
        StatusBar.init(
          id: :hsb,
          model: "claude-opus-4-6",
          turn_state: :working,
          context_pct: 42,
          cost: 1.23
        )

      rendered = StatusBar.render(state, default_context())

      assert rendered.type == :row
      # 4 items * 2 elements + 3 separators
      assert length(rendered.children) == 11

      assert Enum.at(rendered.children, 0).content == "Model: "
      assert Enum.at(rendered.children, 1).content == "claude-opus-4-6"
      assert Enum.at(rendered.children, 3).content == "Status: "
      assert Enum.at(rendered.children, 4).content == "⟳ working"
      assert Enum.at(rendered.children, 6).content == "Ctx: "
      assert Enum.at(rendered.children, 7).content == "42%"
      assert Enum.at(rendered.children, 9).content == "Cost: "
      assert Enum.at(rendered.children, 10).content == "$1.23"
    end

    test "renders idle turn-state with a calm glyph" do
      {:ok, state} = StatusBar.init(id: :hsb, turn_state: :idle)
      rendered = StatusBar.render(state, default_context())

      assert Enum.at(rendered.children, 4).content == "• idle"
    end

    test "formats integer cost as two decimals" do
      {:ok, state} = StatusBar.init(id: :hsb, cost: 2)
      rendered = StatusBar.render(state, default_context())

      assert Enum.at(rendered.children, 10).content == "$2.00"
    end

    test "rounds fractional context percentage" do
      {:ok, state} = StatusBar.init(id: :hsb, context_pct: 41.6)
      rendered = StatusBar.render(state, default_context())

      assert Enum.at(rendered.children, 7).content == "42%"
    end
  end

  describe "update/2" do
    test "merges new props via the default Base.Component merge" do
      {:ok, state} = StatusBar.init(id: :hsb)
      {updated, []} = StatusBar.update(%{model: "opus"}, state)
      assert updated.model == "opus"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = StatusBar.init(id: :hsb)
      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, []} = StatusBar.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
