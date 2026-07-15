defmodule Raxol.UI.Components.Harness.PickerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Picker

  defp default_context, do: %{theme: %{}, available_width: 60}

  defp press(state, key, modifiers \\ []) do
    Picker.handle_event(
      Event.key_event(key, :pressed, modifiers),
      state,
      default_context()
    )
  end

  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn char, acc ->
      {new_state, []} = press(acc, char)
      new_state
    end)
  end

  defp init!(props), do: elem(Picker.init(props), 1)

  describe "init/1" do
    test "starts with an empty query and every item ranked in original order" do
      state = init!(items: ["charlie", "alpha", "bravo"], key_fn: & &1)

      assert Picker.query(state) == ""

      assert Enum.map(Picker.ranked(state), & &1.item) == [
               "charlie",
               "alpha",
               "bravo"
             ]

      assert Picker.selected_item(state) == "charlie"
    end

    test "defaults on_select/on_cancel and starts with no preview when preview_fn absent" do
      state = init!(items: ["a"], key_fn: & &1)

      assert state.on_select == :select
      assert state.on_cancel == :cancel
      assert Picker.preview(state) == :none
      assert state.preview_task == nil
    end

    test "empty items list is safe (no crash, no selection)" do
      state = init!(items: [], key_fn: & &1)

      assert Picker.selected_item(state) == nil
      assert Picker.ranked(state) == []
    end
  end

  describe "type-to-filter" do
    test "typing narrows the ranked list and resets the cursor to the top match" do
      state = init!(items: ["hello", "help", "world"], key_fn: & &1)

      state = type(state, "hel")

      assert Enum.map(Picker.ranked(state), & &1.item) == ["hello", "help"]
      assert state.cursor == 0
    end

    test "backspace removes the last grapheme and re-filters" do
      state = init!(items: ["hello", "world"], key_fn: & &1)
      state = type(state, "hex")

      assert Picker.ranked(state) == []

      {state, []} = press(state, :backspace)

      assert Picker.query(state) == "he"
      assert Enum.map(Picker.ranked(state), & &1.item) == ["hello"]
    end

    test "backspace on an empty query is a no-op" do
      state = init!(items: ["a"], key_fn: & &1)

      {state, []} = press(state, :backspace)

      assert Picker.query(state) == ""
    end
  end

  # The native terminal driver paths do NOT emit a `modifiers:` list:
  # event_translator.ex emits boolean shift:/ctrl:/alt: fields, and
  # input_parser.ex emits a bare %{key: char} (no modifier fields at all
  # for an unmodified printable). Only Event.key_event/3 (the test
  # helper used by `press/3` above) sets `modifiers: []`. A printable
  # clause that *requires* a `modifiers:` field is therefore dead on the
  # real terminal -- the systemic input-shape gap. These drive the raw
  # driver-shaped events directly.
  describe "type-to-filter across real driver input shapes (regression)" do
    defp raw_key(state, data) do
      Picker.handle_event(
        %Event{type: :key, data: data},
        state,
        default_context()
      )
    end

    test "event_translator-shaped printable (boolean modifier fields) inserts into the query" do
      # "widget" has no "a" -- an unambiguous filter for the query "a".
      state = init!(items: ["alpha", "widget"], key_fn: & &1)

      {state, []} =
        raw_key(state, %{key: "a", shift: false, ctrl: false, alt: false})

      assert Picker.query(state) == "a"
      assert Enum.map(Picker.ranked(state), & &1.item) == ["alpha"]
    end

    test "input_parser-shaped printable (bare key, no modifier fields) inserts into the query" do
      state = init!(items: ["alpha", "widget"], key_fn: & &1)

      {state, []} = raw_key(state, %{key: "a"})

      assert Picker.query(state) == "a"
      assert Enum.map(Picker.ranked(state), & &1.item) == ["alpha"]
    end

    test "shift-only capital letter (boolean shape) is still text" do
      state = init!(items: ["Alpha", "beta"], key_fn: & &1)

      {state, []} =
        raw_key(state, %{key: "A", shift: true, ctrl: false, alt: false})

      assert Picker.query(state) == "A"
    end

    test "a ctrl-modified printable is a shortcut, not text (boolean shape)" do
      state = init!(items: ["alpha"], key_fn: & &1)

      {state, []} =
        raw_key(state, %{key: "a", shift: false, ctrl: true, alt: false})

      assert Picker.query(state) == ""
    end

    test "an alt-modified printable is a shortcut, not text (modifiers-list shape)" do
      state = init!(items: ["alpha"], key_fn: & &1)

      {state, []} = raw_key(state, %{key: "a", modifiers: [:alt]})

      assert Picker.query(state) == ""
    end
  end

  describe "selection movement" do
    test "down moves the cursor to the next item" do
      state = init!(items: ["a", "b", "c"], key_fn: & &1)

      {state, []} = press(state, :down)

      assert Picker.selected_item(state) == "b"
    end

    test "up from the top clamps at the first item" do
      state = init!(items: ["a", "b", "c"], key_fn: & &1)

      {state, []} = press(state, :up)

      assert Picker.selected_item(state) == "a"
      assert state.cursor == 0
    end

    test "down from the bottom clamps at the last item" do
      state = init!(items: ["a", "b"], key_fn: & &1)

      {state, []} = press(state, :down)
      {state, []} = press(state, :down)
      {state, []} = press(state, :down)

      assert Picker.selected_item(state) == "b"
    end

    test "movement is windowed: scroll_top advances once the cursor passes visible_height" do
      items = for i <- 1..20, do: "item-#{i}"
      state = init!(items: items, key_fn: & &1, visible_height: 5)

      state =
        Enum.reduce(1..6, state, fn _i, acc -> elem(press(acc, :down), 0) end)

      assert Picker.selected_item(state) == "item-7"
      assert state.scroll_top > 0
    end

    test "up/down on an empty ranked list is a no-op" do
      state = init!(items: [], key_fn: & &1)

      {state, []} = press(state, :down)
      {state, []} = press(state, :up)

      assert Picker.selected_item(state) == nil
    end
  end

  describe "select / cancel messages" do
    test "Enter emits on_select with the currently selected item" do
      state = init!(items: ["a", "b"], key_fn: & &1, id: :p, on_select: :chosen)

      {state, []} = press(state, :down)
      {_state, cmds} = press(state, :enter)

      assert cmds == [{:component_event, :p, {:chosen, "b"}}]
    end

    test "Enter on an empty ranked list is a no-op" do
      state = init!(items: [], key_fn: & &1, id: :p)

      {_state, cmds} = press(state, :enter)

      assert cmds == []
    end

    test "Escape emits on_cancel" do
      state = init!(items: ["a"], key_fn: & &1, id: :p, on_cancel: :dismissed)

      {_state, cmds} = press(state, :escape)

      assert cmds == [{:component_event, :p, :dismissed}]
    end

    test "Escape cancels any in-flight preview task" do
      state =
        init!(
          items: ["a"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview: " <> item} end
        )

      assert %Task{} = state.preview_task
      task_pid = state.preview_task.pid

      {state, _cmds} = press(state, :escape)

      assert state.preview_task == nil
      assert state.preview_ref == nil
      refute Process.alive?(task_pid)
    end
  end

  describe "preview: renders for the current selection" do
    test "preview_fn result lands in state once its task's message is forwarded to update/2" do
      state =
        init!(
          items: ["alpha", "beta"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview of " <> item} end
        )

      assert Picker.preview(state) == :loading
      ref = state.preview_ref

      {state, []} =
        receive do
          {^ref, result} -> Picker.update({ref, result}, state)
        end

      assert Picker.preview(state) == {:ok, "preview of alpha"}
      assert state.preview_task == nil
      assert state.preview_ref == nil
    end

    test "a preview_fn that raises is rescued and rendered as an error result" do
      state =
        init!(
          items: ["alpha"],
          key_fn: & &1,
          preview_fn: fn _item -> raise "boom" end
        )

      ref = state.preview_ref

      {state, []} =
        receive do
          {^ref, result} -> Picker.update({ref, result}, state)
        end

      assert {:error, %RuntimeError{}} = Picker.preview(state)
    end

    test "an abnormal task exit (DOWN) for the current ref renders as an error" do
      state =
        init!(
          items: ["alpha"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview of " <> item} end
        )

      ref = state.preview_ref

      {state, []} =
        Picker.update({:DOWN, ref, :process, self(), :killed}, state)

      assert Picker.preview(state) == {:error, :killed}
    end
  end

  describe "stale-preview cancellation (fzf#3134 lesson)" do
    test "a superseded selection's late task result never lands in state" do
      state =
        init!(
          items: ["alpha", "beta"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview of " <> item} end
        )

      stale_ref = state.preview_ref
      stale_task_pid = state.preview_task.pid

      # Move the selection -- this cancels alpha's task (real Task.shutdown)
      # and starts a fresh one for beta with a NEW ref.
      {state, []} = press(state, :down)

      assert Picker.selected_item(state) == "beta"
      refute Process.alive?(stale_task_pid)
      fresh_ref = state.preview_ref
      assert fresh_ref != stale_ref
      assert Picker.preview(state) == :loading

      # Simulate alpha's result arriving anyway (the fzf#3134 race: a
      # result computed just before shutdown lands in the mailbox
      # regardless). ref-matching must drop it untouched.
      {state, []} = Picker.update({stale_ref, {:ok, "preview of alpha"}}, state)

      assert Picker.preview(state) == :loading
      assert state.preview_ref == fresh_ref

      # The fresh (correct) result for beta still lands normally.
      assert_receive {^fresh_ref, {:ok, "preview of beta"}}
      {state, []} = Picker.update({fresh_ref, {:ok, "preview of beta"}}, state)

      assert Picker.preview(state) == {:ok, "preview of beta"}
    end

    test "a stale DOWN message is dropped the same way" do
      state =
        init!(
          items: ["alpha", "beta"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview of " <> item} end
        )

      stale_ref = state.preview_ref
      {state, []} = press(state, :down)
      fresh_ref = state.preview_ref

      {state, []} =
        Picker.update({:DOWN, stale_ref, :process, self(), :killed}, state)

      assert Picker.preview(state) == :loading
      assert state.preview_ref == fresh_ref
    end
  end

  describe "typing while a preview is in flight" do
    test "changing the query cancels the previous selection's preview and starts a new one" do
      state =
        init!(
          items: ["hello", "help", "world"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview of " <> item} end
        )

      first_ref = state.preview_ref
      first_task_pid = state.preview_task.pid

      state = type(state, "wor")

      assert Picker.selected_item(state) == "world"
      refute Process.alive?(first_task_pid)
      assert state.preview_ref != first_ref
      assert Picker.preview(state) == :loading
    end
  end

  describe "render/2" do
    test "renders prompt, list, and preview pane without crashing" do
      state =
        init!(
          items: ["hello", "help", "world"],
          key_fn: & &1,
          preview_fn: fn item -> {:ok, "preview: " <> item} end
        )

      rendered = Picker.render(state, default_context())

      assert %{type: :column, children: [prompt, body]} = rendered
      assert %{type: :text, content: content} = prompt
      assert content =~ ">"

      assert %{type: :row, children: [list, preview]} = body
      assert %{id: "picker-list", type: :column} = list
      assert %{id: "picker-preview", type: :column} = preview
    end

    test "renders just the list (no preview pane) when preview_fn is absent" do
      state = init!(items: ["hello", "help"], key_fn: & &1)

      rendered = Picker.render(state, default_context())

      assert %{type: :column, children: [_prompt, body]} = rendered
      assert %{id: "picker-list", type: :column} = body
    end

    test "match-position highlighting: matched graphemes render bold, selected row gets bg" do
      state = init!(items: ["hello", "help"], key_fn: & &1)
      state = type(state, "hl")

      %{
        type: :column,
        children: [_prompt, %{id: "picker-list", children: [first_row, _]}]
      } =
        Picker.render(state, default_context())

      # "hello": h(0) and l(2) match "hl" as a subsequence -- both bold;
      # the selected row's segments also carry the selection background.
      assert %{type: :row, children: segments, style: %{bg: :blue}} = first_row
      contents = Enum.map(segments, & &1.content)
      assert contents == ["h", "e", "l", "lo"]

      bold_segments = Enum.filter(segments, &(&1.style[:bold] == true))
      assert Enum.map(bold_segments, & &1.content) == ["h", "l"]
      assert Enum.all?(segments, &(&1.style[:bg] == :blue))
    end

    test "truncates long labels to the available width with an ellipsis" do
      state = init!(items: [String.duplicate("x", 100)], key_fn: & &1)

      %{children: [_prompt, %{children: [row]}]} =
        Picker.render(state, %{available_width: 10})

      full_content = row.children |> Enum.map_join(& &1.content)
      assert String.ends_with?(full_content, "…")
      assert String.length(full_content) <= 10
    end

    test "an item whose key_fn yields \"\" still renders a visible, selectable row" do
      state = init!(items: [%{name: ""}], key_fn: & &1.name)

      %{children: [_prompt, %{children: [row]}]} =
        Picker.render(state, default_context())

      assert %{type: :row, children: children} = row
      assert length(children) >= 1
      assert Enum.any?(children, &(&1.content != ""))
    end
  end

  describe "update/2 guards against mis-routed structs and unknown props" do
    test "an %Event{} that misses every handle_event/3 clause is a no-op through update/2" do
      state = init!(items: ["a", "b"], key_fn: & &1)

      {new_state, cmds} =
        Picker.update(Event.key_event("a", :pressed, []), state)

      assert new_state == state
      assert cmds == []
    end

    test "an arbitrary map with an internal-state key does not bypass the cursor clamp" do
      state = init!(items: ["a", "b", "c"], key_fn: & &1)

      {new_state, cmds} = Picker.update(%{cursor: 99}, state)

      assert new_state == state
      assert cmds == []
    end

    test "a legitimate prop update still applies through the allowlist" do
      state = init!(items: ["a"], key_fn: & &1, placeholder: "old")

      {new_state, []} = Picker.update(%{placeholder: "new"}, state)

      assert new_state.placeholder == "new"
    end
  end
end
