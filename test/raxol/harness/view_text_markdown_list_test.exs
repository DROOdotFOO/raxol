defmodule Raxol.Harness.ViewTextMarkdownListTest do
  @moduledoc """
  Regression suite for the harness Markdown list-item render defect
  observed in a real-LLM run: a bulleted list item with an inline code
  span rendered as THREE physical rows (bullet alone, code content
  alone, dash-text alone) instead of one.

  Root cause under test: `Raxol.UI.Components.MarkdownRenderer` emits a
  styled list item as ONE `%{type: :row}` of inline `:text` spans
  (bullet prefix + styled code span + plain tail), which is correct --
  but `Raxol.Harness.Surface.ViewText.lines/3` flattened EVERY `:text`
  leaf into its own physical line, exploding the row vertically. The
  contract asserted here: a `:row` of text leaves is ONE logical line
  (segments joined in order, styled per-segment on the `:styled` path),
  and the stable-prefix streaming freezer never changes that geometry.

  The fixture input is the exact tool-inventory answer shape from V's
  run (bullets + backtick code + em-dash text).
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface.ViewText
  alias Raxol.UI.Components.Harness.MarkdownBody

  @width 80

  # V's exact input from the real-LLM run (tool-inventory answer shape).
  @v_input "* `read` — file contents\n* `write` — create or overwrite files\n"

  defp sealed_lines(text, width \\ @width, mode \\ :plain) do
    text
    |> MarkdownBody.render(%{mode: :sealed, width: width})
    |> ViewText.lines(width, mode)
  end

  describe "V's fixture: bullets + inline code + em-dash text" do
    test "each short item renders as exactly one physical row (plain)" do
      lines = sealed_lines(@v_input)

      assert lines == [
               "  · read — file contents",
               "  · write — create or overwrite files",
               ""
             ]
    end

    test "no row is ever a bare bullet or a bare code-span fragment" do
      lines = sealed_lines(@v_input)

      refute Enum.any?(lines, &(String.trim(&1) in ["*", "read", "write"])),
             "list item split across rows: #{inspect(lines)}"
    end

    test "styled path keeps the item on one row with the code span styled inline" do
      lines = sealed_lines(@v_input, @width, :styled)

      assert length(lines) == 3

      [first, second, _blank] = lines

      # One physical line: bullet prefix, then the code span styled
      # inline (SGR fg for @code_style's :yellow), then the plain tail --
      # never three separate rows.
      assert first =~ "  · "
      assert first =~ "read"
      assert first =~ " — file contents"
      assert second =~ "write"

      # The code span carries its own SGR run INSIDE the line, reset
      # before the plain tail continues.
      assert first =~ ~r/\e\[[0-9;]*33m.*read.*\e\[0m/u,
             "code span not styled inline: #{inspect(first)}"

      # Plain-content geometry is identical to the plain path.
      assert strip_sgr(first) == "  · read — file contents"
      assert strip_sgr(second) == "  · write — create or overwrite files"
    end
  end

  describe "list shapes" do
    test "ordered list items render one row each with code inline" do
      lines = sealed_lines("1. `alpha` — first\n2. `beta` — second\n")

      assert lines == [
               "  1. alpha — first",
               "  2. beta — second",
               ""
             ]
    end

    test "bold/italic/code mixes stay on one row" do
      lines = sealed_lines("* **bold** then _soft_ then `code` end\n")

      assert lines == ["  · bold then soft then code end", ""]
    end

    test "nested list items are never split mid-item" do
      text = "* `top` — outer\n  * `sub` — inner\n"
      lines = sealed_lines(text)

      # One physical row per source item -- the nested item may render
      # with its literal indent (builtin parser has no nested-list
      # grammar), but its bullet, code content, and tail always share
      # one row.
      assert Enum.count(lines, &(&1 =~ "top")) == 1
      assert Enum.count(lines, &(&1 =~ "sub")) == 1

      [top_line] = Enum.filter(lines, &(&1 =~ "top"))
      assert top_line =~ "— outer"

      [sub_line] = Enum.filter(lines, &(&1 =~ "sub"))
      assert sub_line =~ "— inner"

      refute Enum.any?(lines, &(String.trim(&1) in ["*", "top", "sub"]))
    end

    test "long items wrap with hang-indent under the bullet" do
      long_tail = String.duplicate("word ", 30) |> String.trim()
      lines = sealed_lines("* `cmd` — #{long_tail}\n", 40)

      [first | rest] = lines
      continuations = rest |> Enum.reject(&(&1 == ""))

      assert first =~ ~r/^  · cmd/
      assert continuations != [], "expected the long item to wrap"

      # Hang indent: every continuation line is indented to the text
      # column (bullet prefix width, 4 columns), never back at the
      # bullet column.
      Enum.each(continuations, fn line ->
        assert line =~ ~r/^    \S/,
               "continuation line not hang-indented: #{inspect(line)}"
      end)
    end
  end

  describe "streaming render path" do
    test "per-delta streaming renders keep items on one row" do
      # Deltas deliberately split MID-ITEM (inside the code span, inside
      # the em-dash tail) to catch a render that leaks a half-item's
      # markers at a prefix.
      chunks = [
        "* `re",
        "ad` — file",
        " contents\n* `wr",
        "ite` — create or overwrite files\n"
      ]

      final_view =
        Enum.reduce(chunks, "", fn chunk, acc ->
          acc = acc <> chunk

          view = MarkdownBody.render(acc, %{mode: :streaming, width: @width})
          lines = ViewText.lines(view, @width, :plain)

          # Committed lines (everything above the still-growing tail) are
          # stable: no marker may leak into them. A transient marker ghost
          # at the GROWING TAIL is the provisional-close's documented
          # erasure behavior on a mid-construct prefix — it self-heals on
          # the next delta and is not corruption.
          for line <- Enum.drop(lines, -1) do
            refute line =~ "*",
                   "marker leaked into a committed line at #{inspect(acc)}: #{inspect(line)}"
          end

          acc
        end)
        |> then(&MarkdownBody.render(&1, %{mode: :streaming, width: @width}))

      lines = ViewText.lines(final_view, @width, :plain)

      assert lines == [
               "  · read — file contents",
               "  · write — create or overwrite files",
               ""
             ]
    end

    test "sealed render after streaming yields the same one-row-per-item geometry" do
      streaming_lines =
        @v_input
        |> MarkdownBody.render(%{mode: :streaming, width: @width})
        |> ViewText.lines(@width, :plain)

      assert streaming_lines == sealed_lines(@v_input)
    end
  end

  describe "ViewText row-join seam" do
    test "a :row of text leaves joins into one line in document order" do
      view = %{
        type: :row,
        gap: 0,
        style: %{},
        children: [
          %{type: :text, content: "  * ", style: %{}},
          %{type: :text, content: "code", style: %{fg: :yellow}},
          %{type: :text, content: " tail", style: %{}}
        ]
      }

      assert ViewText.lines(view, @width, :plain) == ["  * code tail"]
    end

    test "row joining truncates across segments at the width budget" do
      view = %{
        type: :row,
        gap: 0,
        style: %{},
        children: [
          %{type: :text, content: "  * ", style: %{}},
          %{type: :text, content: "abcdefgh", style: %{fg: :yellow}},
          %{type: :text, content: " and more text", style: %{}}
        ]
      }

      [line] = ViewText.lines(view, 10, :plain)
      assert line == "  * abcde…"
    end

    test "an embedded newline inside a row segment still splits rows (trust boundary)" do
      view = %{
        type: :row,
        gap: 0,
        style: %{},
        children: [
          %{type: :text, content: "left", style: %{}},
          %{type: :text, content: "mid\nnext", style: %{fg: :yellow}},
          %{type: :text, content: " right", style: %{}}
        ]
      }

      assert ViewText.lines(view, @width, :plain) == ["leftmid", "next right"]
    end

    test "a :row's gap becomes literal spaces between joined segments" do
      # ToolCallBlock's header shape: glyph + name + args, gap: 1.
      view = %{
        type: :row,
        gap: 1,
        style: %{},
        children: [
          %{type: :text, content: "✓", style: %{fg: :green}},
          %{type: :text, content: "mix_test", style: %{}},
          %{type: :text, content: "(path: \".\")", style: %{dim: true}}
        ]
      }

      assert ViewText.lines(view, @width, :plain) == [
               "✓ mix_test (path: \".\")"
             ]
    end

    test "a :row carrying gap only in style still spaces its segments" do
      # ToolResultBlock's header_row shape: %{type: :row, style: %{gap: 1}}.
      view = %{
        type: :row,
        style: %{gap: 1},
        children: [
          %{type: :text, content: "✓", style: %{}},
          %{type: :text, content: "Tool Result", style: %{}}
        ]
      }

      assert ViewText.lines(view, @width, :plain) == ["✓ Tool Result"]
    end

    test "a :row with a non-text child falls back to the recursive walk" do
      view = %{
        type: :row,
        gap: 0,
        style: %{},
        children: [
          %{type: :text, content: "a", style: %{}},
          %{
            type: :column,
            gap: 0,
            style: %{},
            children: [%{type: :text, content: "b", style: %{}}]
          }
        ]
      }

      assert ViewText.lines(view, @width, :plain) == ["a", "b"]
    end

    test "a :column of text leaves is NOT joined (one line per child, unchanged)" do
      view = %{
        type: :column,
        gap: 0,
        style: %{},
        children: [
          %{type: :text, content: "one", style: %{}},
          %{type: :text, content: "two", style: %{}}
        ]
      }

      assert ViewText.lines(view, @width, :plain) == ["one", "two"]
    end
  end

  defp strip_sgr(line), do: String.replace(line, ~r/\e\[[0-9;]*m/, "")
end
