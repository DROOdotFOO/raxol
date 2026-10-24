defmodule Raxol.UI.Components.Input.TabsTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.Tabs

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp sample_tabs do
    [
      %{id: :home, label: "Home"},
      %{id: :edit, label: "Edit"},
      %{id: :view, label: "View"}
    ]
  end

  defp key_event(key) do
    %Event{type: :key, data: %{key: key}}
  end

  defp char_event(ch) do
    %Event{type: :key, data: %{key: :char, char: ch}}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = Tabs.init(id: :tabs1)
      assert state.id == :tabs1
      assert state.tabs == []
      assert state.active_index == 0
      assert state.focused == false
      assert state.on_change == nil
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      cb = fn _i -> :ok end

      assert {:ok, state} =
               Tabs.init(
                 id: :tabs2,
                 tabs: sample_tabs(),
                 active_index: 1,
                 focused: true,
                 on_change: cb,
                 style: %{bg: :blue},
                 theme: %{fg: :white}
               )

      assert state.tabs == sample_tabs()
      assert state.active_index == 1
      assert state.focused == true
      assert state.on_change == cb
    end
  end

  describe "handle_event/3 - arrow navigation" do
    test "right arrow moves to next tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      {new_state, []} = Tabs.handle_event(key_event(:right), state, %{})
      assert new_state.active_index == 1
    end

    test "left arrow moves to previous tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 1)
      {new_state, []} = Tabs.handle_event(key_event(:left), state, %{})
      assert new_state.active_index == 0
    end

    test "right arrow wraps from last to first" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 2)
      {new_state, []} = Tabs.handle_event(key_event(:right), state, %{})
      assert new_state.active_index == 0
    end

    test "left arrow wraps from first to last" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      {new_state, []} = Tabs.handle_event(key_event(:left), state, %{})
      assert new_state.active_index == 2
    end

    test "navigation on empty tabs does nothing" do
      {:ok, state} = Tabs.init(id: :t, tabs: [])
      {new_state, []} = Tabs.handle_event(key_event(:right), state, %{})
      assert new_state.active_index == 0
    end
  end

  describe "handle_event/3 - home/end" do
    test "home jumps to first tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 2)
      {new_state, []} = Tabs.handle_event(key_event(:home), state, %{})
      assert new_state.active_index == 0
    end

    test "end jumps to last tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      {new_state, []} = Tabs.handle_event(key_event(:end), state, %{})
      assert new_state.active_index == 2
    end

    test "end on empty tabs does nothing" do
      {:ok, state} = Tabs.init(id: :t, tabs: [])
      {new_state, []} = Tabs.handle_event(key_event(:end), state, %{})
      assert new_state.active_index == 0
    end
  end

  describe "handle_event/3 - number keys" do
    test "number key selects corresponding tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      {new_state, []} = Tabs.handle_event(char_event("2"), state, %{})
      assert new_state.active_index == 1
    end

    test "number key out of range does nothing" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      {new_state, []} = Tabs.handle_event(char_event("9"), state, %{})
      assert new_state.active_index == 0
    end

    test "number key 1 selects first tab" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 2)
      {new_state, []} = Tabs.handle_event(char_event("1"), state, %{})
      assert new_state.active_index == 0
    end
  end

  describe "handle_event/3 - on_change callback" do
    test "fires on_change when tab changes" do
      test_pid = self()
      cb = fn index -> send(test_pid, {:tab_changed, index}) end
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0, on_change: cb)

      {_new_state, []} = Tabs.handle_event(key_event(:right), state, %{})
      assert_receive {:tab_changed, 1}
    end

    test "fires on_change for number key selection" do
      test_pid = self()
      cb = fn index -> send(test_pid, {:tab_changed, index}) end
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0, on_change: cb)

      {_new_state, []} = Tabs.handle_event(char_event("3"), state, %{})
      assert_receive {:tab_changed, 2}
    end
  end

  describe "handle_event/3 - focus/blur" do
    test "focus event sets focused to true" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs())
      {new_state, []} = Tabs.handle_event(%Event{type: :focus}, state, %{})
      assert new_state.focused == true
    end

    test "blur event sets focused to false" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), focused: true)
      {new_state, []} = Tabs.handle_event(%Event{type: :blur}, state, %{})
      assert new_state.focused == false
    end
  end

  describe "handle_event/3 - pass-through" do
    test "unknown events pass through unchanged" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs())
      event = %Event{type: :key, data: %{key: :char, char: "x"}}
      {new_state, []} = Tabs.handle_event(event, state, %{})
      assert new_state == state
    end
  end

  describe "render/2" do
    test "renders empty tabs" do
      {:ok, state} = Tabs.init(id: :t, tabs: [])
      rendered = Tabs.render(state, default_context())
      assert rendered.type == :row
      assert rendered.children == []
    end

    test "renders tab labels with dividers" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 0)
      rendered = Tabs.render(state, default_context())

      assert rendered.type == :row
      # 3 tabs + 2 dividers = 5 children
      assert length(rendered.children) == 5

      # Check dividers at positions 1 and 3
      assert Enum.at(rendered.children, 1).content == "|"
      assert Enum.at(rendered.children, 3).content == "|"
    end

    test "active tab has reverse style" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 1)
      rendered = Tabs.render(state, default_context())

      # Tab at index 1 is the active one -- it's at children position 2 (after tab0 + divider)
      active_tab = Enum.at(rendered.children, 2)
      assert active_tab.style == %{reverse: true}
      assert active_tab.content == " Edit "
    end

    test "inactive tabs have no reverse style" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 1)
      rendered = Tabs.render(state, default_context())

      first_tab = Enum.at(rendered.children, 0)
      assert first_tab.style == %{}
      assert first_tab.content == " Home "
    end

    test "single tab renders without dividers" do
      {:ok, state} = Tabs.init(id: :t, tabs: [%{id: :only, label: "Only"}], active_index: 0)
      rendered = Tabs.render(state, default_context())

      assert length(rendered.children) == 1
      assert Enum.at(rendered.children, 0).content == " Only "
    end
  end

  describe "update/2" do
    test "merges new active index" do
      {:ok, state} = Tabs.init(id: :t, tabs: sample_tabs())
      {updated, []} = Tabs.update(%{active_index: 2}, state)
      assert updated.active_index == 2
    end

    test "merges style and theme" do
      {:ok, state} = Tabs.init(id: :t, style: %{fg: :red}, theme: %{bg: :blue})
      {updated, []} = Tabs.update(%{style: %{bold: true}, theme: %{fg: :green}}, state)
      assert updated.style == %{fg: :red, bold: true}
      assert updated.theme == %{bg: :blue, fg: :green}
    end
  end

  describe "get_tabs tool" do
    test "reports the DSL node's :active and the component state's :active_index" do
      dsl = %{tabs: ["Overview", %{label: "Details"}], active: 1}
      {:ok, component} = Tabs.init(id: :t, tabs: sample_tabs(), active_index: 2)

      assert {:ok, %{tabs: ["Overview", "Details"], active_index: 1}} =
               Tabs.handle_tool_call("get_tabs", %{}, %{widget_state: dsl})

      assert {:ok, %{active_index: 2}} =
               Tabs.handle_tool_call("get_tabs", %{}, %{widget_state: component})
    end
  end
end
