defmodule Raxol.UI.Components.Display.ViewportTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Display.Viewport
  alias Raxol.View.Components

  defp make_children(n) do
    Enum.map(1..n, fn i -> Components.text(content: "Line #{i}") end)
  end

  defp init_viewport(opts \\ []) do
    {:ok, state} = Viewport.init(opts)
    state
  end

  describe "init/1" do
    test "initializes with defaults" do
      state = init_viewport()
      assert state.scroll_top == 0
      assert state.scroll_left == 0
      assert state.visible_height == 10
      assert state.children == []
      assert state.content_height == 0
      assert state.show_scrollbar == true
      assert state.focused == false
    end

    test "initializes with custom props" do
      children = make_children(20)

      state =
        init_viewport(
          id: :vp1,
          children: children,
          visible_height: 5,
          show_scrollbar: false,
          style: %{bg: :blue}
        )

      assert state.id == :vp1
      assert state.visible_height == 5
      assert state.content_height == 20
      assert state.show_scrollbar == false
      assert state.style == %{bg: :blue}
    end

    test "accepts map props" do
      {:ok, state} = Viewport.init(%{visible_height: 8})
      assert state.visible_height == 8
    end
  end

  describe "render/2" do
    test "renders visible slice of children" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      rendered = Viewport.render(state, %{})

      assert rendered.type == :box
      [content_col | _] = vp_children(rendered)
      assert content_col.type == :column
      assert length(content_col.children) == 5

      first = hd(content_col.children)
      assert first.content == "Line 1"
    end

    test "renders from scroll offset" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 3, scroll_top: 5)

      rendered = Viewport.render(state, %{})

      [content_col | _] = vp_children(rendered)
      contents = Enum.map(content_col.children, & &1.content)
      assert contents == ["Line 6", "Line 7", "Line 8"]
    end

    test "renders scrollbar when content exceeds viewport" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      rendered = Viewport.render(state, %{})

      assert length(vp_children(rendered)) == 2
      [_content, scrollbar] = vp_children(rendered)
      assert scrollbar.type == :column
      assert length(scrollbar.children) == 5
    end

    test "hides scrollbar when content fits" do
      children = make_children(3)
      state = init_viewport(children: children, visible_height: 5)
      rendered = Viewport.render(state, %{})

      assert length(vp_children(rendered)) == 1
    end

    test "hides scrollbar when show_scrollbar is false" do
      children = make_children(20)

      state =
        init_viewport(
          children: children,
          visible_height: 5,
          show_scrollbar: false
        )

      rendered = Viewport.render(state, %{})

      assert length(vp_children(rendered)) == 1
    end

    test "defaults to the :glyph scrollbar style" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      assert state.scrollbar_style == :glyph

      rendered = Viewport.render(state, %{})
      [_content, scrollbar] = vp_children(rendered)
      contents = Enum.map(scrollbar.children, & &1.content)
      assert Enum.all?(contents, &(&1 in ["█", "░"]))
    end

    test ":subtle scrollbar style paints the thumb as a background wash, no glyphs" do
      children = make_children(20)

      state =
        init_viewport(
          children: children,
          visible_height: 5,
          scrollbar_style: :subtle
        )

      rendered = Viewport.render(state, %{})
      [_content, scrollbar] = vp_children(rendered)

      assert length(scrollbar.children) == 5
      # every track cell is a blank space -- no block glyphs anywhere
      assert Enum.all?(scrollbar.children, &(&1.content == " "))
      # exactly one cell (the thumb) carries the pastel-blue background;
      # the rest are unstyled track
      bgs = Enum.map(scrollbar.children, & &1.bg)
      assert Enum.count(bgs, &(&1 != nil)) == 1
      assert Enum.find(bgs, &(&1 != nil)) == {110, 140, 180}
    end

    test ":subtle style renders no scrollbar at all when content fits" do
      children = make_children(3)

      state =
        init_viewport(
          children: children,
          visible_height: 5,
          scrollbar_style: :subtle
        )

      rendered = Viewport.render(state, %{})
      assert length(vp_children(rendered)) == 1
    end

    test "scrollbar_style is updatable via :update_props" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)

      {new_state, _} =
        Viewport.update({:update_props, %{scrollbar_style: :subtle}}, state)

      assert new_state.scrollbar_style == :subtle
    end

    test "renders empty viewport" do
      state = init_viewport(visible_height: 5)
      rendered = Viewport.render(state, %{})

      [content_col] = vp_children(rendered)
      assert content_col.children == []
    end
  end

  describe "keyboard scrolling" do
    test "arrow down scrolls by 1" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      event = %Event{type: :key, data: %{key: :down}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 1
    end

    test "arrow up scrolls by -1" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 5, scroll_top: 5)

      event = %Event{type: :key, data: %{key: :up}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 4
    end

    test "page down scrolls by visible_height" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      event = %Event{type: :key, data: %{key: :page_down}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 5
    end

    test "page up scrolls by visible_height" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 5, scroll_top: 10)

      event = %Event{type: :key, data: %{key: :page_up}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 5
    end

    test "home scrolls to top" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 5, scroll_top: 10)

      event = %Event{type: :key, data: %{key: :home}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 0
    end

    test "end scrolls to bottom" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)
      event = %Event{type: :key, data: %{key: :end}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 15
    end

    test "does not scroll past bottom" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 5, scroll_top: 15)

      event = %Event{type: :key, data: %{key: :down}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 15
    end

    test "does not scroll past top" do
      children = make_children(20)

      state =
        init_viewport(children: children, visible_height: 5, scroll_top: 0)

      event = %Event{type: :key, data: %{key: :up}}

      {updated, []} = Viewport.handle_event(event, state, %{})
      assert updated.scroll_top == 0
    end

    test "string key names work" do
      children = make_children(20)
      state = init_viewport(children: children, visible_height: 5)

      {updated, []} =
        Viewport.handle_event(
          %Event{type: :key, data: %{key: "Down"}},
          state,
          %{}
        )

      assert updated.scroll_top == 1

      {updated, []} =
        Viewport.handle_event(
          %Event{type: :key, data: %{key: "PageDown"}},
          updated,
          %{}
        )

      assert updated.scroll_top == 6
    end

    test "unknown keys pass through" do
      state = init_viewport(children: make_children(20), visible_height: 5)
      event = %Event{type: :key, data: %{key: "x"}}
      {same, []} = Viewport.handle_event(event, state, %{})
      assert same.scroll_top == 0
    end
  end

  describe "update/2" do
    test "set_children updates content and clamps scroll" do
      state =
        init_viewport(
          children: make_children(20),
          visible_height: 5,
          scroll_top: 15
        )

      new_children = make_children(8)
      {updated, []} = Viewport.update({:set_children, new_children}, state)

      assert updated.content_height == 8
      assert updated.scroll_top == 3
    end

    test "scroll_to sets exact position" do
      state = init_viewport(children: make_children(20), visible_height: 5)
      {updated, []} = Viewport.update({:scroll_to, 7}, state)
      assert updated.scroll_top == 7
    end

    test "scroll_to clamps to valid range" do
      state = init_viewport(children: make_children(20), visible_height: 5)
      {updated, []} = Viewport.update({:scroll_to, 100}, state)
      assert updated.scroll_top == 15
    end

    test "scroll_by adds delta" do
      state =
        init_viewport(
          children: make_children(20),
          visible_height: 5,
          scroll_top: 3
        )

      {updated, []} = Viewport.update({:scroll_by, 4}, state)
      assert updated.scroll_top == 7
    end

    test "scroll_by negative" do
      state =
        init_viewport(
          children: make_children(20),
          visible_height: 5,
          scroll_top: 10
        )

      {updated, []} = Viewport.update({:scroll_by, -3}, state)
      assert updated.scroll_top == 7
    end

    test "set_visible_height adjusts and clamps" do
      state =
        init_viewport(
          children: make_children(20),
          visible_height: 5,
          scroll_top: 15
        )

      {updated, []} = Viewport.update({:set_visible_height, 10}, state)
      assert updated.visible_height == 10
      assert updated.scroll_top == 10
    end

    test "update_props merges multiple fields" do
      state = init_viewport(children: make_children(5), visible_height: 5)
      new_children = make_children(30)

      {updated, []} =
        Viewport.update(
          {:update_props, %{children: new_children, visible_height: 8}},
          state
        )

      assert updated.content_height == 30
      assert updated.visible_height == 8
    end

    test "unknown messages pass through" do
      state = init_viewport()
      {same, []} = Viewport.update(:unknown, state)
      assert same == state
    end
  end

  describe "focus events" do
    test "focus event sets focused" do
      state = init_viewport()

      {updated, []} =
        Viewport.handle_event(%Event{type: :focus, data: %{}}, state, %{})

      assert updated.focused == true
    end

    test "blur event clears focused" do
      state = %{init_viewport() | focused: true}

      {updated, []} =
        Viewport.handle_event(%Event{type: :blur, data: %{}}, state, %{})

      assert updated.focused == false
    end
  end

  describe "mount/1 and unmount/1" do
    test "mount returns {state, []}" do
      state = init_viewport()
      assert {^state, []} = Viewport.mount(state)
    end

    test "unmount returns state" do
      state = init_viewport()
      assert Viewport.unmount(state) == state
    end
  end

  # Viewport renders as a :box (addressable, self-bounding) wrapping a :row of
  # [content_column, scrollbar]. Descend to that row's children.
  defp vp_children(rendered), do: hd(rendered.children).children
end
