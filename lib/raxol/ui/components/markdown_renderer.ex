defmodule Raxol.UI.Components.MarkdownRenderer do
  @moduledoc """
  Renders Markdown text into styled Raxol elements for terminal display.

  Supports headings, bold, italic, code spans, code blocks, lists,
  blockquotes, horizontal rules, and links. Uses EarmarkParser when
  available, falls back to a built-in regex parser.
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.View.Components

  @default_width Raxol.Core.Defaults.terminal_width()
  @heading_style %{bold: true, fg: :cyan}
  @hr_style %{fg: :white}
  @code_style %{fg: :yellow}
  @blockquote_style %{fg: :green}
  @hr_width 40
  @ul_prefix "  * "
  @blockquote_prefix "| "

  @spec init(map()) ::
          {:ok, %{markdown_text: String.t(), width: non_neg_integer()}}
  @impl true
  def init(props) do
    state =
      Map.merge(
        %{markdown_text: "", width: @default_width},
        props
      )

    {:ok, state}
  end

  @impl true
  @spec mount(map()) :: {map(), list()}
  def mount(state), do: {state, []}

  @impl true
  @spec unmount(map()) :: map()
  def unmount(state), do: state

  @impl true
  @spec update(term(), map()) :: map()
  def update(_message, state), do: state

  @impl true
  @spec handle_event(term(), map(), map()) :: {map(), list()}
  def handle_event(_event, state, _context), do: {state, []}

  @spec render(map(), map()) :: map()
  @impl true
  def render(state, _context) do
    markdown_text = state[:markdown_text] || ""
    width = state[:width] || Raxol.Core.Defaults.terminal_width()

    elements =
      if Code.ensure_loaded?(EarmarkParser) do
        render_with_earmark(markdown_text, width)
      else
        render_with_builtin(markdown_text, width)
      end

    # gap: 0 — block spacing is expressed by explicit blank-line elements;
    # the :column dialect default (gap 1) would double every gap.
    %{type: :column, children: elements, style: %{}, gap: 0}
  end

  # --- Earmark-based rendering ---

  defp render_with_earmark(markdown_text, width) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(EarmarkParser, :as_ast, [markdown_text]) do
      {:ok, ast, _} -> Enum.flat_map(ast, &ast_node_to_elements(&1, width))
      _ -> render_with_builtin(markdown_text, width)
    end
  end

  defp ast_node_to_elements(node, _width) when is_binary(node) do
    [Components.text(content: node)]
  end

  defp ast_node_to_elements({"h1", _attrs, children, _meta}, width) do
    text = extract_text(children)

    [
      Components.text(content: ""),
      Components.text(content: "# " <> text, style: @heading_style),
      Components.text(
        content: String.duplicate("=", min(String.length(text) + 2, width))
      ),
      Components.text(content: "")
    ]
  end

  defp ast_node_to_elements({"h2", _attrs, children, _meta}, width) do
    text = extract_text(children)

    [
      Components.text(content: ""),
      Components.text(content: "## " <> text, style: @heading_style),
      Components.text(
        content: String.duplicate("-", min(String.length(text) + 3, width))
      ),
      Components.text(content: "")
    ]
  end

  defp ast_node_to_elements({"h" <> level, _attrs, children, _meta}, _width)
       when level in ["3", "4", "5", "6"] do
    text = extract_text(children)
    prefix = String.duplicate("#", String.to_integer(level)) <> " "

    [
      Components.text(content: ""),
      Components.text(content: prefix <> text, style: @heading_style),
      Components.text(content: "")
    ]
  end

  defp ast_node_to_elements({"p", _attrs, children, _meta}, _width) do
    text = extract_inline(children)
    [Components.text(content: text), Components.text(content: "")]
  end

  defp ast_node_to_elements({"ul", _attrs, children, _meta}, width) do
    items =
      Enum.flat_map(children, fn
        {"li", _, li_children, _} ->
          text = extract_inline(li_children)
          [Components.text(content: @ul_prefix <> text)]

        other ->
          ast_node_to_elements(other, width)
      end)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    items ++ [Components.text(content: "")]
  end

  defp ast_node_to_elements({"ol", _attrs, children, _meta}, width) do
    items =
      children
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {{"li", _, li_children, _}, idx} ->
          text = extract_inline(li_children)
          [Components.text(content: "  #{idx}. " <> text)]

        {other, _idx} ->
          ast_node_to_elements(other, width)
      end)

    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    items ++ [Components.text(content: "")]
  end

  defp ast_node_to_elements({"pre", _attrs, children, _meta}, _width) do
    code_text = extract_code_text(children)
    lines = String.split(code_text, "\n")

    code_elements =
      Enum.map(lines, fn line ->
        Components.text(content: "  " <> line, style: @code_style)
      end)

    Enum.concat([
      [Components.text(content: "")],
      code_elements,
      [Components.text(content: "")]
    ])
  end

  defp ast_node_to_elements({"blockquote", _attrs, children, _meta}, width) do
    inner = Enum.flat_map(children, &ast_node_to_elements(&1, width))

    Enum.map(inner, fn el ->
      content = el[:content] || ""

      if content == "" do
        el
      else
        %{
          el
          | content: @blockquote_prefix <> content,
            style: Map.merge(el[:style] || %{}, @blockquote_style)
        }
      end
    end)
  end

  defp ast_node_to_elements({"hr", _attrs, _children, _meta}, width) do
    [
      Components.text(content: ""),
      Components.text(
        content: String.duplicate("-", min(@hr_width, width)),
        style: @hr_style
      ),
      Components.text(content: "")
    ]
  end

  defp ast_node_to_elements({_tag, _attrs, children, _meta}, width) do
    Enum.flat_map(children, &ast_node_to_elements(&1, width))
  end

  defp ast_node_to_elements(_, _width), do: []

  defp extract_text(children) when is_list(children) do
    Enum.map_join(children, "", fn
      text when is_binary(text) -> text
      {_tag, _attrs, inner, _meta} -> extract_text(inner)
    end)
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp extract_inline(children) when is_list(children) do
    Enum.map_join(children, "", &extract_inline_node/1)
  end

  defp extract_inline(text) when is_binary(text), do: text
  defp extract_inline(_), do: ""

  defp extract_inline_node(text) when is_binary(text), do: text

  defp extract_inline_node({"strong", _, inner, _}),
    do: "*" <> extract_text(inner) <> "*"

  defp extract_inline_node({"em", _, inner, _}),
    do: "_" <> extract_text(inner) <> "_"

  defp extract_inline_node({"code", _, inner, _}),
    do: "`" <> extract_text(inner) <> "`"

  defp extract_inline_node({"a", attrs, inner, _}) do
    href =
      Enum.find_value(attrs, "", fn {k, v} -> if k == "href", do: v end)

    extract_text(inner) <> " (" <> href <> ")"
  end

  defp extract_inline_node({_tag, _, inner, _}), do: extract_inline(inner)

  defp extract_code_text(children) when is_list(children) do
    Enum.map_join(children, "", fn
      text when is_binary(text) -> text
      {"code", _, inner, _} -> extract_text(inner)
      {_tag, _, inner, _} -> extract_code_text(inner)
    end)
  end

  # --- Built-in regex-based rendering (no deps) ---

  defp render_with_builtin(markdown_text, width) do
    markdown_text
    |> String.split("\n")
    |> parse_blocks(width, [])
    |> Enum.reverse()
  end

  defp parse_blocks([], _width, acc), do: acc

  # Fenced code block
  defp parse_blocks(["```" <> _ | rest], width, acc) do
    {code_lines, remaining} = take_until_fence(rest, [])

    code_elements =
      Enum.map(code_lines, fn line ->
        Components.text(content: "  " <> line, style: @code_style)
      end)

    new_acc =
      [Components.text(content: "") | code_elements] ++
        [Components.text(content: "") | acc]

    parse_blocks(remaining, width, new_acc)
  end

  # Heading
  defp parse_blocks([line | rest], width, acc) do
    element = parse_line(line, width)
    parse_blocks(rest, width, [element | acc])
  end

  defp parse_line("# " <> text, _width) do
    Components.text(
      content: "# " <> strip_inline(text),
      style: @heading_style
    )
  end

  defp parse_line("## " <> text, _width) do
    Components.text(
      content: "## " <> strip_inline(text),
      style: @heading_style
    )
  end

  defp parse_line("### " <> text, _width) do
    Components.text(
      content: "### " <> strip_inline(text),
      style: @heading_style
    )
  end

  defp parse_line("---" <> _, width) do
    Components.text(
      content: String.duplicate("-", min(@hr_width, width)),
      style: @hr_style
    )
  end

  defp parse_line("***" <> _, width) do
    Components.text(
      content: String.duplicate("-", min(@hr_width, width)),
      style: @hr_style
    )
  end

  defp parse_line("> " <> text, _width) do
    Components.text(
      content: @blockquote_prefix <> strip_inline(text),
      style: @blockquote_style
    )
  end

  defp parse_line("- " <> text, _width) do
    Components.text(content: @ul_prefix <> strip_inline(text))
  end

  defp parse_line("* " <> text, _width) do
    Components.text(content: @ul_prefix <> strip_inline(text))
  end

  defp parse_line(line, _width) do
    # Check for ordered list: "1. text", "2. text", etc.
    case Regex.run(~r/^(\d+)\.\s+(.*)/, line) do
      [_, num, text] ->
        Components.text(content: "  #{num}. " <> strip_inline(text))

      _ ->
        Components.text(content: strip_inline(line))
    end
  end

  defp strip_inline(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "*\\1*")
    |> String.replace(~r/__(.+?)__/, "*\\1*")
    |> String.replace(~r/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/, "_\\1_")
    |> String.replace(~r/(?<!_)_(?!_)(.+?)(?<!_)_(?!_)/, "_\\1_")
    |> String.replace(~r/\[(.+?)\]\((.+?)\)/, "\\1 (\\2)")
  end

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_until_fence(["```" <> _ | rest], acc), do: {Enum.reverse(acc), rest}

  defp take_until_fence([line | rest], acc),
    do: take_until_fence(rest, [line | acc])
end
