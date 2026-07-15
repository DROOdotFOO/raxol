defmodule Raxol.UI.Components.Harness.ResidualIndicatorTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ResidualIndicator

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ResidualIndicator.init(id: :ri1)
      assert state.id == :ri1
      assert state.residual == nil
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with a provided residual" do
      assert {:ok, state} =
               ResidualIndicator.init(
                 id: :ri2,
                 residual: "which retry class applies",
                 style: %{fg: :cyan},
                 theme: %{bg: :blue}
               )

      assert state.id == :ri2
      assert state.residual == "which retry class applies"
      assert state.style == %{fg: :cyan}
      assert state.theme == %{bg: :blue}
    end

    test "defaults id to a unique generated string" do
      assert {:ok, state} = ResidualIndicator.init([])
      assert state.id =~ ~r/^residual-indicator-\d+$/
    end
  end

  describe "render/2" do
    test "renders nothing (empty text) when residual is nil" do
      {:ok, state} = ResidualIndicator.init(id: :ri_nil, residual: nil)
      rendered = ResidualIndicator.render(state, default_context())

      assert rendered.type == :text
      assert rendered.content == ""
    end

    test "renders a subtle warning line when residual is present" do
      {:ok, state} =
        ResidualIndicator.init(
          id: :ri_some,
          residual: "which retry class covers a stalled extraction"
        )

      rendered = ResidualIndicator.render(state, default_context())

      assert rendered.type == :text
      assert rendered.id == :ri_some

      assert rendered.content ==
               "⚠ unresolved: which retry class covers a stalled extraction"

      assert rendered.style == %{dim: true}
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = ResidualIndicator.init(id: :ri_evt, residual: "x")

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, []} = ResidualIndicator.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
