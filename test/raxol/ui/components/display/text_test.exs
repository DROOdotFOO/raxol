defmodule Raxol.UI.Components.Display.TextTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Display.Text

  @context %{theme: %{}}

  describe "init/1" do
    test "sets defaults" do
      {:ok, state} = Text.init([])
      assert state.content == ""
      assert state.wrap == :none
      assert state.align == :left
      assert state.width == nil
      assert state.truncate == false
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "accepts provided props" do
      {:ok, state} =
        Text.init(
          content: "hello",
          wrap: :word,
          align: :center,
          width: 20,
          truncate: true,
          id: "my-text",
          style: %{bold: true},
          theme: %{fg: :red}
        )

      assert state.content == "hello"
      assert state.wrap == :word
      assert state.align == :center
      assert state.width == 20
      assert state.truncate == true
      assert state.id == "my-text"
      assert state.style == %{bold: true}
      assert state.theme == %{fg: :red}
    end
  end

  describe "render/2 - single line, no wrapping" do
    test "returns text element with content" do
      {:ok, state} = Text.init(content: "hello world", id: "t")
      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "hello world"
    end

    test "applies style from state" do
      {:ok, state} = Text.init(content: "hi", id: "t", style: %{bold: true})
      result = Text.render(state, @context)
      assert result.style.bold == true
    end
  end

  describe "render/2 - truncation" do
    test "truncates long text with ellipsis" do
      {:ok, state} =
        Text.init(content: "hello world", width: 8, truncate: true, id: "t")

      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "hello..."
      assert String.length(result.content) == 8
    end

    test "does not truncate text that fits" do
      {:ok, state} =
        Text.init(content: "hi", width: 10, truncate: true, id: "t")

      result = Text.render(state, @context)
      assert result.content == "hi"
    end

    test "does not truncate when no width set" do
      {:ok, state} =
        Text.init(content: "a long string", truncate: true, id: "t")

      result = Text.render(state, @context)
      assert result.content == "a long string"
    end

    test "handles very small widths" do
      {:ok, state} =
        Text.init(content: "hello", width: 3, truncate: true, id: "t")

      result = Text.render(state, @context)
      assert String.length(result.content) == 3
    end
  end

  describe "render/2 - word wrapping" do
    test "produces column with wrapped lines" do
      {:ok, state} =
        Text.init(
          content: "one two three four",
          width: 10,
          wrap: :word,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert length(contents) > 1
      assert Enum.all?(contents, fn c -> String.length(c) <= 10 end)
    end

    test "single word that fits returns text element" do
      {:ok, state} =
        Text.init(content: "hello", width: 10, wrap: :word, id: "t")

      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "hello"
    end
  end

  describe "render/2 - char wrapping" do
    test "produces column with char-wrapped lines" do
      {:ok, state} =
        Text.init(content: "abcdefghij", width: 4, wrap: :char, id: "t")

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["abcd", "efgh", "ij"]
    end
  end

  describe "render/2 - alignment" do
    test "left alignment is default (no padding)" do
      {:ok, state} = Text.init(content: "hi", width: 10, id: "t")
      result = Text.render(state, @context)
      assert result.content == "hi"
    end

    test "right alignment pads left" do
      {:ok, state} = Text.init(content: "hi", width: 10, align: :right, id: "t")
      result = Text.render(state, @context)
      assert result.content == "        hi"
    end

    test "center alignment pads both sides" do
      {:ok, state} =
        Text.init(content: "hi", width: 10, align: :center, id: "t")

      result = Text.render(state, @context)
      assert String.length(result.content) == 10
      assert String.trim(result.content) == "hi"
    end

    test "alignment without width is no-op" do
      {:ok, state} = Text.init(content: "hi", align: :center, id: "t")
      result = Text.render(state, @context)
      assert result.content == "hi"
    end
  end

  describe "render/2 - wrapping + alignment" do
    test "each wrapped line is aligned independently" do
      {:ok, state} =
        Text.init(
          content: "ab cd ef",
          width: 5,
          wrap: :word,
          align: :right,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column

      Enum.each(result.children, fn child ->
        assert String.length(child.content) == 5
      end)
    end
  end

  describe "init/1 - white_space" do
    test "defaults to :normal" do
      {:ok, state} = Text.init([])
      assert state.white_space == :normal
    end

    test "accepts provided white_space" do
      {:ok, state} = Text.init(white_space: :pre_wrap)
      assert state.white_space == :pre_wrap
    end
  end

  describe "render/2 - white_space :normal is a no-op over the legacy wrap prop" do
    test "wrap: :word output is unchanged whether white_space is set or omitted" do
      {:ok, without} =
        Text.init(
          content: "one two three four",
          width: 10,
          wrap: :word,
          id: "t"
        )

      {:ok, with_normal} =
        Text.init(
          content: "one two three four",
          width: 10,
          wrap: :word,
          white_space: :normal,
          id: "t"
        )

      assert Text.render(without, @context) ==
               Text.render(with_normal, @context)
    end
  end

  describe "render/2 - white_space overrides wrap dispatch when non-default" do
    test ":pre preserves whitespace and only breaks on explicit newlines" do
      {:ok, state} =
        Text.init(
          content: "a  b\nc  d",
          width: 3,
          white_space: :pre,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["a  b", "c  d"]
    end

    test ":nowrap collapses whitespace into a single line regardless of width" do
      {:ok, state} =
        Text.init(
          content: "line one\nline two",
          width: 4,
          white_space: :nowrap,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "line one line two"
    end

    test ":pre_line collapses spaces but preserves newlines, wraps at width" do
      {:ok, state} =
        Text.init(
          content: "a   b\nc d",
          width: 10,
          white_space: :pre_line,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["a b", "c d"]
    end
  end

  describe "init/1 - text_overflow / line_clamp" do
    test "defaults to :clip and nil" do
      {:ok, state} = Text.init([])
      assert state.text_overflow == :clip
      assert state.line_clamp == nil
    end

    test "accepts provided text_overflow and line_clamp" do
      {:ok, state} = Text.init(text_overflow: :ellipsis, line_clamp: 3)
      assert state.text_overflow == :ellipsis
      assert state.line_clamp == 3
    end
  end

  describe "render/2 - text_overflow default (:clip) is a no-op" do
    test ":nowrap output is unchanged whether text_overflow is set to :clip or omitted" do
      {:ok, without} =
        Text.init(
          content: "hello world foo",
          width: 8,
          white_space: :nowrap,
          id: "t"
        )

      {:ok, with_clip} =
        Text.init(
          content: "hello world foo",
          width: 8,
          white_space: :nowrap,
          text_overflow: :clip,
          id: "t"
        )

      assert Text.render(without, @context) == Text.render(with_clip, @context)
    end

    test ":pre output is unchanged whether text_overflow is set to :clip or omitted" do
      {:ok, without} =
        Text.init(
          content: "a  b\nc  d looooong",
          width: 5,
          white_space: :pre,
          id: "t"
        )

      {:ok, with_clip} =
        Text.init(
          content: "a  b\nc  d looooong",
          width: 5,
          white_space: :pre,
          text_overflow: :clip,
          id: "t"
        )

      assert Text.render(without, @context) == Text.render(with_clip, @context)
    end

    test "text_overflow: :ellipsis has no effect on :normal/:pre_wrap/:pre_line (spec-scoped to :nowrap/:pre only)" do
      {:ok, without} =
        Text.init(
          content: "one two three four",
          width: 10,
          white_space: :pre_wrap,
          id: "t"
        )

      {:ok, with_ellipsis} =
        Text.init(
          content: "one two three four",
          width: 10,
          white_space: :pre_wrap,
          text_overflow: :ellipsis,
          id: "t"
        )

      assert Text.render(without, @context) ==
               Text.render(with_ellipsis, @context)
    end

    test "legacy truncate: true prop is unaffected by the new text_overflow default" do
      {:ok, state} =
        Text.init(content: "hello world", width: 8, truncate: true, id: "t")

      result = Text.render(state, @context)
      assert result.content == "hello..."
    end
  end

  describe "render/2 - line_clamp default (nil) is a no-op" do
    test "word-wrapped output is unchanged whether line_clamp is nil or omitted" do
      {:ok, without} =
        Text.init(
          content: "one two three four five six",
          width: 10,
          wrap: :word,
          id: "t"
        )

      {:ok, with_nil} =
        Text.init(
          content: "one two three four five six",
          width: 10,
          wrap: :word,
          line_clamp: nil,
          id: "t"
        )

      assert Text.render(without, @context) == Text.render(with_nil, @context)
    end
  end

  describe "render/2 - text_overflow: :ellipsis applied to :nowrap / :pre" do
    test ":nowrap truncates the collapsed single line with a real ellipsis" do
      {:ok, state} =
        Text.init(
          content: "hello world foo",
          width: 8,
          white_space: :nowrap,
          text_overflow: :ellipsis,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "hello w…"
      assert Raxol.UI.TextMeasure.display_width(result.content) <= 8
    end

    test ":pre truncates each preserved line independently" do
      {:ok, state} =
        Text.init(
          content: "a  b\nc  d looooong",
          width: 5,
          white_space: :pre,
          text_overflow: :ellipsis,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["a  b", "c  d…"]
    end
  end

  describe "render/2 - line_clamp" do
    test "clamps :normal wrap to max_lines with block-ellipsis on the last line" do
      {:ok, state} =
        Text.init(
          content: "one two three four five six",
          width: 10,
          line_clamp: 2,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :column
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["one two", "three fou…"]
    end

    test "overrides the legacy wrap prop when set" do
      {:ok, state} =
        Text.init(
          content: "one two three four five six",
          width: 10,
          wrap: :char,
          line_clamp: 2,
          id: "t"
        )

      result = Text.render(state, @context)
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["one two", "three fou…"]
    end

    test "combined with :pre_line white_space" do
      {:ok, state} =
        Text.init(
          content: "a\nb\nc\nd",
          width: 10,
          white_space: :pre_line,
          line_clamp: 2,
          id: "t"
        )

      result = Text.render(state, @context)
      contents = Enum.map(result.children, & &1.content)
      assert contents == ["a", "b…"]
    end

    test "content fitting entirely within max_lines is unchanged, no ellipsis" do
      {:ok, state} =
        Text.init(
          content: "one two",
          width: 10,
          line_clamp: 5,
          id: "t"
        )

      result = Text.render(state, @context)
      assert result.type == :text
      assert result.content == "one two"
    end
  end

  describe "update/2" do
    test "merges style and theme" do
      {:ok, state} =
        Text.init(style: %{bold: true}, theme: %{fg: :red}, id: "t")

      {updated, []} =
        Text.update(%{style: %{italic: true}, theme: %{bg: :blue}}, state)

      assert updated.style == %{bold: true, italic: true}
      assert updated.theme == %{fg: :red, bg: :blue}
    end

    test "updates content" do
      {:ok, state} = Text.init(content: "old", id: "t")
      {updated, []} = Text.update(%{content: "new"}, state)
      assert updated.content == "new"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = Text.init(content: "hello", id: "t")
      {result_state, commands} = Text.handle_event(:any_event, state, @context)
      assert result_state == state
      assert commands == []
    end
  end
end
