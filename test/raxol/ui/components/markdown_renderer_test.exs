defmodule Raxol.UI.Components.MarkdownRendererTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.MarkdownRenderer

  defp render_md(text, opts \\ %{}) do
    {:ok, state} =
      MarkdownRenderer.init(Map.merge(%{markdown_text: text}, opts))

    MarkdownRenderer.render(state, %{})
  end

  defp children(result), do: result.children

  # Recursively flattens `:text`/`:row` elements into their leaf text
  # content, in document order. Needed because inline-formatted lines are
  # now rendered as a `:row` of styled spans rather than a single `:text`
  # element -- most content-only assertions should look through that.
  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{type: :row, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(%{type: :column, children: children}),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_), do: []

  defp contents(result), do: Enum.flat_map(children(result), &flat_texts/1)

  defp full_text(result), do: Enum.join(contents(result), "")

  # Every rendered table line, identified by the Table component's inner
  # column separator.
  defp table_lines(result) do
    result
    |> children()
    |> Enum.map(& &1[:content])
    |> Enum.filter(&(is_binary(&1) and String.contains?(&1, "│")))
  end

  # Recursively collects every `{content, style}` leaf pair, so tests can
  # assert on the style attached to a specific styled span.
  defp flat_leaves(%{type: :text, content: content, style: style}),
    do: [{content, style}]

  defp flat_leaves(%{type: :row, children: children}),
    do: Enum.flat_map(children, &flat_leaves/1)

  defp flat_leaves(%{type: :column, children: children}),
    do: Enum.flat_map(children, &flat_leaves/1)

  defp flat_leaves(_), do: []

  defp leaves(result), do: Enum.flat_map(children(result), &flat_leaves/1)

  # One string per top-level child (rows collapse to a single line).
  defp line_strings(result) do
    Enum.map(children(result), fn
      %{type: :text, content: c} ->
        c

      %{type: :row, children: ch} ->
        Enum.map_join(ch, "", &(&1[:content] || ""))

      _ ->
        ""
    end)
  end

  describe "init/1" do
    test "returns {:ok, state} with defaults" do
      assert {:ok, state} = MarkdownRenderer.init(%{})
      assert state.markdown_text == ""
      assert state.width == 80
      assert state.syntax_theme == :one_dark
    end

    test "merges custom props" do
      assert {:ok, state} =
               MarkdownRenderer.init(%{markdown_text: "# Hi", width: 40})

      assert state.markdown_text == "# Hi"
      assert state.width == 40
    end
  end

  describe "update/2" do
    test "returns state unchanged" do
      {:ok, state} = MarkdownRenderer.init(%{markdown_text: "# Title"})
      assert MarkdownRenderer.update(:any, state) == state
    end
  end

  describe "handle_event/3" do
    test "returns {state, []} for any event" do
      {:ok, state} = MarkdownRenderer.init(%{markdown_text: "text"})
      assert {^state, []} = MarkdownRenderer.handle_event(:click, state, %{})
    end
  end

  describe "mount/1 and unmount/1" do
    test "mount returns {state, []}" do
      {:ok, state} = MarkdownRenderer.init(%{})
      assert {^state, []} = MarkdownRenderer.mount(state)
    end

    test "unmount returns state" do
      {:ok, state} = MarkdownRenderer.init(%{})
      assert MarkdownRenderer.unmount(state) == state
    end
  end

  describe "render/2 structure" do
    test "returns a column container with children" do
      result = render_md("hello")
      assert result.type == :column
      assert is_list(result.children)
    end

    test "plain (unformatted) lines stay single flat text elements" do
      result = render_md("hello")

      for child <- children(result) do
        assert child.type == :text
      end
    end
  end

  describe "headings" do
    test "renders h1 with bold cyan style" do
      result = render_md("# Hello World")
      assert full_text(result) =~ "Hello World"
      assert full_text(result) =~ "#"
      leaves = leaves(result)

      assert Enum.any?(leaves, fn {t, s} ->
               t =~ "Hello" and s[:bold] == true and s[:fg] == :cyan
             end)
    end

    test "renders h2 with bold cyan style" do
      result = render_md("## Section")
      assert full_text(result) =~ "Section"

      assert Enum.any?(leaves(result), fn {t, s} ->
               t =~ "Section" and s[:bold] == true and s[:fg] == :cyan
             end)
    end

    test "renders h3 with bold cyan style" do
      result = render_md("### Sub")
      assert full_text(result) =~ "Sub"

      assert Enum.any?(leaves(result), fn {t, s} ->
               t =~ "Sub" and s[:bold] == true and s[:fg] == :cyan
             end)
    end

    for level <- 4..6 do
      hashes = String.duplicate("#", level)

      test "renders h#{level} (#{hashes}) with bold cyan style, not literal hashes" do
        result = render_md(unquote(hashes) <> " Heading #{unquote(level)}")
        assert full_text(result) =~ "Heading #{unquote(level)}"

        assert Enum.any?(leaves(result), fn {t, s} ->
                 t =~ "Heading" and s[:bold] == true and s[:fg] == :cyan
               end)
      end
    end

    test "more than 6 hashes is not a heading (falls through to plain text)" do
      result = render_md("####### Seven hashes")
      refute Enum.any?(leaves(result), fn {_t, s} -> s[:fg] == :cyan end)
      assert full_text(result) =~ "####### Seven hashes"
    end
  end

  describe "inline formatting (fitting lines -> styled spans)" do
    test "bold text becomes a styled span, not literal markers" do
      result = render_md("some **bold** text")
      assert full_text(result) =~ "bold"
      refute full_text(result) =~ "*"

      assert {"bold", %{bold: true}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "bold"))
    end

    test "italic text becomes a styled span, not literal markers" do
      result = render_md("some _italic_ text")
      assert full_text(result) =~ "italic"
      refute full_text(result) =~ "_"

      assert {"italic", %{italic: true}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "italic"))
    end

    test "code spans use the code style" do
      result = render_md("run `mix test` now")
      assert full_text(result) =~ "mix test"
      refute full_text(result) =~ "`"

      assert {"mix test", %{fg: :yellow}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "mix test"))
    end

    test "converts links to OSC-8 hyperlink spans (label only, URL on :link)" do
      result = render_md("[click](http://example.com)")
      text = full_text(result)
      assert text =~ "click"
      # URL is not dumped into visible text — it rides on the element/style.
      refute text =~ "http://example.com"
      refute text =~ "["
      refute text =~ "]("

      assert Enum.any?(leaves(result), fn {t, s} ->
               t == "click" and s[:link] == "http://example.com" and
                 s[:underline] == true
             end)
    end

    test "a plain line with no formatting stays a single unstyled element" do
      result = render_md("just plain text")
      [line | _] = Enum.filter(children(result), &(&1.content != ""))
      assert line.type == :text
      assert line.content == "just plain text"
    end

    test "multiple spans in one line preserve order and each style" do
      result = render_md("**bold** and _em_ and `code`")
      leaves = leaves(result) |> Enum.reject(&(elem(&1, 0) == ""))

      assert Enum.map(leaves, &elem(&1, 0)) == [
               "bold",
               " and ",
               "em",
               " and ",
               "code"
             ]

      assert Enum.at(leaves, 0) |> elem(1) |> Map.get(:bold)
      assert Enum.at(leaves, 2) |> elem(1) |> Map.get(:italic)
      assert Enum.at(leaves, 4) |> elem(1) |> Map.get(:fg) == :yellow
    end

    test "a lone unmatched marker passes through as literal text" do
      result = render_md("a * b")
      assert full_text(result) == "a * b"
    end

    test "intraword underscores in a snake_case identifier are not deleted" do
      # CommonMark: `_..._` emphasis does not fire intraword (flanked by
      # alphanumerics on both sides) -- `*` is exempt from this rule, `_`
      # is not. Regression guard: this used to match `_user_` as italic,
      # silently deleting both underscores ("getuserid").
      result = render_md("get_user_id")
      assert full_text(result) == "get_user_id"
      refute Enum.any?(leaves(result), fn {_t, s} -> s[:italic] end)
    end

    test "underscore emphasis still fires when flanked by whitespace" do
      result = render_md("get_user_id and _emphasis_ here")
      assert full_text(result) == "get_user_id and emphasis here"

      assert {"emphasis", %{italic: true}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "emphasis"))
    end

    test "double and triple underscore emphasis also respect the intraword rule" do
      result = render_md("a__b__c and __bold__ and a___b___c and ___both___")
      full = full_text(result)
      assert full =~ "a__b__c"
      assert full =~ "a___b___c"
      assert full =~ "bold"
      assert full =~ "both"

      assert Enum.any?(leaves(result), fn {t, s} -> t == "bold" and s[:bold] end)

      assert Enum.any?(leaves(result), fn {t, s} ->
               t == "both" and s[:bold] and s[:italic]
             end)
    end
  end

  describe "inline formatting (overflowing lines -> wrapped, marker-free)" do
    test "long formatted line wraps, keeps markers out, may keep bold spans" do
      long = "some **bold** words that go on and on and on and on and on and on"
      result = render_md(long, %{width: 20})
      lines = line_strings(result)

      assert length(lines) > 1
      refute Enum.any?(lines, &String.contains?(&1, "*"))
      assert Enum.any?(lines, &String.contains?(&1, "bold"))
      # Styles can survive wrap now (segment-aware); bold segment still present.
      assert Enum.any?(leaves(result), fn {t, s} ->
               t == "bold" and s[:bold] == true
             end)
    end

    test "wrapped list item keeps the bullet prefix on the first line only" do
      long =
        "- a rather long list item body that will not fit on one narrow line at all"

      result = render_md(long, %{width: 20})
      lines = line_strings(result) |> Enum.reject(&(&1 == ""))

      assert [first | rest] = lines
      assert String.starts_with?(first, "  · ")
      refute Enum.any?(rest, &String.starts_with?(&1, "  · "))
      refute Enum.any?(lines, &String.contains?(&1, "*a "))
    end

    test "wrapped ordered list item's prefixed line also stays within width" do
      long =
        "1. a rather long list item body that will not fit on one narrow line at all"

      result = render_md(long, %{width: 20})
      lines = line_strings(result) |> Enum.reject(&(&1 == ""))

      assert [first | _rest] = lines
      assert String.starts_with?(first, "  1. ")
    end

    test "a double space inside a wrapped bold span doesn't drop its style" do
      # `:pretty` collapses every whitespace run to a single space in the
      # lines it returns; a wrapped output line is relocated in the
      # ORIGINAL (uncollapsed) text via an exact byte search, so a double
      # space anywhere in the source used to make that search miss and
      # the whole wrapped line fall back to unstyled (text kept, style
      # lost).
      long =
        "**one two  three four five six seven eight nine ten eleven twelve**"

      result = render_md(long, %{width: 20})
      lines = line_strings(result)

      assert length(lines) > 1
      assert full_text(result) =~ "two  three" or full_text(result) =~ "two three"

      assert Enum.any?(leaves(result), fn {t, s} ->
               s[:bold] == true and String.contains?(t, "two")
             end)
    end
  end

  describe "lists" do
    test "renders unordered list items with bullet markers" do
      result = render_md("- item one\n- item two")
      all_content = contents(result)
      assert Enum.any?(all_content, &(&1 =~ "item one"))
      assert Enum.any?(all_content, &(&1 =~ "item two"))

      assert Enum.any?(
               children(result),
               &(&1.type == :text and &1.content =~ "· item one")
             )
    end

    test "renders ordered list items with numbers" do
      result = render_md("1. first\n2. second")
      all_content = contents(result)
      assert Enum.any?(all_content, &(&1 =~ "1."))
      assert Enum.any?(all_content, &(&1 =~ "first"))
      assert Enum.any?(all_content, &(&1 =~ "2."))
      assert Enum.any?(all_content, &(&1 =~ "second"))
    end

    test "list item with inline formatting renders as styled spans" do
      result = render_md("- some **bold** item")
      assert full_text(result) =~ "bold"
      refute full_text(result) =~ "*bold*"

      row = Enum.find(children(result), &(&1.type == :row))
      assert row != nil
      assert Enum.any?(row.children, &(&1.content == "  · "))
    end
  end

  describe "code blocks" do
    test "renders fenced code via CodeBlock/SyntaxHighlighter tokens" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      result = render_md(md)
      assert full_text(result) =~ "IO.puts"
      assert full_text(result) =~ "hi"

      # When Makeup is registered, at least one token carries a hex fg.
      # Plain fallback still preserves text; the shape is always rows.
      assert Enum.any?(children(result), &(&1.type == :row))
    end

    test "indents code lines with a two-space gutter" do
      md = "```\nhello\nworld\n```"
      result = render_md(md)
      rows = Enum.filter(children(result), &(&1.type == :row))

      for row <- rows do
        first = List.first(row.children)
        assert first.content == "  "
      end
    end

    # Regression pin: the builtin fenced path used to push code lines onto
    # the reversed accumulator in already-correct order, so the final
    # reversal flipped them -- a multi-line block rendered bottom-to-top.
    test "renders multi-line code in source order" do
      md = "```\nfirst\nsecond\nthird\n```"
      result = render_md(md)

      # Flatten each body row (skip blank/label text elements) to plain text.
      row_texts =
        children(result)
        |> Enum.filter(&(&1.type == :row))
        |> Enum.map(fn row ->
          row.children |> Enum.map_join("", & &1.content)
        end)

      assert row_texts == ["  first", "  second", "  third"]
    end

    test "elixir fence can carry hex syntax colors" do
      md = "```elixir\ndef foo, do: 1\n```"
      result = render_md(md)
      fgs = leaves(result) |> Enum.map(fn {_t, style} -> style[:fg] end)

      if Enum.any?(fgs, &is_binary/1) do
        assert Enum.any?(fgs, &match?("#" <> _, &1))
      end
    end
  end

  describe "blockquotes" do
    test "renders blockquote with gutter prefix and green style" do
      result = render_md("> quoted text")
      assert full_text(result) =~ "quoted text"
      assert full_text(result) =~ "│"

      assert Enum.any?(leaves(result), fn {t, s} ->
               t =~ "quoted" and s[:fg] == :green
             end)
    end

    test "blockquote keeps bold and code styles inside" do
      result = render_md("> carry **bold** and `code`")
      assert full_text(result) =~ "bold"
      assert full_text(result) =~ "code"
      refute full_text(result) =~ "**"
      refute full_text(result) =~ "`"

      assert Enum.any?(leaves(result), fn {t, s} ->
               t == "bold" and s[:bold] == true
             end)

      assert Enum.any?(leaves(result), fn {t, s} ->
               t == "code" and s[:fg] == :yellow
             end)
    end
  end

  describe "horizontal rules" do
    test "renders hr as a continuous box-drawing rule" do
      result = render_md("---", %{width: 20})

      assert Enum.any?(children(result), fn el ->
               is_binary(el[:content]) and String.contains?(el.content, "─")
             end)
    end
  end

  describe "empty input" do
    test "renders empty string without error" do
      result = render_md("")
      assert result.type == :column
      assert is_list(result.children)
    end
  end

  describe "width parameter" do
    test "respects width for horizontal rules" do
      result = render_md("---", %{width: 20})

      hr =
        Enum.find(children(result), fn el ->
          is_binary(el[:content]) and String.contains?(el.content, "─")
        end)

      assert hr != nil
      assert String.length(hr.content) <= 20
    end
  end

  describe "render_with_builtin/2 (forced, EarmarkParser-independent)" do
    test "matches the default render_md output when EarmarkParser is unavailable" do
      # forces builtin path; default render already uses it in :test
      direct = MarkdownRenderer.render_with_builtin("some **bold** text", 80)

      {:ok, state} =
        MarkdownRenderer.init(%{markdown_text: "some **bold** text"})

      via_render = MarkdownRenderer.render(state, %{})

      assert direct == via_render.children
    end

    test "produces the same span/style shape as the AST path for bold" do
      result = %{
        type: :column,
        children: MarkdownRenderer.render_with_builtin("**bold**", 80)
      }

      assert {"bold", %{bold: true}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "bold"))
    end

    test "produces the same span/style shape as the AST path for code" do
      result = %{
        type: :column,
        children: MarkdownRenderer.render_with_builtin("`code`", 80)
      }

      assert {"code", %{fg: :yellow}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "code"))
    end
  end

  # A fence's info string ("```elixir") selects the highlighter's lexer.
  # It is NOT displayed -- there used to be a dim label line above the
  # body carrying the language name, since removed.
  describe "fenced code fences (info string)" do
    test "the language name is never rendered" do
      result = render_md("```elixir\nIO.puts(\"hi\")\n```")

      refute full_text(result) =~ "elixir"
      refute Enum.any?(children(result), &(&1[:style][:dim] == true))
    end

    test "an untagged fence renders blank + one code row + blank" do
      result = render_md("```\nhello\n```")

      assert length(children(result)) == 3
    end

    test "~~~ fences render their body the same way" do
      result = render_md("~~~python\nx = 1\n~~~")

      refute full_text(result) =~ "python"
      assert full_text(result) =~ "x = 1"
    end

    # The deleted EarmarkParser path parsed this as an INLINE code span,
    # not a fence -- so in :dev (where ex_doc supplied EarmarkParser) a
    # fence with an attribute in its info string lost its CodeBlock body
    # and its syntax highlighting entirely.
    test "a multi-word info string still opens a real fence" do
      result = render_md("```elixir title=demo\n:ok\n```")

      refute full_text(result) =~ "title"
      refute full_text(result) =~ "```"
      assert full_text(result) =~ ":ok"

      # A real fence body is CodeBlock rows, not one inline text element.
      assert Enum.any?(children(result), &(&1[:type] == :row))
    end

    # MarkdownRenderer's contract is "callers may pass untrusted text", and
    # it has direct callers with no MarkdownBody pre-sanitization in front
    # (e.g. the playground's DemoHelpers.markdown/2). The info string is
    # sanitized at THIS boundary regardless of which path produced it.
    test "control/ESC bytes in the info string never reach the output" do
      result = render_md("```elixir\e[2J\n:ok\n```")

      refute full_text(result) =~ "\e",
             "a raw ESC byte from the fence info string reached text()"
    end

    test "an oversized info string cannot produce unbounded output" do
      lang = String.duplicate("x", 100_000)
      result = render_md("```#{lang}\n:ok\n```")

      refute full_text(result) =~ lang
    end
  end

  # Regression guard for the reported defect: with no "table" clause on the
  # (now deleted) Earmark path, the generic AST recursion emitted one text
  # element per CELL, so a table rendered as a vertical list of cells.
  describe "GFM tables" do
    test "renders as one framed table, not one element per cell" do
      md = """
      | Feature | Status |
      | --- | --- |
      | Headings h1-h6 | yes |
      | GFM tables | yes |
      """

      lines = table_lines(render_md(md, %{width: 60}))

      # One line per source row (header + 2 body), each carrying BOTH cells.
      assert length(lines) == 3

      assert Enum.all?(
               lines,
               &(String.contains?(&1, "│") and &1 =~ ~r/\S.*│.*\S/)
             )

      assert hd(lines) =~ "Feature"
      assert hd(lines) =~ "Status"
      assert Enum.at(lines, 1) =~ "Headings h1-h6"
      assert Enum.at(lines, 1) =~ "yes"
    end

    test "table cell elements carry a map style, not Table's internal atom-list style" do
      # Regression guard: `Table.render/2` builds its cells through
      # `Raxol.Core.Renderer.View.text/2`, whose `style:` is an atom LIST
      # (e.g. `[:bold]`), not the `%{bold: true}` map every other element
      # this module emits uses. Splicing that raw shape into this
      # module's own tree crashed `Harness.Surface`'s `ViewText.lines/3`
      # bridge (`Map.get([:bold], :bold, nil)` -> `BadMapError`) the first
      # time a real session rendered a GFM table.
      md = """
      | a | b |
      | --- | --- |
      | x | y |
      """

      result = render_md(md, %{width: 40})

      table_text_elements =
        result
        |> children()
        |> Enum.filter(&(&1[:type] == :text and is_binary(&1[:content])))

      assert table_text_elements != []

      assert Enum.all?(table_text_elements, fn el ->
               is_map(el.style)
             end)
    end

    test "a snake_case identifier in a cell keeps its underscores" do
      # Regression guard: `table_cell_text/1` parses cell markup through
      # the same `builtin_segments/1` every other line uses; before the
      # intraword-emphasis guard, "foo_bar_baz" matched `_bar_` as italic
      # and the Table component (plain-string cells, no styled spans)
      # rendered the survivor as "foobarbaz".
      md = """
      | name | status |
      | --- | --- |
      | foo_bar_baz | ok |
      """

      [_header, row] = table_lines(render_md(md, %{width: 40}))
      assert row =~ "foo_bar_baz"
    end

    # `take_table_rows/4` used to require a leading "|" unconditionally, so
    # a valid pipe-less table rendered its header and then dropped every
    # body row out of the table as raw prose.
    test "absorbs body rows of a table written without leading pipes" do
      md = """
      Name | Qty
      ---- | ---
      foo | 1
      bar | 22
      """

      result = render_md(md, %{width: 40})

      assert length(table_lines(result)) == 3
      refute full_text(result) =~ "foo | 1"
    end

    # ...while a pipe-delimited table must NOT absorb following prose that
    # merely happens to contain a stray "|" (the guard the leading-pipe test
    # was there to provide in the first place).
    test "a pipe-delimited table stops at prose containing a stray pipe" do
      md = """
      | A | B |
      | --- | --- |
      | 1 | 2 |
      use a | b to split
      """

      result = render_md(md, %{width: 40})

      assert length(table_lines(result)) == 2
      assert full_text(result) =~ "use a | b to split"
    end

    test "cells render inline markup as text, not literal markers" do
      md = """
      | **Name** | Link |
      | --- | --- |
      | `code` | [foo](http://x.test) |
      """

      text = full_text(render_md(md, %{width: 60}))

      refute text =~ "**"
      refute text =~ "http://x.test"
      assert text =~ "Name"
      assert text =~ "code"
      assert text =~ "foo"
    end

    test "honors GFM column alignment from the separator row" do
      md = """
      | L | R | C |
      |:---|---:|:---:|
      | a | b | c |
      """

      [_header, row] = table_lines(render_md(md, %{width: 40}))
      [left, right, center] = String.split(row, "│")

      assert String.starts_with?(String.trim_leading(left), "a")
      assert String.ends_with?(String.trim_trailing(right), "b")

      lead = String.length(center) - String.length(String.trim_leading(center))

      trail =
        String.length(center) - String.length(String.trim_trailing(center))

      assert abs(lead - trail) <= 1, "center-aligned cell should be balanced"
    end
  end

  # Characters whose BYTE length, GRAPHEME count and DISPLAY WIDTH are three
  # different numbers, in every placement the renderer has. This is the
  # class that broke twice already: `:re` returns byte offsets and they were
  # fed to `String.slice/3` (grapheme-indexed), so an em dash earlier in a
  # line desynchronized every inline span after it. Any code here that
  # indexes text must agree with itself about which unit it is counting.
  describe "wide, composed and multi-byte characters" do
    # 1 grapheme / 2 cells, 1 grapheme / 1 cell but multi-byte, 1 grapheme
    # built from 7 codepoints, and a grapheme that is a base plus a
    # combining mark (NOT precomposed -- "e" <> U+0301).
    @cjk "日本語"
    @dash "—"
    @family "👨‍👩‍👧‍👦"
    @combining "é"

    defp rendered_lines(result) do
      Enum.map(children(result), fn
        %{type: :text, content: c} ->
          c

        %{type: :row, children: ch} ->
          Enum.map_join(ch, "", &(&1[:content] || ""))

        _ ->
          ""
      end)
    end

    defp assert_intact(result, expected_fragments) do
      text = full_text(result)

      assert String.valid?(text),
             "renderer emitted invalid UTF-8 -- a cut landed mid-codepoint"

      for fragment <- expected_fragments do
        assert text =~ fragment,
               "#{inspect(fragment)} did not survive intact: #{inspect(text)}"
      end
    end

    test "survives every inline placement on a fitting line" do
      md =
        "#{@cjk} #{@dash} **bold #{@cjk}** and *em #{@family}* and " <>
          "`code #{@combining}` and [link #{@cjk}](http://x.test)"

      result = render_md(md, %{width: 200})

      assert_intact(result, [@cjk, @dash, @family, @combining])
      refute full_text(result) =~ "**"
      refute full_text(result) =~ "http://x.test"
    end

    test "survives every block placement" do
      md = """
      # #{@cjk} #{@dash} heading

      - list #{@family} item
      - list #{@combining} item

      > quote #{@cjk} #{@dash} text

      | #{@cjk} | col |
      | --- | --- |
      | #{@family} | #{@combining} |
      """

      assert_intact(render_md(md, %{width: 200}), [
        @cjk,
        @dash,
        @family,
        @combining
      ])
    end

    test "a fenced code body keeps them byte-for-byte" do
      md = "```elixir\n# #{@cjk} #{@dash} #{@family} #{@combining}\n:ok\n```"

      assert_intact(render_md(md, %{width: 200}), [
        @cjk,
        @dash,
        @family,
        @combining
      ])
    end

    # The regression that motivated this block: the multi-byte character
    # sits BEFORE the inline span, so a byte/grapheme mixup corrupts the
    # span rather than the wide character itself.
    test "a multi-byte character before an inline span does not shift it" do
      result =
        render_md("prose #{@dash} tail `SyntaxHighlighter` end", %{width: 200})

      assert {"SyntaxHighlighter", %{fg: :yellow}} =
               Enum.find(leaves(result), &(elem(&1, 0) == "SyntaxHighlighter"))

      refute full_text(result) =~ "`"
    end

    test "every wrapped line stays within the width budget" do
      md =
        "Prose with #{@cjk}#{@cjk}#{@cjk} runs #{@dash} plus #{@family} " <>
          "and #{@combining} repeated to force several wrapped lines in a row " <>
          "with **bold #{@cjk}** spans crossing the break points."

      for width <- [20, 33, 40, 61] do
        result = render_md(md, %{width: width})

        for line <- rendered_lines(result) do
          assert Raxol.UI.TextMeasure.display_width(line) <= width,
                 "line exceeded width #{width}: #{inspect(line)}"
        end

        assert_intact(result, [@cjk, @dash, @family, @combining])
      end
    end

    # A break landing inside a CJK run is legal (there are no spaces to
    # break at), but it must land BETWEEN graphemes, never inside one.
    test "wrapping a space-free CJK run never splits a grapheme" do
      cjk_run = String.duplicate("日本語のテキストです", 6)

      for width <- [7, 12, 31] do
        result = render_md(cjk_run, %{width: width})
        lines = rendered_lines(result)

        for line <- lines do
          assert String.valid?(line)
          assert Raxol.UI.TextMeasure.display_width(line) <= width
        end

        assert lines |> Enum.join() |> String.replace(" ", "") == cjk_run
      end
    end

    test "a table sizes its columns by display width, not byte or grapheme count" do
      md = """
      | #{@cjk} | b |
      | --- | --- |
      | x | #{@cjk} |
      """

      lines = table_lines(render_md(md, %{width: 60}))

      # Every row of a table must be exactly as wide as every other row --
      # this is what silently breaks when a renderer counts bytes (CJK
      # over-counted 3x) or graphemes (CJK under-counted 2x) instead.
      widths =
        lines
        |> Enum.map(&Raxol.UI.TextMeasure.display_width/1)
        |> Enum.uniq()

      assert length(widths) == 1,
             "table rows disagreed on width: #{inspect(lines)}"
    end
  end

  # SECURITY: this module's contract is "callers may pass untrusted text"
  # (see moduledoc), so it must not rely on a caller having pre-sanitized
  # -- an embedded ANSI/OSC control sequence must never reach
  # `Components.text()`, where it would be indistinguishable from a real
  # cursor-move/screen-clear/title-write escape.
  describe "control-byte sanitization at this module's own boundary" do
    test "ESC-based ANSI sequences are stripped from prose" do
      result = render_md("hi \e[31mRED\e[0m bye")
      text = full_text(result)

      refute text =~ "\e"
      assert text =~ "hi"
      assert text =~ "RED"
      assert text =~ "bye"
    end

    test "an OSC title-set sequence (ESC ] 0 ; ... BEL) is stripped" do
      result = render_md("hi \e]0;pwn\a bye")
      text = full_text(result)

      refute text =~ "\e"
      refute text =~ "\a"
      assert text =~ "hi"
      assert text =~ "bye"
    end

    test "control bytes are stripped from a table cell" do
      md = """
      | name | note |
      | --- | --- |
      | ok | hi\e[31mRED\e[0mbye |
      """

      [_header, row] = table_lines(render_md(md, %{width: 60}))
      refute row =~ "\e"
      assert row =~ "RED"
    end

    test "assorted C0 controls and DEL are stripped, \\n and \\t are kept" do
      result = render_md("a\x00b\x01c\x02\nd\te\x7ff")
      text = full_text(result)

      assert Enum.all?(String.to_charlist(text), fn cp ->
               cp >= 0x20 or cp in [?\n, ?\t]
             end)

      refute text =~ "\x7f"
    end
  end
end
