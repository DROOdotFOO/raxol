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

  describe "init/1" do
    test "returns {:ok, state} with defaults" do
      assert {:ok, state} = MarkdownRenderer.init(%{})
      assert state.markdown_text == ""
      assert state.width == 80
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
      texts = children(result)
      heading = Enum.find(texts, &(&1.content =~ "# Hello World"))
      assert heading != nil
      assert heading.style.bold == true
      assert heading.style.fg == :cyan
    end

    test "renders h2 with bold cyan style" do
      result = render_md("## Section")
      texts = children(result)
      heading = Enum.find(texts, &(&1.content =~ "## Section"))
      assert heading != nil
      assert heading.style.bold == true
    end

    test "renders h3 with bold cyan style" do
      result = render_md("### Sub")
      texts = children(result)
      heading = Enum.find(texts, &(&1.content =~ "### Sub"))
      assert heading != nil
      assert heading.style.bold == true
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

    test "converts links to text with URL, no marker leakage" do
      result = render_md("[click](http://example.com)")
      text = full_text(result)
      assert text =~ "click"
      assert text =~ "http://example.com"
      refute text =~ "["
      refute text =~ "]("
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
  end

  describe "inline formatting (overflowing lines -> wrapped, marker-free)" do
    test "long formatted line wraps and drops styling but keeps no markers" do
      long = "some **bold** words that go on and on and on and on and on and on"
      result = render_md(long, %{width: 20})
      lines = Enum.map(children(result), & &1.content)

      assert length(lines) > 1
      refute Enum.any?(lines, &String.contains?(&1, "*"))
      assert Enum.any?(lines, &String.contains?(&1, "bold"))
      assert Enum.all?(lines, &(String.length(&1) <= 20))
    end

    test "wrapped list item keeps the bullet prefix on the first line only" do
      long =
        "- a rather long list item body that will not fit on one narrow line at all"

      result = render_md(long, %{width: 20})

      lines =
        Enum.map(children(result), & &1.content) |> Enum.reject(&(&1 == ""))

      assert [first | rest] = lines
      assert String.starts_with?(first, "  * ")
      refute Enum.any?(rest, &String.starts_with?(&1, "  * "))
      refute Enum.any?(lines, &String.contains?(&1, "*a "))
      # The marker eats into the first line's budget too -- every wrapped
      # line, including the one carrying the prefix, must fit `width`.
      assert Enum.all?(lines, &(String.length(&1) <= 20))
    end

    test "wrapped ordered list item's prefixed line also stays within width" do
      long =
        "1. a rather long list item body that will not fit on one narrow line at all"

      result = render_md(long, %{width: 20})

      lines =
        Enum.map(children(result), & &1.content) |> Enum.reject(&(&1 == ""))

      assert [first | _rest] = lines
      assert String.starts_with?(first, "  1. ")
      assert Enum.all?(lines, &(String.length(&1) <= 20))
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
               &(&1.type == :text and &1.content =~ "* item one")
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
      assert Enum.any?(row.children, &(&1.content == "  * "))
    end
  end

  describe "code blocks" do
    test "renders fenced code with yellow style" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      result = render_md(md)

      code_lines =
        Enum.filter(children(result), fn el ->
          el.style[:fg] == :yellow and el.content =~ "IO.puts"
        end)

      assert [_ | _] = code_lines
    end

    test "indents code lines" do
      md = "```\nhello\nworld\n```"
      result = render_md(md)
      code_lines = Enum.filter(children(result), &(&1.style[:fg] == :yellow))

      for line <- code_lines do
        assert String.starts_with?(line.content, "  ")
      end
    end

    # Regression pin: the builtin fenced path used to push code lines onto
    # the reversed accumulator in already-correct order, so the final
    # reversal flipped them -- a multi-line block rendered bottom-to-top.
    test "renders multi-line code in source order" do
      md = "```\nfirst\nsecond\nthird\n```"
      result = render_md(md)

      code_contents =
        result
        |> children()
        |> Enum.filter(&(&1.style[:fg] == :yellow))
        |> Enum.map(& &1.content)

      assert code_contents == ["  first", "  second", "  third"]
    end
  end

  describe "blockquotes" do
    test "renders blockquote with pipe prefix and green style" do
      result = render_md("> quoted text")
      all = children(result)
      quoted = Enum.find(all, &(&1.content =~ "| quoted text"))
      assert quoted != nil
      assert quoted.style.fg == :green
    end
  end

  describe "horizontal rules" do
    test "renders hr as dashes" do
      result = render_md("---")
      all = children(result)
      hr = Enum.find(all, &String.contains?(&1.content, "---"))
      assert hr != nil
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
      all = children(result)
      hr = Enum.find(all, &String.contains?(&1.content, "---"))
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

  describe "inline_segments/2 (Earmark AST path, dependency-free)" do
    test "plain text yields one unstyled segment" do
      assert MarkdownRenderer.inline_segments(["hello"]) == [{"hello", %{}}]
    end

    test "strong node yields a bold segment" do
      ast = [{"strong", [], ["bold"], %{}}]
      assert MarkdownRenderer.inline_segments(ast) == [{"bold", %{bold: true}}]
    end

    test "em node yields an italic segment" do
      ast = [{"em", [], ["em"], %{}}]
      assert MarkdownRenderer.inline_segments(ast) == [{"em", %{italic: true}}]
    end

    test "code node yields a code-styled segment" do
      ast = [{"code", [], ["code"], %{}}]
      assert MarkdownRenderer.inline_segments(ast) == [{"code", %{fg: :yellow}}]
    end

    test "nested strong-inside-em merges both styles" do
      ast = [{"em", [], [{"strong", [], ["both"], %{}}], %{}}]

      assert MarkdownRenderer.inline_segments(ast) == [
               {"both", %{bold: true, italic: true}}
             ]
    end

    test "link node yields plain 'text (href)' segment" do
      ast = [{"a", [{"href", "http://x.test"}], ["click"], %{}}]

      assert MarkdownRenderer.inline_segments(ast) == [
               {"click (http://x.test)", %{}}
             ]
    end

    test "mixed children preserve order" do
      ast = ["plain ", {"strong", [], ["bold"], %{}}, " tail"]

      assert MarkdownRenderer.inline_segments(ast) == [
               {"plain ", %{}},
               {"bold", %{bold: true}},
               {" tail", %{}}
             ]
    end
  end

  # A fence's info string ("```elixir") names the code's language. The
  # renderer displays it as a dim label line above the (monospace, yellow)
  # code body. Display only -- NO syntax highlighting in this unit; the
  # label + @code_style block is the documented seam a future highlighter
  # slots into.
  describe "fenced code language tags (info string)" do
    test "renders the language as a dim label line above the code body" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      result = render_md(md)

      assert [label] =
               Enum.filter(children(result), &(&1[:content] == "  elixir"))

      assert label.style[:dim] == true

      label_idx =
        Enum.find_index(children(result), &(&1[:content] == "  elixir"))

      code_idx =
        Enum.find_index(children(result), &((&1[:content] || "") =~ "IO.puts"))

      assert label_idx < code_idx,
             "the language label must sit above the code body"
    end

    test "the label is chrome, not code -- dim, never the code accent" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      result = render_md(md)

      [label] = Enum.filter(children(result), &(&1[:content] == "  elixir"))

      refute label.style[:fg] == :yellow,
             "the label must be visually distinct from the code body"
    end

    test "an untagged fence renders no label line (and no dim element at all)" do
      md = "```\nhello\n```"
      result = render_md(md)

      assert length(children(result)) == 3

      refute Enum.any?(children(result), &(&1[:style][:dim] == true)),
             "an untagged fence must not grow a label line"
    end

    test "~~~ fences carry the label too" do
      md = "~~~python\nx = 1\n~~~"
      result = render_md(md)

      assert Enum.any?(children(result), &(&1[:content] == "  python"))
    end

    test "only the first word of the info string becomes the label" do
      md = "```elixir title=demo\n:ok\n```"
      result = render_md(md)

      assert Enum.any?(children(result), &(&1[:content] == "  elixir"))
      refute full_text(result) =~ "title"
    end

    test "code_language_from_attrs/1 extracts Earmark's class attr, stripping the language- prefix" do
      assert MarkdownRenderer.code_language_from_attrs([{"class", "elixir"}]) ==
               "elixir"

      assert MarkdownRenderer.code_language_from_attrs([
               {"class", "language-rust"}
             ]) == "rust"

      assert MarkdownRenderer.code_language_from_attrs([]) == nil
      assert MarkdownRenderer.code_language_from_attrs([{"class", ""}]) == nil
    end
  end
end
