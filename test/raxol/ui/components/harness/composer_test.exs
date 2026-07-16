defmodule Raxol.UI.Components.Harness.ComposerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Composer
  alias Raxol.UI.TextMeasure

  defp default_context, do: %{theme: %{}, available_width: 40}

  # Types text one grapheme at a time via real :key events -- the path a
  # user's keystrokes actually take (the Composer intercepts printable
  # characters and routes them through the safe insertion path; see the
  # module docs).
  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn char, acc ->
      {new_state, _cmds} = press(acc, char)
      new_state
    end)
  end

  defp press(state, key, modifiers \\ []) do
    Composer.handle_event(
      Event.key_event(key, :pressed, modifiers),
      state,
      default_context()
    )
  end

  defp paste(state, text) do
    event = %Event{type: :paste, data: %{text: text}}
    Composer.handle_event(event, state, default_context())
  end

  defp hint_of(rendered),
    do: Enum.find(rendered.children, &(&1[:id] == "composer-hint"))

  describe "init/1" do
    test "initializes with empty value, no history, no queued steer" do
      {:ok, state} = Composer.init(id: :composer1)
      assert Composer.value(state) == ""
      assert Composer.history(state) == []
      assert state.queued_steer == nil
    end

    test "accepts an initial value and queued_steer" do
      {:ok, state} =
        Composer.init(
          id: :composer2,
          value: "draft",
          queued_steer: %{text: "steer this", queued_at: 123}
        )

      assert Composer.value(state) == "draft"
      assert state.queued_steer.text == "steer this"
    end
  end

  describe "typing + submit" do
    test "Enter on single-line non-empty content submits and clears the buffer" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hello")

      {new_state, cmds} = press(state, :enter)

      assert cmds == [{:component_event, :c, {:submit, "hello"}}]
      assert Composer.value(new_state) == ""
    end

    test "Enter on empty content is a no-op" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, cmds} = press(state, :enter)

      assert cmds == []
      assert Composer.value(new_state) == ""
    end

    test "Enter on whitespace-only content is a no-op" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "   ")

      {new_state, cmds} = press(state, :enter)

      assert cmds == []
      assert Composer.value(new_state) == "   "
    end

    test "Shift+Enter inserts a newline instead of submitting" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "line one")

      {new_state, cmds} = press(state, :enter, [:shift])

      assert cmds == []
      assert Composer.value(new_state) == "line one\n"
    end

    test "Alt+Enter inserts a newline instead of submitting" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "line one")

      {new_state, cmds} = press(state, :enter, [:alt])

      assert cmds == []
      assert Composer.value(new_state) == "line one\n"
    end

    test "plain Enter continues (inserts newline) once the buffer already spans lines" do
      {:ok, state} = Composer.init(id: :c)
      {state, []} = paste(state, "line one\nline two")

      {new_state, cmds} = press(state, :enter)

      assert cmds == []
      assert Composer.value(new_state) == "line one\nline two\n"
    end

    test "force_submit bypasses the single-line gate" do
      {:ok, state} = Composer.init(id: :c)
      {state, []} = paste(state, "line one\nline two")

      {new_state, cmds} = Composer.force_submit(state)

      assert cmds == [{:component_event, :c, {:submit, "line one\nline two"}}]
      assert Composer.value(new_state) == ""
    end
  end

  describe "bracketed paste" do
    test "multiline paste lands verbatim as content and never submits" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, cmds} = paste(state, "first\nsecond\nthird")

      assert cmds == []
      assert Composer.value(new_state) == "first\nsecond\nthird"
    end

    test "a plain Enter after a multiline paste continues rather than submits" do
      {:ok, state} = Composer.init(id: :c)
      {state, []} = paste(state, "first\nsecond")

      {new_state, cmds} = press(state, :enter)

      assert cmds == []
      assert Composer.value(new_state) == "first\nsecond\n"
    end

    test "paste is a single edit even when it contains many newlines" do
      {:ok, state} = Composer.init(id: :c)
      big_paste = Enum.map_join(1..50, "\n", &"line #{&1}")

      {new_state, cmds} = paste(state, big_paste)

      assert cmds == []
      assert Composer.value(new_state) == big_paste
    end
  end

  describe "history recall" do
    test "round-trips through submitted values with Up/Down" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "first")
      {state, _} = press(state, :enter)
      state = type(state, "second")
      {state, _} = press(state, :enter)

      assert Composer.history(state) == ["second", "first"]

      # Up at the (empty) first line recalls the most recent submission.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "second"

      # Up again walks further back.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "first"

      # Down walks forward again.
      {state, []} = press(state, :down)
      assert Composer.value(state) == "second"

      # Down at the bottom restores the saved (empty) draft.
      {state, []} = press(state, :down)
      assert Composer.value(state) == ""
    end

    test "saves the in-progress draft while browsing history" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "submitted")
      {state, _} = press(state, :enter)
      state = type(state, "unsent draft")

      {state, []} = press(state, :up)
      assert Composer.value(state) == "submitted"

      {state, []} = press(state, :down)
      assert Composer.value(state) == "unsent draft"
    end

    test "history is bounded" do
      {:ok, state} = Composer.init(id: :c, max_history: 3)

      state =
        Enum.reduce(1..5, state, fn n, acc ->
          acc = type(acc, "msg#{n}")
          {acc, _} = press(acc, :enter)
          acc
        end)

      assert Composer.history(state) == ["msg5", "msg4", "msg3"]
    end

    test "Up does nothing when there is no history" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, cmds} = press(state, :up)

      assert cmds == []
      assert Composer.value(new_state) == ""
    end
  end

  describe "queued-steer banner" do
    test "renders a distinct dim banner above the prompt when set" do
      {:ok, state} =
        Composer.init(id: :c, queued_steer: %{text: "hold on", queued_at: 1})

      rendered = Composer.render(state, %{theme: %{}, available_width: 80})

      assert rendered.type == :column
      assert rendered.gap == 0

      banner = hd(rendered.children)
      assert banner.type == :text
      assert banner.style[:dim] == true
      assert banner.content =~ "steer queued for next boundary"
      assert banner.content =~ "hold on"
    end

    test "is absent when queued_steer is nil" do
      {:ok, state} = Composer.init(id: :c, value: "draft")

      rendered = Composer.render(state, default_context())

      assert length(rendered.children) == 1
      assert rendered.type == :column
      assert rendered.gap == 0
    end

    test "truncates to the available width without splitting a double-width character" do
      {:ok, state} =
        Composer.init(
          id: :c,
          queued_steer: %{text: String.duplicate("中", 20), queued_at: 1}
        )

      rendered = Composer.render(state, %{theme: %{}, available_width: 10})
      banner = hd(rendered.children)

      assert TextMeasure.display_width(banner.content) <= 10
    end
  end

  describe "backslash continuation" do
    test "a line ending in backslash + Enter consumes the backslash and inserts a newline" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "foo\\")

      {new_state, cmds} = press(state, :enter)

      assert cmds == []
      assert Composer.value(new_state) == "foo\n"
    end

    test "typing continues on the new line after a continuation" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "foo\\")
      {state, []} = press(state, :enter)
      state = type(state, "bar")

      assert Composer.value(state) == "foo\nbar"
    end

    test "continuation can create the FIRST newline and Enter then submits nothing until forced" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "foo\\")
      {state, []} = press(state, :enter)

      # Buffer is now multiline: plain Enter continues, never submits.
      {state, cmds} = press(state, :enter)
      assert cmds == []

      {_state, cmds} = Composer.force_submit(state)
      assert [{:component_event, :c, {:submit, _text}}] = cmds
    end

    test "an escaped trailing backslash (\\\\) submits with a single backslash retained" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "foo\\\\")

      {new_state, cmds} = press(state, :enter)

      assert cmds == [{:component_event, :c, {:submit, "foo\\"}}]
      assert Composer.value(new_state) == ""
    end

    test "force_submit ignores the escape rule and submits verbatim" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "foo\\")

      {_new_state, cmds} = Composer.force_submit(state)

      assert cmds == [{:component_event, :c, {:submit, "foo\\"}}]
    end
  end

  describe "first-focus hint" do
    test "appears when focused with an empty buffer and no history" do
      {:ok, state} = Composer.init(id: :c)

      hint = hint_of(Composer.render(state, default_context()))

      assert hint != nil
      assert hint.style[:dim] == true
      assert hint.content =~ "\\ continue"
      assert hint.content =~ "↵ submit"
    end

    test "disappears once the buffer has content" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "x")

      assert hint_of(Composer.render(state, default_context())) == nil
    end

    test "disappears once history exists" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "first")
      {state, _} = press(state, :enter)

      assert hint_of(Composer.render(state, default_context())) == nil
    end

    test "disappears when the input is not focused" do
      {:ok, state} = Composer.init(id: :c, focused: false)

      assert hint_of(Composer.render(state, default_context())) == nil
    end
  end

  describe "unicode content" do
    test "CJK and emoji paste round-trips without corruption" do
      {:ok, state} = Composer.init(id: :c)
      text = "héllo 世界 🎉 done"

      {new_state, []} = paste(state, text)

      assert Composer.value(new_state) == text
    end

    test "set_value/2 round-trips unicode content" do
      {:ok, state} = Composer.init(id: :c)
      text = "日本語のテスト 🚀"

      new_state = Composer.set_value(state, text)

      assert Composer.value(new_state) == text
    end
  end

  describe "resize safety" do
    test "render derives width from context[:available_width], not stored state" do
      {:ok, state} = Composer.init(id: :c, value: "hello world")

      narrow = Composer.render(state, %{theme: %{}, available_width: 5})
      wide = Composer.render(state, %{theme: %{}, available_width: 80})

      [input_narrow] = narrow.children
      [input_wide] = wide.children

      assert length(input_narrow.children) >= length(input_wide.children)
    end
  end

  describe "typing via real key events" do
    test "single-character :key events insert the characters" do
      {:ok, state} = Composer.init(id: :c)

      state =
        Enum.reduce(String.graphemes("hi there"), state, fn char, acc ->
          {new_state, _cmds} = press(acc, char)
          new_state
        end)

      assert Composer.value(state) == "hi there"
    end

    test "typed characters then Enter submit the typed text" do
      {:ok, state} = Composer.init(id: :c)

      state =
        Enum.reduce(String.graphemes("ok"), state, fn char, acc ->
          {new_state, _cmds} = press(acc, char)
          new_state
        end)

      {new_state, cmds} = press(state, :enter)

      assert cmds == [{:component_event, :c, {:submit, "ok"}}]
      assert Composer.value(new_state) == ""
    end

    test "typing a multi-codepoint grapheme (emoji) via a :key event inserts it intact" do
      {:ok, state} = Composer.init(id: :c)

      {state, _cmds} = press(state, "🎉")

      assert Composer.value(state) == "🎉"
    end

    test "typing a shifted character keeps working" do
      {:ok, state} = Composer.init(id: :c)

      {state, _cmds} = press(state, "A", [:shift])

      assert Composer.value(state) == "A"
    end
  end

  describe "history reset on submit" do
    test "submitting while browsing history resets history_index and draft" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "first")
      {state, _} = press(state, :enter)
      state = type(state, "unsent draft")

      # Browse into history: index 0, draft saved.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "first"
      assert state.history_index == 0
      assert state.draft == "unsent draft"

      # Submit the recalled entry mid-browse.
      {state, cmds} = press(state, :enter)
      assert cmds == [{:component_event, :c, {:submit, "first"}}]
      assert state.history_index == nil
      assert state.draft == nil
      assert Composer.history(state) == ["first", "first"]

      # Subsequent Up starts from the newest entry again, not a stale index.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "first"
      assert state.history_index == 0
    end
  end

  describe "update/2 prop sync" do
    test "setting the :value prop updates the embedded input (no desync)" do
      {:ok, state} = Composer.init(id: :c, value: "old")

      {new_state, []} = Composer.update(%{value: "new content"}, state)

      assert Composer.value(new_state) == "new content"
      # Rendered lines follow the new value too, not a stale cache.
      assert new_state.mli.lines == ["new content"]
    end

    test "setting :placeholder and :focused props reaches the embedded input" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, []} =
        Composer.update(%{placeholder: "type here", focused: false}, state)

      assert new_state.mli.placeholder == "type here"
      assert new_state.mli.focused == false
    end

    test "non-mli props still merge onto the composer state" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, []} =
        Composer.update(%{queued_steer: %{text: "s", queued_at: 1}}, state)

      assert new_state.queued_steer.text == "s"
      # No :value key ever lands on the outer composer map.
      refute Map.has_key?(new_state, :value)
    end
  end

  describe "typing with an active selection" do
    test "a typed character replaces the selection and clears it" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hello")

      state = %{
        state
        | mli: %{state.mli | selection_start: {0, 0}, selection_end: {0, 5}}
      }

      {new_state, _cmds} = press(state, "x")

      assert Composer.value(new_state) == "x"
      assert new_state.mli.selection_start == nil
      assert new_state.mli.selection_end == nil
    end
  end

  describe "handle_event/3 passthrough" do
    test "unrelated events are delegated to the wrapped MultiLineInput" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "abc")

      {new_state, _cmds} = press(state, :home)

      assert new_state.mli.cursor_pos == {0, 0}
    end
  end

  # -- T27 review round: real driver shapes, not just Event.key_event/3 --
  #
  # Before this round, `handle_event/3` matched key events by pattern
  # (`%{key: :enter, modifiers: modifiers}`), a shape that ONLY exists on
  # `Event.key_event/3` (the test API). The two real driver shapes --
  # `event_translator.ex`'s (native termbox) and `input_parser.ex`'s (raw
  # ANSI) -- have no `:modifiers` key at all, so that pattern never
  # matched a real keypress: Enter never submitted, and printable
  # characters never inserted outside of tests. These tests drive the
  # REAL translator/parser functions (not hand-built maps) to prove the
  # fix reaches actual terminal input, not just the test API.
  describe "real driver shapes (event_translator.ex / input_parser.ex)" do
    alias Raxol.Terminal.ANSI.InputParser
    alias Raxol.Terminal.Driver.EventTranslator

    defp translator_key_event(key_code, char_code \\ 0, mod_code \\ 0) do
      {:ok, event} =
        EventTranslator.translate(%{
          type: :key,
          key: key_code,
          char: char_code,
          mod: mod_code
        })

      event
    end

    defp parser_key_event(binary) do
      [event] = InputParser.parse(binary)
      event
    end

    test "a real termbox Enter (TB_KEY_ENTER) and a real ANSI Enter (CR byte) both submit" do
      {:ok, translator_state} = Composer.init(id: :c)
      translator_state = type(translator_state, "hello")

      {:ok, parser_state} = Composer.init(id: :c)
      parser_state = type(parser_state, "hello")

      {_translator_new, translator_cmds} =
        Composer.handle_event(
          translator_key_event(13),
          translator_state,
          default_context()
        )

      {_parser_new, parser_cmds} =
        Composer.handle_event(
          parser_key_event(<<13>>),
          parser_state,
          default_context()
        )

      assert translator_cmds == [{:component_event, :c, {:submit, "hello"}}]
      assert translator_cmds == parser_cmds
    end

    test "a native termbox printable char event inserts (was dead code before T27)" do
      {:ok, state} = Composer.init(id: :c)

      {state, _cmds} =
        Composer.handle_event(
          translator_key_event(0, ?h),
          state,
          default_context()
        )

      {state, _cmds} =
        Composer.handle_event(
          translator_key_event(0, ?i),
          state,
          default_context()
        )

      assert Composer.value(state) == "hi"
    end

    test "a raw-ANSI printable char event inserts" do
      {:ok, state} = Composer.init(id: :c)

      {state, _cmds} =
        Composer.handle_event(parser_key_event("x"), state, default_context())

      assert Composer.value(state) == "x"
    end

    test "a native termbox Ctrl+char event does not insert (it's a shortcut, delegated onward)" do
      {:ok, state} = Composer.init(id: :c)

      {new_state, _cmds} =
        Composer.handle_event(
          # mod bit 2 == ctrl, per event_translator.ex
          translator_key_event(0, ?a, 2),
          state,
          default_context()
        )

      refute Composer.value(new_state) == "a"
    end

    test "Alt+Enter from a real termbox event inserts a newline, not a submit" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "line one")

      {new_state, cmds} =
        Composer.handle_event(
          # mod bit 4 == alt, per event_translator.ex
          translator_key_event(13, 0, 4),
          state,
          default_context()
        )

      assert cmds == []
      assert Composer.value(new_state) == "line one\n"
    end
  end
end
