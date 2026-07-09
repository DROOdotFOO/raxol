defmodule Raxol.UI.Components.Input.SelectListTest do
  use ExUnit.Case

  alias Raxol.UI.Components.Input.SelectList
  alias Raxol.UI.Components.Input.SelectList.{Navigation, Pagination, Search, Selection, Utils}

  # -- Helpers --

  defp sample_options do
    [{"Apple", :apple}, {"Banana", :banana}, {"Cherry", :cherry}]
  end

  defp many_options(n \\ 25) do
    Enum.map(1..n, fn i -> {"Item #{i}", :"item_#{i}"} end)
  end

  defp init_state(extra_props \\ %{}) do
    props = Map.merge(%{options: sample_options()}, extra_props)
    {:ok, state} = SelectList.init(props)
    state
  end

  defp key_event(key) do
    %{type: :key, data: %{key: key}}
  end

  defp focus_event, do: %{type: :focus}
  defp blur_event, do: %{type: :blur}

  defp resize_event(w, h) do
    %{type: :resize, data: %{width: w, height: h}}
  end

  defp mouse_event(x, y) do
    %{type: :mouse, data: %{x: x, y: y}}
  end

  # -- init/1 --

  describe "init/1" do
    test "returns {:ok, state} with default values" do
      {:ok, state} = SelectList.init(%{options: sample_options()})

      assert state.options == sample_options()
      assert state.focused_index == 0
      assert state.scroll_offset == 0
      assert state.search_text == ""
      assert state.filtered_options == nil
      assert state.is_filtering == false
      assert state.selected_indices == MapSet.new()
      assert state.selected_index == 0
      assert state.is_search_focused == false
      assert state.page_size == 10
      assert state.visible_items == 10
      assert state.current_page == 0
      assert state.enable_search == false
      assert state.multiple == false
      assert state.has_focus == false
      assert state.placeholder == "Type to search..."
      assert state.empty_message == "No options available"
      assert state.show_pagination == false
    end

    test "accepts custom options" do
      {:ok, state} =
        SelectList.init(%{
          options: sample_options(),
          enable_search: true,
          multiple: true,
          page_size: 5,
          placeholder: "Find...",
          empty_message: "Nothing here",
          label: "Fruits"
        })

      assert state.enable_search == true
      assert state.multiple == true
      assert state.page_size == 5
      assert state.placeholder == "Find..."
      assert state.empty_message == "Nothing here"
      assert state.label == "Fruits"
    end

    test "raises when options prop is missing" do
      assert_raise ArgumentError, ~r/requires :options/, fn ->
        apply(SelectList, :init, [%{}])
      end
    end

    test "raises when options is not a list" do
      assert_raise ArgumentError, ~r/:options must be a list/, fn ->
        SelectList.init(%{options: "not a list"})
      end
    end

    test "raises when option label is not a string" do
      assert_raise ArgumentError, ~r/labels must be strings/, fn ->
        SelectList.init(%{options: [{123, :val}]})
      end
    end

    test "raises when option is not a tuple" do
      assert_raise ArgumentError, ~r/must be .* tuples/, fn ->
        SelectList.init(%{options: [:bare_atom]})
      end
    end

    test "accepts three-element tuples with style map" do
      opts = [{"Styled", :styled, %{bold: true}}]
      {:ok, state} = SelectList.init(%{options: opts})
      assert state.options == opts
    end

    test "raises when three-element tuple style is not a map" do
      assert_raise ArgumentError, ~r/style .* must be a map/, fn ->
        SelectList.init(%{options: [{"Bad", :bad, "not_a_map"}]})
      end
    end

    test "accepts empty options list" do
      {:ok, state} = SelectList.init(%{options: []})
      assert state.options == []
    end
  end

  # -- update/2 --

  describe "update/2 :update_props" do
    test "merges new props into state" do
      state = init_state()
      new_options = [{"Date", :date}, {"Elderberry", :elderberry}]

      {updated, _cmd} = SelectList.update({:update_props, %{options: new_options}}, state)

      assert updated.options == new_options
    end

    test "resets navigation state when options change" do
      state = %{init_state() | focused_index: 2, scroll_offset: 1, current_page: 1}
      new_options = [{"X", :x}, {"Y", :y}]

      {updated, _cmd} = SelectList.update({:update_props, %{options: new_options}}, state)

      assert updated.focused_index == 0
      assert updated.scroll_offset == 0
      assert updated.current_page == 0
      assert updated.filtered_options == nil
    end

    test "preserves state when non-option props change" do
      state = %{init_state() | focused_index: 2}

      {updated, _cmd} =
        SelectList.update(
          {:update_props, %{options: state.options, label: "New Label"}},
          state
        )

      assert updated.focused_index == 2
      assert updated.label == "New Label"
    end
  end

  describe "update/2 :search" do
    test "updates search_buffer immediately" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.update({:search, "app"}, state)

      assert updated.search_buffer == "app"
    end
  end

  describe "update/2 :apply_search" do
    test "filters options by search text" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.update({:apply_search, "ban"}, state)

      assert updated.search_text == "ban"
      assert updated.is_filtering == true
      assert updated.filtered_options == [{"Banana", :banana}]
    end

    test "clears filter when search text is empty" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.update({:apply_search, ""}, state)

      assert updated.filtered_options == nil
      assert updated.is_filtering == false
    end
  end

  describe "update/2 :select_option" do
    test "selects an option by index in single mode" do
      state = init_state()

      {updated, _commands} = SelectList.update({:select_option, 1}, state)

      assert updated.selected_index == 1
      assert updated.focused_index == 1
    end

    test "toggles selection in multiple mode" do
      state = init_state(%{multiple: true})

      {s1, _} = SelectList.update({:select_option, 0}, state)
      assert MapSet.member?(s1.selected_indices, 0)

      {s2, _} = SelectList.update({:select_option, 2}, s1)
      assert MapSet.member?(s2.selected_indices, 0)
      assert MapSet.member?(s2.selected_indices, 2)

      # Toggle off
      {s3, _} = SelectList.update({:select_option, 0}, s2)
      refute MapSet.member?(s3.selected_indices, 0)
      assert MapSet.member?(s3.selected_indices, 2)
    end

    test "clamps index to valid range" do
      state = init_state()

      {updated, _} = SelectList.update({:select_option, 99}, state)
      assert updated.selected_index == 2

      {updated2, _} = SelectList.update({:select_option, -5}, state)
      assert updated2.selected_index == 0
    end
  end

  describe "update/2 :set_page" do
    test "updates current page and focused index" do
      state = init_state(%{options: many_options(), page_size: 5})

      updated = Pagination.update_page_state(state, 2)

      assert updated.current_page == 2
      assert updated.focused_index == 10
    end

    test "clamps page number to valid range" do
      state = init_state(%{options: many_options(12), page_size: 5})

      updated = Pagination.update_page_state(state, 100)

      # max page is 2 (0-indexed) for 12 items with page_size 5
      assert updated.current_page == 2
    end
  end

  describe "update/2 :set_focus" do
    test "sets has_focus to true" do
      state = init_state()

      {updated, _cmd} = SelectList.update({:set_focus, true}, state)

      assert updated.has_focus == true
    end

    test "sets has_focus to false" do
      state = %{init_state() | has_focus: true}

      {updated, _cmd} = SelectList.update({:set_focus, false}, state)

      assert updated.has_focus == false
    end

    test "triggers on_focus callback when gaining focus" do
      test_pid = self()

      on_focus = fn index ->
        send(test_pid, {:focused, index})
      end

      state = init_state(%{on_focus: on_focus})

      {_updated, _cmd} = SelectList.update({:set_focus, true}, state)

      assert_receive {:focused, 0}
    end
  end

  describe "update/2 :toggle_search_focus" do
    test "toggles search focus when search is enabled" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.update({:toggle_search_focus}, state)

      assert updated.is_search_focused == true

      {toggled_back, _cmd} = SelectList.update({:toggle_search_focus}, updated)

      assert toggled_back.is_search_focused == false
    end

    test "does nothing when search is disabled" do
      state = init_state(%{enable_search: false})

      {updated, _cmd} = SelectList.update({:toggle_search_focus}, state)

      assert updated.is_search_focused == false
    end

    test "clears search state when toggling" do
      state = %{
        init_state(%{enable_search: true})
        | search_text: "old",
          search_buffer: "old",
          filtered_options: [{"Apple", :apple}],
          is_filtering: true
      }

      {updated, _cmd} = SelectList.update({:toggle_search_focus}, state)

      assert updated.search_text == ""
      assert updated.search_buffer == ""
      assert updated.filtered_options == nil
      assert updated.is_filtering == false
    end
  end

  describe "update/2 :set_visible_height" do
    test "updates visible_height" do
      state = init_state()

      {updated, _cmd} = SelectList.update({:set_visible_height, 20}, state)

      assert updated.visible_height == 20
    end
  end

  describe "update/2 :set_search_focus" do
    test "activates search focus and clears search state" do
      state = %{
        init_state(%{enable_search: true})
        | search_text: "old",
          search_buffer: "old",
          filtered_options: [{"Apple", :apple}],
          is_filtering: true
      }

      {updated, _cmd} = SelectList.update({:set_search_focus, true}, state)

      assert updated.is_search_focused == true
      assert updated.search_text == ""
      assert updated.search_buffer == ""
      assert updated.filtered_options == nil
      assert updated.is_filtering == false
    end
  end

  describe "update/2 with unknown message" do
    test "returns state unchanged for unknown messages" do
      state = init_state()

      {updated, cmd} = SelectList.update({:unknown_message, :data}, state)

      assert updated.options == state.options
      assert cmd == nil
    end
  end

  # -- handle_event/3 --

  describe "handle_event/3 key navigation" do
    test "arrow down moves focus down" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(key_event(:down), state, %{})

      assert updated.focused_index == 1
    end

    test "arrow down does not exceed last item" do
      state = %{init_state() | focused_index: 2}

      {updated, _cmd} = SelectList.handle_event(key_event(:down), state, %{})

      assert updated.focused_index == 2
    end

    test "arrow up moves focus up" do
      state = %{init_state() | focused_index: 2}

      {updated, _cmd} = SelectList.handle_event(key_event(:up), state, %{})

      assert updated.focused_index == 1
    end

    test "arrow up does not go below zero" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(key_event(:up), state, %{})

      assert updated.focused_index == 0
    end

    test "string key 'Down' works for navigation" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(key_event("Down"), state, %{})

      assert updated.focused_index == 1
    end

    test "string key 'Up' works for navigation" do
      state = %{init_state() | focused_index: 1}

      {updated, _cmd} = SelectList.handle_event(key_event("Up"), state, %{})

      assert updated.focused_index == 0
    end

    test "Home key moves to first item" do
      state = %{init_state() | focused_index: 2}

      {updated, _cmd} = SelectList.handle_event(key_event(:home), state, %{})

      assert updated.focused_index == 0
      assert updated.scroll_offset == 0
    end

    test "End key moves to last item" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(key_event(:end), state, %{})

      assert updated.focused_index == 2
    end

    test "PageDown moves focus by visible_items" do
      state = init_state(%{options: many_options(), visible_items: 5})

      {updated, _cmd} = SelectList.handle_event(key_event(:page_down), state, %{})

      assert updated.focused_index == 5
    end

    test "PageDown does not exceed last item" do
      state = %{init_state(%{options: many_options(8), visible_items: 5}) | focused_index: 5}

      {updated, _cmd} = SelectList.handle_event(key_event(:page_down), state, %{})

      assert updated.focused_index == 7
    end

    test "PageUp moves focus up by visible_items" do
      state = %{init_state(%{options: many_options(), visible_items: 5}) | focused_index: 10}

      {updated, _cmd} = SelectList.handle_event(key_event(:page_up), state, %{})

      assert updated.focused_index == 5
    end

    test "PageUp does not go below zero" do
      state = %{init_state(%{options: many_options(), visible_items: 5}) | focused_index: 2}

      {updated, _cmd} = SelectList.handle_event(key_event(:page_up), state, %{})

      assert updated.focused_index == 0
    end

    test "string PageDown and PageUp keys work" do
      state = init_state(%{options: many_options(), visible_items: 5})

      {updated, _cmd} = SelectList.handle_event(key_event("PageDown"), state, %{})
      assert updated.focused_index == 5

      {updated2, _cmd} = SelectList.handle_event(key_event("PageUp"), updated, %{})
      assert updated2.focused_index == 0
    end
  end

  describe "handle_event/3 selection keys" do
    test "Enter selects the focused option in single mode" do
      state = %{init_state() | focused_index: 1}

      {updated, _cmd} = SelectList.handle_event(key_event(:enter), state, %{})

      assert updated.selected_index == 1
    end

    test "Space selects the focused option in single mode" do
      state = %{init_state() | focused_index: 2}

      {updated, _cmd} = SelectList.handle_event(key_event(:space), state, %{})

      assert updated.selected_index == 2
    end

    test "Enter toggles selection in multiple mode" do
      state = init_state(%{multiple: true})

      {s1, _} = SelectList.handle_event(key_event(:enter), state, %{})
      assert MapSet.member?(s1.selected_indices, 0)

      {s2, _} = SelectList.handle_event(key_event(:enter), s1, %{})
      refute MapSet.member?(s2.selected_indices, 0)
    end

    test "Space toggles selection in multiple mode" do
      state = %{init_state(%{multiple: true}) | focused_index: 1}

      {s1, _} = SelectList.handle_event(key_event(:space), state, %{})
      assert MapSet.member?(s1.selected_indices, 1)

      # focused_index is set to 1 by selection
      {s2, _} = SelectList.handle_event(key_event(:space), s1, %{})
      refute MapSet.member?(s2.selected_indices, 1)
    end

    test "string Enter and Space keys work" do
      state = %{init_state() | focused_index: 1}

      {updated, _cmd} = SelectList.handle_event(key_event("Enter"), state, %{})
      assert updated.selected_index == 1

      state2 = %{init_state() | focused_index: 2}

      {updated2, _cmd} = SelectList.handle_event(key_event("Space"), state2, %{})
      assert updated2.selected_index == 2
    end
  end

  describe "handle_event/3 search keys" do
    test "Tab toggles search focus when search is enabled" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.handle_event(key_event(:tab), state, %{})

      assert updated.is_search_focused == true
    end

    test "Tab does nothing when search is disabled" do
      state = init_state(%{enable_search: false})

      {updated, _cmd} = SelectList.handle_event(key_event(:tab), state, %{})

      assert updated.is_search_focused == false
    end

    test "Backspace removes last character from search buffer" do
      state = %{
        init_state(%{enable_search: true})
        | is_search_focused: true,
          search_buffer: "app"
      }

      {updated, _cmd} = SelectList.handle_event(key_event(:backspace), state, %{})

      assert updated.search_buffer == "ap"
    end

    test "Backspace does nothing when search buffer is empty" do
      state = %{
        init_state(%{enable_search: true})
        | is_search_focused: true,
          search_buffer: ""
      }

      {updated, _cmd} = SelectList.handle_event(key_event(:backspace), state, %{})

      assert updated.search_buffer == ""
    end

    test "Backspace does nothing when search is not focused" do
      state = %{
        init_state(%{enable_search: true})
        | is_search_focused: false,
          search_buffer: "abc"
      }

      {updated, _cmd} = SelectList.handle_event(key_event(:backspace), state, %{})

      assert updated.search_buffer == "abc"
    end

    test "character key appends to search buffer when search is focused" do
      state = %{
        init_state(%{enable_search: true})
        | is_search_focused: true,
          search_buffer: ""
      }

      {updated, _cmd} = SelectList.handle_event(key_event("a"), state, %{})

      assert updated.search_buffer == "a"
    end

    test "character key is ignored when search is not focused" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.handle_event(key_event("a"), state, %{})

      assert updated.search_buffer == ""
    end

    test "character key is ignored when search is disabled" do
      state = %{init_state(%{enable_search: false}) | is_search_focused: false}

      {updated, _cmd} = SelectList.handle_event(key_event("x"), state, %{})

      assert updated.search_buffer == ""
    end
  end

  describe "handle_event/3 focus and blur" do
    test "focus event sets has_focus to true" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(focus_event(), state, %{})

      assert updated.has_focus == true
    end

    test "blur event sets has_focus to false" do
      state = %{init_state() | has_focus: true}

      {updated, _cmd} = SelectList.handle_event(blur_event(), state, %{})

      assert updated.has_focus == false
    end
  end

  describe "handle_event/3 resize" do
    test "resize event updates visible_height" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(resize_event(80, 24), state, %{})

      assert updated.visible_height == 24
    end
  end

  describe "handle_event/3 mouse" do
    test "clicking on an option selects it" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(mouse_event(0, 1), state, %{})

      assert updated.selected_index == 1
      assert updated.focused_index == 1
    end

    test "clicking on search bar area activates search focus" do
      state = init_state(%{enable_search: true})

      {updated, _cmd} = SelectList.handle_event(mouse_event(5, 0), state, %{})

      assert updated.is_search_focused == true
    end

    test "clicking out of range does not change state" do
      state = init_state()

      {updated, _cmd} = SelectList.handle_event(mouse_event(0, 99), state, %{})

      assert updated.selected_index == state.selected_index
    end
  end

  # -- render/2 --

  describe "render/2" do
    test "returns a container with rendered children" do
      state = init_state()
      result = SelectList.render(state, %{})

      assert result.type == :container
      assert is_list(result.children)
      assert length(result.children) == 3

      Enum.each(result.children, fn element ->
        assert element.type == :text
        assert is_binary(element.content)
      end)
    end

    test "renders correct option labels" do
      state = init_state()
      result = SelectList.render(state, %{})

      contents =
        Enum.map_join(result.children, "", fn el -> el.content end)

      assert contents =~ "Apple"
      assert contents =~ "Banana"
      assert contents =~ "Cherry"
    end

    test "renders selected marker on selected option" do
      state = %{init_state() | selected_index: 1}
      result = SelectList.render(state, %{})

      banana_el = Enum.at(result.children, 1)
      assert banana_el.content =~ "> "
    end

    test "renders only visible options based on scroll_offset and visible_items" do
      state = init_state(%{options: many_options(20), visible_items: 5})
      state = %{state | scroll_offset: 3}

      result = SelectList.render(state, %{})

      assert length(result.children) == 5

      first_content = Enum.at(result.children, 0).content
      assert first_content =~ "Item 4"
    end

    test "renders filtered options when filtering is active" do
      state = %{
        init_state()
        | filtered_options: [{"Banana", :banana}],
          is_filtering: true
      }

      result = SelectList.render(state, %{})

      assert length(result.children) == 1
      assert Enum.at(result.children, 0).content =~ "Banana"
    end

    test "renders search bar when search_enabled is true" do
      state = %{init_state() | search_enabled: true, search_query: "test"}
      result = SelectList.render(state, %{})

      search_content = Enum.at(result.children, 0).content
      assert search_content =~ "Search:"
      assert search_content =~ "test"
    end

    test "renders pagination info when paginated is true" do
      state = %{init_state(%{options: many_options(20)}) | paginated: true}
      result = SelectList.render(state, %{})

      last_el = List.last(result.children)
      assert last_el.content =~ "Page"
    end

    test "renders empty container when options are empty" do
      state = init_state(%{options: []})
      result = SelectList.render(state, %{})

      assert result.type == :container
      assert result.children == []
    end
  end

  # -- Selection module --

  describe "Selection" do
    test "selected?/2 returns true for selected index in single mode" do
      state = %{init_state() | selected_index: 1, multiple: false}

      assert Selection.selected?(state, 1)
      refute Selection.selected?(state, 0)
      refute Selection.selected?(state, 2)
    end

    test "selected?/2 returns true for selected indices in multiple mode" do
      state = %{
        init_state(%{multiple: true})
        | selected_indices: MapSet.new([0, 2])
      }

      assert Selection.selected?(state, 0)
      refute Selection.selected?(state, 1)
      assert Selection.selected?(state, 2)
    end

    test "get_selected_option/1 returns the selected option" do
      state = %{init_state() | selected_index: 1}

      assert Selection.get_selected_option(state) == {"Banana", :banana}
    end

    test "get_selected_value/1 returns the value of the selected option" do
      state = %{init_state() | selected_index: 2}

      assert Selection.get_selected_value(state) == :cherry
    end

    test "get_selected_value/1 returns nil when no options" do
      state = init_state(%{options: []})

      assert Selection.get_selected_value(state) == nil
    end

    test "select_by_value/2 selects by option value" do
      state = init_state()

      {updated, _commands} = Selection.select_by_value(state, :cherry)

      assert updated.selected_index == 2
    end

    test "select_by_value/2 returns unchanged state for missing value" do
      state = init_state()

      {updated, commands} = Selection.select_by_value(state, :nonexistent)

      assert updated == state
      assert commands == []
    end

    test "generates on_select callback command" do
      test_pid = self()
      on_select = fn value -> send(test_pid, {:selected, value}) end
      state = Map.put(init_state(), :on_select, on_select)

      {_updated, commands} = Selection.update_selection_state(state, 1)

      assert Enum.any?(commands, fn
        {:callback, ^on_select, [:banana]} -> true
        _ -> false
      end)
    end

    test "generates on_change callback command" do
      test_pid = self()
      on_change = fn new_state -> send(test_pid, {:changed, new_state}) end
      state = Map.put(init_state(), :on_change, on_change)

      {_updated, commands} = Selection.update_selection_state(state, 1)

      assert Enum.any?(commands, fn
        {:callback, ^on_change, [_state]} -> true
        _ -> false
      end)
    end
  end

  # -- Search module --

  describe "Search" do
    test "update_search_state/2 filters options by query" do
      state = init_state()

      updated = Search.update_search_state(state, "ch")

      assert updated.is_filtering == true
      assert updated.filtered_options == [{"Cherry", :cherry}]
      assert updated.selected_index == 0
      assert updated.scroll_offset == 0
    end

    test "update_search_state/2 is case-insensitive" do
      state = init_state()

      updated = Search.update_search_state(state, "APPLE")

      assert updated.filtered_options == [{"Apple", :apple}]
    end

    test "update_search_state/2 returns nil filtered_options for empty query" do
      state = init_state()

      updated = Search.update_search_state(state, "")

      assert updated.filtered_options == nil
      assert updated.is_filtering == false
    end

    test "clear_search/1 resets search state" do
      state = %{
        init_state()
        | search_query: "test",
          filtered_options: [{"Apple", :apple}],
          selected_index: 1,
          scroll_offset: 5
      }

      updated = Search.clear_search(state)

      assert updated.search_query == ""
      assert updated.filtered_options == nil
      assert updated.selected_index == 0
      assert updated.scroll_offset == 0
    end

    test "search_active?/1 returns true when query is non-empty" do
      state = %{init_state() | search_query: "abc"}
      assert Search.search_active?(state)
    end

    test "search_active?/1 returns false when query is empty" do
      state = %{init_state() | search_query: ""}
      refute Search.search_active?(state)
    end

    test "get_results_count/1 returns total count when not filtering" do
      state = init_state()
      assert Search.get_results_count(state) == 3
    end

    test "get_results_count/1 returns filtered count when filtering" do
      state = %{init_state() | filtered_options: [{"Apple", :apple}]}
      assert Search.get_results_count(state) == 1
    end

    test "append_to_search/2 appends character and filters" do
      state = %{init_state() | search_query: "ap"}

      updated = Search.append_to_search(state, "p")

      assert updated.search_query == "app"
      assert updated.filtered_options == [{"Apple", :apple}]
    end

    test "backspace_search/1 removes last character and re-filters" do
      state = %{init_state() | search_query: "app"}

      updated = Search.backspace_search(state)

      assert updated.search_query == "ap"
      # "ap" matches "Apple"
      assert updated.filtered_options == [{"Apple", :apple}]
    end

    test "backspace_search/1 on empty query stays empty" do
      state = %{init_state() | search_query: ""}

      updated = Search.backspace_search(state)

      assert updated.search_query == ""
    end
  end

  # -- Navigation module --

  describe "Navigation" do
    test "handle_arrow_down/1 increments focused_index" do
      state = init_state()

      updated = Navigation.handle_arrow_down(state)

      assert updated.focused_index == 1
    end

    test "handle_arrow_up/1 decrements focused_index" do
      state = %{init_state() | focused_index: 2}

      updated = Navigation.handle_arrow_up(state)

      assert updated.focused_index == 1
    end

    test "handle_home/1 sets focused_index to 0" do
      state = %{init_state() | focused_index: 2, scroll_offset: 5}

      updated = Navigation.handle_home(state)

      assert updated.focused_index == 0
      assert updated.scroll_offset == 0
    end

    test "handle_end/1 sets focused_index to last item" do
      state = init_state()

      updated = Navigation.handle_end(state)

      assert updated.focused_index == 2
    end

    test "handle_page_down/1 jumps by visible_items" do
      state = init_state(%{options: many_options(20), visible_items: 5})

      updated = Navigation.handle_page_down(state)

      assert updated.focused_index == 5
    end

    test "handle_page_up/1 jumps back by visible_items" do
      state = %{init_state(%{options: many_options(20), visible_items: 5}) | focused_index: 10}

      updated = Navigation.handle_page_up(state)

      assert updated.focused_index == 5
    end

    test "handle_search/2 filters options and resets position" do
      state = %{init_state() | focused_index: 2, scroll_offset: 1, search_query: ""}

      updated = Navigation.handle_search(state, "ban")

      assert updated.search_query == "ban"
      assert updated.focused_index == 0
      assert updated.scroll_offset == 0
      assert length(updated.filtered_options) == 1
    end

    test "clear_search/1 resets filter state" do
      state = %{
        init_state()
        | filtered_options: [{"Apple", :apple}],
          search_query: "app",
          focused_index: 0,
          scroll_offset: 0
      }

      updated = Navigation.clear_search(state)

      assert updated.filtered_options == nil
      assert updated.search_query == ""
    end

    test "scroll_offset adjusts when focused item is below viewport" do
      state = %{
        init_state(%{options: many_options(20), visible_items: 5})
        | focused_index: 0,
          scroll_offset: 0
      }

      # Navigate to item 6 (beyond visible_items of 5)
      updated = %{state | focused_index: 6}
      result = Navigation.update_scroll_position(updated)

      assert result.scroll_offset == 2
    end

    test "scroll_offset adjusts when focused item is above viewport" do
      state = %{
        init_state(%{options: many_options(20), visible_items: 5})
        | focused_index: 2,
          scroll_offset: 5
      }

      result = Navigation.update_scroll_position(state)

      assert result.scroll_offset == 2
    end
  end

  # -- Pagination module --

  describe "Pagination" do
    test "get_effective_options/1 returns all options when not filtering" do
      state = init_state()

      assert Utils.get_effective_options(state) == sample_options()
    end

    test "get_effective_options/1 returns filtered options when filtering" do
      state = %{init_state() | filtered_options: [{"Apple", :apple}]}

      assert Utils.get_effective_options(state) == [{"Apple", :apple}]
    end

    test "calculate_total_pages/1 computes correct page count" do
      state = init_state(%{options: many_options(23), page_size: 10})

      assert Pagination.calculate_total_pages(state) == 3
    end

    test "calculate_total_pages/1 returns 0 for empty list" do
      state = init_state(%{options: [], page_size: 10})

      assert Pagination.calculate_total_pages(state) == 0
    end

    test "has_next_page?/1 and has_prev_page?/1" do
      state = init_state(%{options: many_options(25), page_size: 10})

      assert Pagination.has_next_page?(state)
      refute Pagination.has_prev_page?(state)

      page1_state = Pagination.update_page_state(state, 1)
      assert Pagination.has_next_page?(page1_state)
      assert Pagination.has_prev_page?(page1_state)

      last_state = Pagination.update_page_state(state, 2)
      refute Pagination.has_next_page?(last_state)
      assert Pagination.has_prev_page?(last_state)
    end

    test "next_page/1 advances to next page" do
      state = init_state(%{options: many_options(25), page_size: 10})

      updated = Pagination.next_page(state)

      assert Pagination.get_current_page(updated) == 1
    end

    test "next_page/1 does nothing on last page" do
      state = init_state(%{options: many_options(25), page_size: 10})
      last = Pagination.update_page_state(state, 2)

      unchanged = Pagination.next_page(last)

      assert unchanged.focused_index == last.focused_index
    end

    test "prev_page/1 goes to previous page" do
      state = init_state(%{options: many_options(25), page_size: 10})
      page1 = Pagination.update_page_state(state, 1)

      updated = Pagination.prev_page(page1)

      assert Pagination.get_current_page(updated) == 0
    end

    test "prev_page/1 does nothing on first page" do
      state = init_state(%{options: many_options(25), page_size: 10})

      unchanged = Pagination.prev_page(state)

      assert unchanged.focused_index == state.focused_index
    end

    test "get_page_options/1 returns correct slice" do
      state = init_state(%{options: many_options(25), visible_items: 5, page_size: 5})

      page0 = Pagination.get_page_options(state)
      assert length(page0) == 5
      assert Enum.at(page0, 0) == {"Item 1", :item_1}

      page1_state = Pagination.update_page_state(state, 1)
      page1 = Pagination.get_page_options(page1_state)
      assert length(page1) == 5
      assert Enum.at(page1, 0) == {"Item 6", :item_6}
    end
  end
end
