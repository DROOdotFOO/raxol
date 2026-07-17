defmodule Raxol.UI.Components.Harness.ComposerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Surface.ViewText
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

  describe "no hint line (V ruling: the hint carried no information)" do
    test "an empty focused composer renders no composer-hint node" do
      {:ok, state} = Composer.init(id: :c)

      assert hint_of(Composer.render(state, default_context())) == nil
    end
  end

  describe "trailing-space draft (the spacebar park defect)" do
    # The defect: word-wrap (`TextHelper.split_into_lines/3`) trims each
    # wrapped line, so a draft of "ab " produced `lines: ["ab"]` and
    # `edit_point/2` -- which measured `List.last(mli.lines)` -- reported
    # the same column as for "ab". A space is invisible; the parked
    # terminal cursor is the ONLY visible feedback for typing one, so
    # the frame looked frozen until the next visible character arrived.
    test "edit_point advances past a trailing space typed into the draft" do
      {:ok, state} = Composer.init(%{id: :c, width: 40, focused: true})
      state = type(state, "ab ")

      assert Composer.edit_point(state, 40) == {0, 4}
    end

    test "each additional trailing space advances the park column again" do
      {:ok, state} = Composer.init(%{id: :c, width: 40, focused: true})
      state = type(state, "ab")
      assert Composer.edit_point(state, 40) == {0, 3}

      state = type(state, " ")
      assert Composer.edit_point(state, 40) == {0, 4}

      state = type(state, " ")
      assert Composer.edit_point(state, 40) == {0, 5}
    end

    test "the park column never exceeds the available width" do
      {:ok, state} = Composer.init(%{id: :c, width: 10, focused: true})
      state = Composer.set_value(state, "abcdef    ")

      {_row, col} = Composer.edit_point(state, 10)
      assert col <= 10
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

    # -- control keys over the real wires (the live-demo defect) --------
    #
    # T27 fixed Enter and printable chars INSIDE the Composer, but every
    # other special key (:backspace/:delete/arrows/home/end) still
    # delegates the raw event onward to MultiLineInput -- whose
    # EventHandler matched only `%{key: _, modifiers: _}`, the
    # `Event.key_event/3` test-API shape. Neither real driver shape
    # carries `:modifiers`, so backspace and arrow keys were dead on a
    # real terminal (harness live/fixture demos) while passing every
    # test-API-shaped test. These drive the REAL parser/translator
    # emitters through the delegation path.

    test "a real ANSI backspace (DEL byte) deletes the char before the cursor" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hi")

      {new_state, _cmds} =
        Composer.handle_event(
          parser_key_event(<<127>>),
          state,
          default_context()
        )

      assert Composer.value(new_state) == "h"
    end

    test "a real termbox backspace (TB key 127) deletes too" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hi")

      {new_state, _cmds} =
        Composer.handle_event(
          translator_key_event(127),
          state,
          default_context()
        )

      assert Composer.value(new_state) == "h"
    end

    test "a real ANSI left-arrow moves the cursor (next insert lands mid-draft)" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "ab")

      {state, _cmds} =
        Composer.handle_event(
          # CSI D -- left arrow on the raw-ANSI wire
          parser_key_event("\e[D"),
          state,
          default_context()
        )

      {state, _cmds} =
        Composer.handle_event(parser_key_event("X"), state, default_context())

      assert Composer.value(state) == "aXb"
    end

    test "a real ANSI delete (CSI 3~) removes the char under the cursor" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "ab")

      {state, _cmds} =
        Composer.handle_event(
          parser_key_event("\e[D"),
          state,
          default_context()
        )

      {state, _cmds} =
        Composer.handle_event(
          parser_key_event("\e[3~"),
          state,
          default_context()
        )

      assert Composer.value(state) == "a"
    end

    test "a real ANSI Home (CSI H) moves the cursor to the line start" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "ab")

      {state, _cmds} =
        Composer.handle_event(
          parser_key_event("\e[H"),
          state,
          default_context()
        )

      {state, _cmds} =
        Composer.handle_event(parser_key_event("X"), state, default_context())

      assert Composer.value(state) == "Xab"
    end
  end

  # -- the logical/visual split (V's field repro: leading-space drafts) --
  #
  # The disease being pinned: MultiLineInput keeps two mutually-corrupting
  # representations. Edit ops treat `state.lines` as truth and re-derive
  # `value = Enum.join(lines, "\n")` (`TextHelper.with_lines/3`), while
  # `ensure_cursor_visible/1` re-derives `lines` from `value` through the
  # DISPLAY word-wrapper -- whose `wrap_line_by_word` drops the
  # leading-space run (`String.split(line, " ")` discards the empty first
  # word) and `String.trim`s every produced line. After the first rewrap
  # (any backspace/arrow/enter), `lines` is a trimmed display artifact;
  # the next edit consults it at the LOGICAL cursor col -- shifted right
  # by the eaten leading run -- and joins it back into `value`, deleting
  # whitespace from the logical draft. Observed corruption before the fix:
  # " ab" + Backspace + Backspace left "a" (deleted the space, kept the
  # 'a' -- "removes the second-to-last char instead of the last one").
  #
  # The contract these tests pin: the LOGICAL draft (`mli.value`) plus the
  # logical cursor are the single source of truth; every visual artifact
  # (wrapped display rows, park column) is derived ONE-WAY from them and
  # never feeds back into an edit.

  defp display(state, width) do
    ViewText.lines(
      Composer.render(state, %{theme: %{}, available_width: width}),
      width,
      :plain
    )
  end

  describe "leading-whitespace drafts (V's field repro)" do
    test "backspace on ' ab' deletes the 'b' -- draft becomes ' a'" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " ab")

      {state, _cmds} = press(state, :backspace)

      assert Composer.value(state) == " a"
    end

    test "the SECOND backspace deletes the 'a', never the leading space" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " ab")

      {state, _cmds} = press(state, :backspace)
      {state, _cmds} = press(state, :backspace)

      assert Composer.value(state) == " "

      {state, _cmds} = press(state, :backspace)
      assert Composer.value(state) == ""
    end

    test "the display keeps the leading space after a rewrapping edit" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " ab")

      {state, _cmds} = press(state, :backspace)

      # The draft row must show the logical draft (cursor cell padding
      # aside), not a trimmed artifact ("a").
      assert [row] = display(state, 40)
      assert String.starts_with?(row, " a")
    end

    test "edit_point counts the leading space after a rewrapping edit" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " ab")

      {state, _cmds} = press(state, :backspace)

      # Draft " a", cursor at its end: 2 cells -> 1-based col 3. The
      # pre-fix defect reported {0, 2} (the trimmed line "a" measured).
      assert Composer.edit_point(state, 40) == {0, 3}
    end

    test "mid-draft insert after Left lands at the logical cursor" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " ab")

      {state, _cmds} = press(state, :left)
      {state, _cmds} = press(state, "x")

      # Pre-fix this produced "abx": the rewrap on Left dropped the
      # leading space and the insert landed off-by-the-leading-run.
      assert Composer.value(state) == " axb"
    end

    test "interior whitespace runs survive an edit cycle" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " a  b")

      {state, _cmds} = press(state, :backspace)
      assert Composer.value(state) == " a  "

      {state, _cmds} = press(state, "c")
      assert Composer.value(state) == " a  c"
    end
  end

  describe "arrow navigation: grapheme steps and logical boundaries" do
    test "Left steps over a wide grapheme (CJK) as one cursor step" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "你好")

      {state, _cmds} = press(state, :left)
      {state, _cmds} = press(state, "x")

      assert Composer.value(state) == "你x好"
    end

    test "Left/Right round-trip returns to the end of the draft" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "abc")

      {state, _cmds} = press(state, :left)
      {state, _cmds} = press(state, :left)
      {state, _cmds} = press(state, :right)
      {state, _cmds} = press(state, :right)
      {state, _cmds} = press(state, "!")

      assert Composer.value(state) == "abc!"
    end

    test "Home then End bracket the logical line, leading space included" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, " hi")

      {state, _cmds} = press(state, :home)
      {state, _cmds} = press(state, "<")
      assert Composer.value(state) == "< hi"

      {state, _cmds} = press(state, :end)
      {state, _cmds} = press(state, ">")
      assert Composer.value(state) == "< hi>"
    end

    test "backspace at Home is a no-op on the draft" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hi")

      {state, _cmds} = press(state, :home)
      {state, _cmds} = press(state, :backspace)

      assert Composer.value(state) == "hi"
    end
  end

  describe "visual up/down across wrapped rows" do
    # Width 10: "aaaa bbbb cccc" wraps (content-preserving) to the visual
    # rows ["aaaa bbbb ", "cccc"] -- the trailing space stays on row 0,
    # "cccc" starts at logical col 10.
    defp wrapped_draft do
      {:ok, state} = Composer.init(%{id: :c, width: 10, focused: true})
      type(state, "aaaa bbbb cccc")
    end

    test "Up moves from the wrapped second row into the first at the goal column" do
      state = wrapped_draft()

      # Cursor ends at logical col 14 -> visual row 1, cell 4.
      {state, _cmds} = press(state, :up)
      {state, _cmds} = press(state, "X")

      # Landed at cell 4 of visual row 0 -> logical col 4.
      assert Composer.value(state) == "aaaaX bbbb cccc"
    end

    test "Up mid-wrap moves; only Up at the TOP visual row recalls history" do
      {:ok, state} = Composer.init(%{id: :c, width: 10, focused: true})
      state = type(state, "old")
      {state, _cmds} = press(state, :enter)
      state = type(state, "aaaa bbbb cccc")

      # First Up: cursor is on visual row 1 -> plain movement, no recall.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "aaaa bbbb cccc"
      assert state.history_index == nil

      # Second Up: now at the top visual row -> history recall.
      {state, []} = press(state, :up)
      assert Composer.value(state) == "old"
      assert state.history_index == 0
    end

    test "Down remembers the goal column across a shorter row" do
      state = wrapped_draft()

      {state, _cmds} = press(state, :up)
      {state, _cmds} = press(state, :down)
      {state, _cmds} = press(state, "!")

      # Back on visual row 1 at the goal cell (4 == end of "cccc").
      assert Composer.value(state) == "aaaa bbbb cccc!"
    end

    test "Up at the top row with no history, and Down at the bottom row with no recall, are no-ops" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "hi")

      {up_state, []} = press(state, :up)
      assert Composer.value(up_state) == "hi"
      assert up_state.mli.cursor_pos == state.mli.cursor_pos

      {down_state, []} = press(state, :down)
      assert Composer.value(down_state) == "hi"
      assert down_state.mli.cursor_pos == state.mli.cursor_pos
    end
  end

  describe "multi-line drafts (backslash continuation) navigation" do
    test "Up from the second logical line lands in the first; edits land there" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "one\\")
      {state, []} = press(state, :enter)
      state = type(state, "two")
      assert Composer.value(state) == "one\ntwo"

      {state, _cmds} = press(state, :up)
      {state, _cmds} = press(state, "X")

      assert Composer.value(state) == "oneX\ntwo"
    end

    test "Down returns to the second logical line" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "one\\")
      {state, []} = press(state, :enter)
      state = type(state, "two")

      {state, _cmds} = press(state, :up)
      {state, _cmds} = press(state, :down)
      {state, _cmds} = press(state, "!")

      assert Composer.value(state) == "one\ntwo!"
    end
  end

  describe "WrapMap alignment laws (the projection's oracle)" do
    alias Raxol.UI.Components.Harness.Composer.WrapMap

    # A corpus of the whitespace/width shapes that broke the old dual
    # representation, crossed with widths that force wraps at awkward
    # boundaries.
    @corpus [
      "",
      " ",
      "   ",
      " ab",
      "ab ",
      " a  b ",
      "aaaa bbbb cccc",
      "a verylongwordthatmustsplit b",
      "你好 世界",
      "a你b好c",
      "e🎉mo ji🎉 end",
      "one\ntwo three\n four"
    ]

    test "every segment is an EXACT substring of its logical line at its start offset" do
      for value <- @corpus, width <- [3, 4, 7, 10, 40] do
        map = WrapMap.build(value, width, :word)
        logical = String.split(value, "\n")

        for %{text: text, row: row, start: start} <- map.segments do
          line = Enum.at(logical, row)

          assert String.slice(line, start, String.length(text)) == text,
                 "segment #{inspect(text)} misaligned at #{inspect({row, start})} " <>
                   "in #{inspect(line)} (width #{width})"
        end
      end
    end

    test "only whitespace is ever absent between consecutive segments (nothing else is dropped)" do
      for value <- @corpus, width <- [3, 4, 7, 10, 40] do
        map = WrapMap.build(value, width, :word)
        logical = String.split(value, "\n")

        map.segments
        |> Enum.group_by(& &1.row)
        |> Enum.each(fn {row, segments} ->
          line = Enum.at(logical, row)

          # Walk the gaps: before the first segment, between segments,
          # and after the last -- each must be pure whitespace.
          covered =
            Enum.map(segments, fn %{start: start, text: text} ->
              {start, start + String.length(text)}
            end)

          gaps =
            Enum.zip([{0, 0} | covered], covered ++ [{String.length(line), 0}])
            |> Enum.map(fn {{_s1, e1}, {s2, _e2}} ->
              String.slice(line, e1, max(s2 - e1, 0))
            end)

          for gap <- gaps, gap != "" do
            assert String.trim(gap) == "",
                   "non-whitespace #{inspect(gap)} dropped from " <>
                     "#{inspect(line)} (width #{width})"
          end
        end)
      end
    end

    test "to_visual is total and lands inside a real segment for every logical position" do
      for value <- @corpus, width <- [3, 4, 7, 10, 40] do
        map = WrapMap.build(value, width, :word)
        logical = String.split(value, "\n")

        for {line, row} <- Enum.with_index(logical),
            col <- 0..String.length(line) do
          {vrow, gcol} = WrapMap.to_visual(map, {row, col})
          segment = Enum.at(map.segments, vrow)

          assert segment != nil
          assert segment.row == row
          assert gcol >= 0 and gcol <= String.length(segment.text)
        end
      end
    end
  end

  describe "edit_point follows the logical cursor (park generalization)" do
    test "after Left the park sits before the last char, not at the draft end" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "abc")

      {state, _cmds} = press(state, :left)

      assert Composer.edit_point(state, 40) == {0, 3}
    end

    test "a CJK draft parks by display cells, not graphemes" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "你好")

      assert Composer.edit_point(state, 40) == {0, 5}

      {state, _cmds} = press(state, :left)
      assert Composer.edit_point(state, 40) == {0, 3}
    end

    test "on a wrapped draft the park sits on the cursor's visual row" do
      {:ok, state} = Composer.init(%{id: :c, width: 10, focused: true})
      state = type(state, "aaaa bbbb cccc")

      assert Composer.edit_point(state, 10) == {1, 5}

      {state, _cmds} = press(state, :up)
      assert Composer.edit_point(state, 10) == {0, 5}
    end

    test "a mid-draft edit_point on a multi-line draft reports the cursor's row" do
      {:ok, state} = Composer.init(id: :c)
      state = type(state, "one\\")
      {state, []} = press(state, :enter)
      state = type(state, "two")

      {state, _cmds} = press(state, :up)

      assert Composer.edit_point(state, 40) == {0, 4}
    end
  end
end
