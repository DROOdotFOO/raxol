defmodule Raxol.UI.Components.Harness.TaintBadgeTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.TaintBadge

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = TaintBadge.init(id: :tb1)
      assert state.id == :tb1
      assert state.taint == false
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes tainted" do
      assert {:ok, state} = TaintBadge.init(id: :tb2, taint: true)
      assert state.taint == true
    end
  end

  describe "render/2" do
    test "renders nothing (empty text) when trusted" do
      {:ok, state} = TaintBadge.init(id: :tb_trusted, taint: false)
      rendered = TaintBadge.render(state, default_context())

      assert rendered.type == :text
      assert rendered.content == ""
    end

    test "renders the untrusted label in yellow when tainted" do
      {:ok, state} = TaintBadge.init(id: :tb_tainted, taint: true)
      rendered = TaintBadge.render(state, default_context())

      assert rendered.type == :text
      assert rendered.content == "⚠ untrusted"
      assert rendered.style.fg == :yellow
      assert rendered.style.bold == true
    end

    test "an explicit style colour overrides the default yellow" do
      {:ok, state} =
        TaintBadge.init(id: :tb_override, taint: true, style: %{fg: :red})

      rendered = TaintBadge.render(state, default_context())

      assert rendered.style.fg == :red
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged (stateless component)" do
      {:ok, state} = TaintBadge.init(id: :tb_evt, taint: true)
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      {new_state, []} = TaintBadge.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
