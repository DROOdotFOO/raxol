defmodule Raxol.UI.Components.MarkdownRenderer do
  @moduledoc """
  Renders Markdown text into styled Raxol elements for terminal display.

  Supports headings, bold, italic, code spans, code blocks, lists,
  blockquotes, horizontal rules, and links. Uses EarmarkParser when
  available, falls back to a built-in regex parser.

  Inline styling does not survive a wrap boundary: a line that overflows
  `width` falls back to plain, unstyled wrapped text, though wrapped
  output never leaks literal Markdown marker characters.

  A fenced code block's info string (the language tag after ```` ``` ````
  or `~~~`, e.g. `elixir` in ` ```elixir `) renders as a dim label line
  above the code body. This is display-only -- no syntax highlighting is
  performed, and none is planned as part of this label. The label plus
  the plain `@code_style` code body is the seam a future highlighter
  would slot into, not something this module implements itself.
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
  # GFM tables never shrink a column to zero width. Below this floor columns stop shrinking:
  # cells are clipped to the floor with an ellipsis and the row as a whole
  # is then wider than `width`, so the layout wraps/overflows that line
  # like any other long text() -- NOT a horizontal scroll (there is no
  # scroll surface here; "scrollable" is the aspirational end state).
  @min_col_width 3

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
    lang = pre_code_language(children)
    fenced_code_elements(code_text, lang)
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

  # Earmark wraps a fenced code block's language tag in the inner `code`
  # node's `class` attr (`language-elixir` per the CommonMark convention,
  # though a bare `elixir` is accepted too via `code_language_from_attrs/1`).
  defp pre_code_language(children) when is_list(children) do
    Enum.find_value(children, fn
      {"code", attrs, _inner, _meta} -> code_language_from_attrs(attrs)
      _other -> nil
    end)
  end

  defp pre_code_language(_children), do: nil

  @doc false
  @spec code_language_from_attrs(list()) :: String.t() | nil
  def code_language_from_attrs(attrs) when is_list(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", value} -> lang_word(value)
      nil -> nil
    end
  end

  def code_language_from_attrs(_attrs), do: nil

  # The displayed language tag is the first whitespace-separated word of
  # an info string, an optional Earmark "language-" class prefix stripped
  # first (a no-op when there is none, e.g. a bare fence info string like
  # `elixir title=demo`). Absent/blank/whitespace-only input yields `nil`,
  # not an empty string -- `code_label_elements/1` treats those the same,
  # but keeping the "no label" case as a single value simplifies callers.
  defp lang_word(value) do
    value
    |> to_string()
    |> String.replace_prefix("language-", "")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
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

  # Fenced code block. GFM allows either ```` ``` ```` or `~~~` as the
  # fence marker; a fence only closes on a line using the SAME marker it
  # opened with, so a stray line of the other marker type while the fence
  # is open is fence CONTENT, not a closer (mismatched fences never
  # prematurely end the block). Whatever follows the marker on the opening
  # line is the info string -- its first word (if any) becomes the
  # displayed language label; the rest (e.g. a `title=demo` attribute) is
  # discarded, same as it always was before labels existed.
  defp parse_blocks(["```" <> info | rest], width, acc) do
    parse_fenced_block("```", lang_word(info), rest, width, acc)
  end

  defp parse_blocks(["~~~" <> info | rest], width, acc) do
    parse_fenced_block("~~~", lang_word(info), rest, width, acc)
  end

  # GFM table: a header row immediately followed by a separator-shaped row
  # (`|---|---|`). Both must be present as their own lines in the buffer --
  # a lone in-progress header (the last streamed line, no following line
  # yet) can't satisfy this 2-line lookahead, so it renders as plain text
  # rather than flashing a broken frame. The separator check is lenient
  # (`separator_row?/1` accepts a partial `|--`), so complete-header +
  # partial-separator DOES render -- a premature but well-formed frame
  # (header + separator, body rows fill in as they stream). That is the
  # intended benign streaming behavior, never a zero-width collapse.
  defp parse_blocks([header, sep | rest], width, acc) do
    if table_row?(header) and separator_row?(sep) do
      header_cells = split_table_row(header)
      {row_lines, remaining} = take_table_rows(rest, [], length(header_cells))
      body_rows = Enum.map(row_lines, &split_table_row/1)
      table_elements = render_table_rows(header_cells, body_rows, width)
      parse_blocks(remaining, width, Enum.reverse(table_elements) ++ acc)
    else
      elements = parse_line(header, width)
      parse_blocks([sep | rest], width, Enum.reverse(elements) ++ acc)
    end
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

  defp parse_fenced_block(marker, lang, rest, width, acc) do
    {code_lines, remaining} = take_until_fence(rest, marker, [])
    code_text = Enum.join(code_lines, "\n")
    elements = fenced_code_elements(code_text, lang)

    # Same reverse-then-cons convention every other `parse_blocks` clause
    # uses (`acc` is fully reversed once at the very end, in
    # `render_with_builtin/2`) -- pushing this block's elements on
    # pre-reversed keeps them in correct reading order after that final
    # reversal, exactly like a single `parse_line/2` result would be.
    parse_blocks(remaining, width, Enum.reverse(elements) ++ acc)
  end

  # Shared by both the Earmark AST path (`ast_node_to_elements/2` for
  # `"pre"`) and this builtin path, so the two parsers can't drift on how
  # the language label sits relative to the surrounding blank lines and
  # code body: blank, optional dim label, code lines, blank. `lang` is
  # `nil` (or an empty/absent tag) -> no label line at all, not an empty one.
  defp fenced_code_elements(code_text, lang) do
    code_elements =
      code_text
      |> String.split("\n")
      |> Enum.map(fn line ->
        Components.text(content: "  " <> line, style: @code_style)
      end)

    blank = Components.text(content: "")

    Enum.concat([[blank], code_label_elements(lang), code_elements, [blank]])
  end

  defp code_label_elements(nil), do: []
  defp code_label_elements(""), do: []

  defp code_label_elements(lang) do
    [Components.text(content: "  " <> lang, style: %{dim: true})]
  end

  defp take_until_fence([], _marker, acc), do: {Enum.reverse(acc), []}

  defp take_until_fence([line | rest], marker, acc) do
    if String.starts_with?(line, marker) do
      {Enum.reverse(acc), rest}
    else
      take_until_fence(rest, marker, [line | acc])
    end
  end

  # --- GFM table rendering (builtin path) ---
  #
  # A permissive-by-design detector: any line containing "|" is a
  # candidate row; a candidate is a separator iff every "|"-delimited cell
  # is only dashes (optionally `:`-flanked for alignment). This is
  # deliberately lenient about a truncated separator (`"|---|--"` still
  # matches) -- during streaming that just renders a slightly-premature
  # table frame one prefix earlier, never a crash or a raw-pipe flash.

  defp table_row?(line) do
    trimmed = String.trim(line)
    trimmed != "" and String.contains?(trimmed, "|")
  end

  defp separator_row?(line) do
    String.contains?(line, "|") and
      line
      |> String.trim()
      |> String.trim("|")
      |> String.split("|")
      |> then(fn cells ->
        cells != [] and Enum.all?(cells, &separator_cell?/1)
      end)
  end

  defp separator_cell?(cell), do: Regex.match?(~r/^\s*:?-+:?\s*$/, cell)

  defp split_table_row(line) do
    line
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  # Consumes subsequent lines that still look like a row of THIS table: a
  # leading "|" (the header/separator convention every existing table in
  # this codebase follows) AND the same number of cells as the header. A
  # blank line, a non-tabular line, or a "|"-containing line that doesn't
  # match that shape (ordinary prose that happens to contain a stray "|"
  # -- cell count alone isn't enough to rule this out for a 2-column
  # table, where any single stray "|" trivially produces 2 cells) stops
  # the row and is left in `remaining` for normal block parsing -- GFM
  # tables don't span a blank/non-tabular-shaped line.
  defp take_table_rows([line | rest], acc, col_count) do
    if table_row_shaped?(line, col_count) do
      take_table_rows(rest, [line | acc], col_count)
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp take_table_rows([], acc, _col_count), do: {Enum.reverse(acc), []}

  defp table_row_shaped?(line, col_count) do
    table_row?(line) and String.starts_with?(String.trim(line), "|") and
      length(split_table_row(line)) == col_count
  end

  defp render_table_rows([], [], _width), do: []

  defp render_table_rows(header_cells, body_rows, width) do
    col_count =
      Enum.max([length(header_cells) | Enum.map(body_rows, &length/1)])

    header = pad_row(header_cells, col_count)
    rows = Enum.map(body_rows, &pad_row(&1, col_count))

    natural_widths = column_widths([header | rows], col_count)
    final_widths = fit_widths(natural_widths, width, col_count)

    header_row = table_row_text(header, final_widths)
    separator_row = table_separator_text(final_widths)
    body_texts = Enum.map(rows, &table_row_text(&1, final_widths))

    Enum.concat([header_row, separator_row | body_texts], [
      Components.text(content: "")
    ])
  end

  defp pad_row(cells, col_count) do
    cells
    |> Kernel.++(List.duplicate("", max(col_count - length(cells), 0)))
    |> Enum.take(col_count)
  end

  defp column_widths(rows, col_count) do
    for i <- 0..(col_count - 1) do
      rows
      |> Enum.map(fn row ->
        row |> Enum.at(i, "") |> TextMeasure.display_width()
      end)
      |> Enum.max()
      |> max(@min_col_width)
    end
  end

  # Shrinks natural column widths to fit `width` when possible; below the
  # `@min_col_width` floor it stops shrinking and accepts a row wider than
  # `width` (the documented "scrollable" degradation) rather than crush
  # any column to zero.
  defp fit_widths(widths, width, col_count) do
    overhead = 3 * col_count + 1
    budget = width - overhead
    total = Enum.sum(widths)

    cond do
      total <= budget ->
        widths

      budget < col_count * @min_col_width ->
        List.duplicate(@min_col_width, col_count)

      true ->
        shrink_proportionally(widths, budget)
    end
  end

  defp shrink_proportionally(widths, budget) do
    total = Enum.sum(widths)
    Enum.map(widths, fn w -> max(@min_col_width, div(w * budget, total)) end)
  end

  defp table_row_text(cells, widths) do
    cells_str =
      cells
      |> Enum.zip(widths)
      |> Enum.map_join(" | ", fn {cell, w} -> pad_cell(cell, w) end)

    Components.text(content: "| " <> cells_str <> " |")
  end

  defp table_separator_text(widths) do
    seps = Enum.map_join(widths, "-|-", &String.duplicate("-", &1))
    Components.text(content: "|-" <> seps <> "-|", style: @hr_style)
  end

  defp pad_cell(text, width) do
    display_w = TextMeasure.display_width(text)

    cond do
      display_w == width -> text
      display_w < width -> text <> String.duplicate(" ", width - display_w)
      true -> TextLayout.truncate(text, width, :ellipsis)
    end
  end
end
