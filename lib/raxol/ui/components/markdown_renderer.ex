defmodule Raxol.UI.Components.MarkdownRenderer do
  @moduledoc """
  Renders Markdown text into styled Raxol elements for terminal display.

  Supports headings, bold, italic, code spans, code blocks, lists,
  blockquotes, horizontal rules, and links. Uses EarmarkParser when
  available, falls back to a built-in regex parser.

  Inline styling does not survive a wrap boundary: a line that overflows
  `width` falls back to plain, unstyled wrapped text, though wrapped
  output never leaks literal Markdown marker characters.
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
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

    %{type: :column, children: elements, style: %{}}
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

  defp ast_node_to_elements({"p", _attrs, children, _meta}, width) do
    lines = render_segments_line(inline_segments(children), width)
    lines ++ [Components.text(content: "")]
  end

  defp ast_node_to_elements({"ul", _attrs, children, _meta}, width) do
    items =
      Enum.flat_map(children, fn
        {"li", _, li_children, _} ->
          render_segments_line(inline_segments(li_children), width, @ul_prefix)

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
          render_segments_line(
            inline_segments(li_children),
            width,
            "  #{idx}. "
          )

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

  @doc """
  Flattens Earmark AST inline children (`strong`/`em`/`code`/`a`/text
  nodes) into a list of `{text, style}` segments, merging styles across
  nesting (e.g. bold inside italic yields `%{bold: true, italic: true}`).

  Empty-text nodes are dropped. Unknown tags recurse into their children
  without adding style, so unsupported inline markup degrades to plain
  text rather than being silently dropped.
  """
  @spec inline_segments(list() | String.t()) :: [{String.t(), map()}]
  def inline_segments(children) when is_list(children) do
    Enum.flat_map(children, &inline_segment_node(&1, %{}))
  end

  def inline_segments(text) when is_binary(text) do
    if text == "", do: [], else: [{text, %{}}]
  end

  def inline_segments(_), do: []

  defp inline_segment_node(text, style) when is_binary(text) do
    if text == "", do: [], else: [{text, style}]
  end

  defp inline_segment_node({"strong", _, inner, _}, style) do
    merged = Map.put(style, :bold, true)
    Enum.flat_map(inner, &inline_segment_node(&1, merged))
  end

  defp inline_segment_node({"em", _, inner, _}, style) do
    merged = Map.put(style, :italic, true)
    Enum.flat_map(inner, &inline_segment_node(&1, merged))
  end

  defp inline_segment_node({"code", _, inner, _}, style) do
    text = extract_text(inner)
    merged = Map.merge(style, @code_style)
    if text == "", do: [], else: [{text, merged}]
  end

  defp inline_segment_node({"a", attrs, inner, _}, style) do
    href =
      Enum.find_value(attrs, "", fn {k, v} -> if k == "href", do: v end)

    text = extract_text(inner) <> " (" <> href <> ")"
    if text == "", do: [], else: [{text, style}]
  end

  defp inline_segment_node({_tag, _, inner, _}, style) do
    Enum.flat_map(inner, &inline_segment_node(&1, style))
  end

  defp inline_segment_node(_, _style), do: []

  defp extract_code_text(children) when is_list(children) do
    Enum.map_join(children, "", fn
      text when is_binary(text) -> text
      {"code", _, inner, _} -> extract_text(inner)
      {_tag, _, inner, _} -> extract_code_text(inner)
    end)
  end

  # --- Shared segment rendering (fits-vs-wrapped) ---
  #
  # `[{text, style}, ...]` segments render as: a plain `text` element when
  # unstyled; a `:row` of styled spans when styled and the full line fits
  # `width`; otherwise word-wrapped plain text (styling does not survive a
  # wrap boundary, but markers never leak since segment parsing already
  # consumed them).

  defp render_segments_line(segments, width, prefix \\ "") do
    segments = Enum.reject(segments, fn {text, _style} -> text == "" end)
    plain_text = Enum.map_join(segments, "", &elem(&1, 0))
    full_text = prefix <> plain_text

    cond do
      segments == [] and prefix == "" ->
        [Components.text(content: "")]

      TextMeasure.display_width(full_text) <= width and
          plain_segments?(segments) ->
        [Components.text(content: full_text)]

      TextMeasure.display_width(full_text) <= width ->
        [inline_row(prefix, segments)]

      true ->
        wrap_plain_lines(prefix, plain_text, width)
    end
  end

  defp plain_segments?(segments) do
    Enum.all?(segments, fn {_text, style} -> style == %{} end)
  end

  defp inline_row(prefix, segments) do
    spans = Enum.map(segments, &segment_text/1)

    children =
      if prefix == "",
        do: spans,
        else: [Components.text(content: prefix) | spans]

    Components.row(gap: 0, children: children)
  end

  defp segment_text({text, style}) when map_size(style) == 0 do
    Components.text(content: text)
  end

  defp segment_text({text, style}),
    do: Components.text(content: text, style: style)

  defp wrap_plain_lines(prefix, text, width) do
    # Wrap to width minus the prefix (e.g. a list marker), or every line
    # after the first would exceed `width` once the prefix is prepended.
    # Continuation lines get the same amount of blank indent so wrapped
    # text lines up under the first line's text, not the marker.
    prefix_width = TextMeasure.display_width(prefix)
    indent = String.duplicate(" ", prefix_width)
    wrap_width = max(width - prefix_width, 1)

    case TextLayout.wrap(text, wrap_width, :normal) do
      [] ->
        [Components.text(content: prefix)]

      [first | rest] ->
        [
          Components.text(content: prefix <> first)
          | Enum.map(rest, &Components.text(content: indent <> &1))
        ]
    end
  end

  # --- Built-in regex-based rendering (no deps) ---

  @doc false
  @spec render_with_builtin(String.t(), non_neg_integer()) :: [map()]
  def render_with_builtin(markdown_text, width) do
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

  defp parse_blocks([line | rest], width, acc) do
    elements = parse_line(line, width)
    parse_blocks(rest, width, Enum.reverse(elements) ++ acc)
  end

  defp parse_line("# " <> text, _width) do
    [
      Components.text(
        content: "# " <> strip_inline(text),
        style: @heading_style
      )
    ]
  end

  defp parse_line("## " <> text, _width) do
    [
      Components.text(
        content: "## " <> strip_inline(text),
        style: @heading_style
      )
    ]
  end

  defp parse_line("### " <> text, _width) do
    [
      Components.text(
        content: "### " <> strip_inline(text),
        style: @heading_style
      )
    ]
  end

  defp parse_line("---" <> _, width) do
    [
      Components.text(
        content: String.duplicate("-", min(@hr_width, width)),
        style: @hr_style
      )
    ]
  end

  defp parse_line("***" <> _, width) do
    [
      Components.text(
        content: String.duplicate("-", min(@hr_width, width)),
        style: @hr_style
      )
    ]
  end

  defp parse_line("> " <> text, _width) do
    [
      Components.text(
        content: @blockquote_prefix <> strip_inline(text),
        style: @blockquote_style
      )
    ]
  end

  defp parse_line("- " <> text, width) do
    render_segments_line(builtin_segments(text), width, @ul_prefix)
  end

  defp parse_line("* " <> text, width) do
    render_segments_line(builtin_segments(text), width, @ul_prefix)
  end

  defp parse_line(line, width) do
    # Check for ordered list: "1. text", "2. text", etc.
    case Regex.run(~r/^(\d+)\.\s+(.*)/, line) do
      [_, num, text] ->
        render_segments_line(builtin_segments(text), width, "  #{num}. ")

      _ ->
        render_segments_line(builtin_segments(line), width)
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

  # `builtin_segments/1` mirrors `inline_segments/1` for the built-in
  # (non-Earmark) path. Match precedence follows alternation order: code
  # span, then bold, then em, then links. Unmatched markers pass through
  # as literal text.
  @builtin_pattern ~r/`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_|\[([^\]]+)\]\(([^)]+)\)/

  defp builtin_segments(text) do
    scan_builtin_segments(text, [])
  end

  defp scan_builtin_segments("", acc), do: Enum.reverse(acc)

  defp scan_builtin_segments(text, acc) do
    case Regex.run(@builtin_pattern, text, return: :index) do
      nil ->
        Enum.reverse([{text, %{}} | acc])

      [{whole_start, whole_len} | groups] ->
        before = String.slice(text, 0, whole_start)
        rest = String.slice(text, (whole_start + whole_len)..-1//1)
        {seg_text, style} = classify_builtin_match(text, groups)

        acc = if before == "", do: acc, else: [{before, %{}} | acc]
        acc = [{seg_text, style} | acc]

        scan_builtin_segments(rest, acc)
    end
  end

  # `Regex.run/3` with `return: :index` trims trailing non-participating
  # capture groups from the result (an Erlang `:re` quirk), so the groups
  # list length varies depending on which alternative matched -- pad it
  # back out to the full 7-group shape before pattern matching.
  defp classify_builtin_match(text, groups) do
    padded = groups ++ List.duplicate({-1, 0}, 7 - length(groups))
    [code, bold1, bold2, em1, em2, link_text, link_url] = padded

    cond do
      code != {-1, 0} ->
        {slice_group(text, code), @code_style}

      bold1 != {-1, 0} ->
        {slice_group(text, bold1), %{bold: true}}

      bold2 != {-1, 0} ->
        {slice_group(text, bold2), %{bold: true}}

      em1 != {-1, 0} ->
        {slice_group(text, em1), %{italic: true}}

      em2 != {-1, 0} ->
        {slice_group(text, em2), %{italic: true}}

      true ->
        link = slice_group(text, link_text)
        url = slice_group(text, link_url)
        {link <> " (" <> url <> ")", %{}}
    end
  end

  defp slice_group(text, {start, len}), do: String.slice(text, start, len)

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_until_fence(["```" <> _ | rest], acc), do: {Enum.reverse(acc), rest}

  defp take_until_fence([line | rest], acc),
    do: take_until_fence(rest, [line | acc])
end
