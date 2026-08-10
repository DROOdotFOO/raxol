defmodule Raxol.UI.Components.MarkdownRenderer do
  @moduledoc """
  Renders Markdown text into styled Raxol elements for terminal display.

  Supports headings, bold, italic, code spans, fenced code blocks
  (``` / ~~~), lists (ul/ol), blockquotes, horizontal rules, links, and
  GFM tables. Parsing is the built-in regex parser, unconditionally.

  There used to be a second, preferred path here: `EarmarkParser` whenever
  `Code.ensure_loaded?/1` found it. That made the parser depend on which
  environment the code ran in -- `ex_doc` pulls EarmarkParser into `:dev`
  transitively, so `mix raxol.playground` parsed with Earmark while the
  test suite parsed with the builtin and proved nothing about it. The
  divergences that hid there: no GFM table support at all (tables rendered
  as a vertical list of one cell per line), and any fence whose info string
  had more than one word (```` ```elixir title=demo ````) parsed as an
  inline code span instead of a code block, losing both the language label
  and syntax highlighting. It was also ~30x slower on the streaming suite,
  which matters because `Harness.MarkdownBody` re-parses the whole buffer
  on every delta -- and that module states all of its stable-prefix,
  byte-cap and mid-grapheme-cut guarantees against the BUILTIN parser as
  its oracle, so the swap silently voided them in the one environment the
  harness actually runs in. One parser, one behavior, everywhere.

  Overflowing lines wrap through the shared `TextLayout.wrap/4` `:pretty`
  engine (Knuth-Plass), and inline styling survives the break: the wrapped
  line boundaries are applied back to the original styled segments, so a
  span split across two lines keeps its style on both halves.

  Fenced code blocks reuse `Raxol.UI.Components.CodeBlock.render_lines/3`
  (the same `SyntaxHighlighter` path as DiffViewer). The fence info string
  selects the lexer but is not displayed. Pass `:syntax_theme` (default
  `:one_dark`) to pick a Makeup style.

  Trust note: a new output surface added to a shared component inherits
  the component's OWN trust contract, not the calling path's. This
  module's contract is "callers may pass untrusted text", so control-byte
  sanitization happens at THIS module's own boundary
  (`render_with_builtin/3`, before the text is split into lines) rather
  than being left to callers -- some callers pre-strip already (the
  harness path's `Harness.MarkdownBody`, making this redundant-but-cheap
  there), others don't (the playground's `DemoHelpers.markdown/2`), and a
  shared component can't assume which kind of caller it has.
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.Components.CodeBlock
  alias Raxol.UI.Components.Harness.TextUtil
  alias Raxol.UI.Components.Table
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_syntax_theme :one_dark
  @heading_style %{bold: true, fg: :cyan}
  @hr_style %{fg: :dim}
  @code_style %{fg: :yellow}
  @blockquote_style %{fg: :green}
  @link_style %{fg: :cyan, underline: true}
  # Middle dot, not "*" -- the asterisk is the SOURCE marker; echoing it
  # back reads as unparsed markup rather than as a rendered bullet.
  @ul_prefix "  · "
  @blockquote_prefix "│ "
  # Leading indent on every fenced-code body line.
  @code_indent "  "
  # GFM tables never shrink a column to zero width. Below this floor columns stop shrinking:
  # cells are clipped to the floor with an ellipsis and the row as a whole
  # is then wider than `width`, so the layout wraps/overflows that line
  # like any other long text() -- NOT a horizontal scroll (there is no
  # scroll surface here; "scrollable" is the aspirational end state).
  @min_col_width 3

  @spec init(map()) ::
          {:ok,
           %{
             markdown_text: String.t(),
             width: non_neg_integer(),
             syntax_theme: atom() | term()
           }}
  @impl true
  def init(props) do
    state =
      Map.merge(
        %{
          markdown_text: "",
          width: @default_width,
          syntax_theme: @default_syntax_theme
        },
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

  @spec render(map(), map()) :: map()
  @impl true
  def render(state, _context) do
    markdown_text = state[:markdown_text] || ""
    width = state[:width] || Raxol.Core.Defaults.terminal_width()
    theme = state[:syntax_theme] || @default_syntax_theme

    elements = render_with_builtin(markdown_text, width, theme)

    # gap: 0 — block spacing is expressed by explicit blank-line elements;
    # the :column dialect default (gap 1) would double every gap.
    %{type: :column, children: elements, style: %{}, gap: 0}
  end

  defp hr_element(width) do
    # Continuous box-drawing rule, full content width (not ASCII hyphens).
    Components.text(
      content: String.duplicate("─", max(width, 1)),
      style: @hr_style
    )
  end

  # The info string is UNTRUSTED input (see the moduledoc's trust note),
  # so it is made safe here, at this module's own boundary rather than on
  # any particular calling path: all C0 controls, DEL, and C1 bytes are
  # stripped BEFORE word extraction (`~r/\s+/` does not treat ESC as
  # whitespace, so `elixir\e[2J` would otherwise survive as one "word"),
  # and the surviving word is clamped. It no longer reaches a text
  # surface -- it only picks the highlighter's lexer -- but it is still
  # sanitized at the source so that reintroducing a visible label, or a
  # lexer registry that echoes unknown names, cannot resurrect the hole.
  @info_string_control_chars ~r/[\x00-\x1F\x7F\x{0080}-\x{009F}]/u
  @max_lang_label_width 32

  # The language tag is the first whitespace-separated word of the
  # sanitized info string, a "language-" class prefix stripped first (a
  # no-op when there is none, e.g. a bare fence info string like `elixir
  # title=demo`). Absent/blank/sanitized-to-empty input yields `nil`, not
  # an empty string -- keeping the "no language" case as a single value
  # simplifies callers.
  defp lang_word(value) do
    value
    |> to_string()
    |> String.replace(@info_string_control_chars, "")
    |> String.replace_prefix("language-", "")
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> clamp_lang()
  end

  defp clamp_lang(nil), do: nil

  defp clamp_lang(lang),
    do: TextLayout.truncate(lang, @max_lang_label_width, :ellipsis)

  # --- Shared segment rendering (fits-vs-wrapped) ---
  #
  # `[{text, style}, ...]` segments render as: a plain `text` element when
  # unstyled; a `:row` of styled spans when styled and the full line fits
  # `width`; otherwise one styled `:row` per wrapped line (see
  # `soft_wrap_segments/2` -- styles survive the break).

  defp render_segments_line(segments, width, prefix \\ "", prefix_style \\ %{})

  defp render_segments_line(segments, width, prefix, prefix_style) do
    segments = Enum.reject(segments, fn {text, _style} -> text == "" end)
    plain_text = Enum.map_join(segments, "", &elem(&1, 0))
    full_text = prefix <> plain_text

    cond do
      segments == [] and prefix == "" ->
        [Components.text(content: "")]

      TextMeasure.display_width(full_text) <= width and
        plain_segments?(segments) and map_size(prefix_style) == 0 ->
        [Components.text(content: full_text)]

      TextMeasure.display_width(full_text) <= width ->
        [inline_row(prefix, segments, prefix_style)]

      true ->
        # Segment-aware wrap keeps bold/code/link styles across soft breaks.
        wrap_segments(prefix, prefix_style, segments, width)
    end
  end

  defp plain_segments?(segments) do
    Enum.all?(segments, fn {_text, style} ->
      style == %{} or map_size(style) == 0
    end)
  end

  defp inline_row(prefix, segments, prefix_style) do
    spans = Enum.map(segments, &segment_text/1)

    children =
      if prefix == "" do
        spans
      else
        [Components.text(content: prefix, style: prefix_style) | spans]
      end

    Components.row(gap: 0, children: children)
  end

  defp segment_text({text, style}) when map_size(style) == 0 do
    Components.text(content: text)
  end

  defp segment_text({text, style}) do
    # Promote :link onto the element so LayoutEngine/OSC-8 pick it up;
    # keep underline + color in the style map for paint.
    Components.text(content: text, style: style, link: Map.get(style, :link))
  end

  # Soft-wrap a segment list, re-emitting a row per visual line. The first
  # line carries `prefix`; continuations re-use the same prefix when it is
  # a blockquote gutter, otherwise a same-width blank indent (lists).
  defp wrap_segments(prefix, prefix_style, segments, width) do
    prefix_width = TextMeasure.display_width(prefix)
    wrap_width = max(width - prefix_width, 1)
    cont_prefix = continuation_prefix(prefix, prefix_style)

    segments
    |> soft_wrap_segments(wrap_width)
    |> Enum.with_index()
    |> Enum.map(fn {line_segs, idx} ->
      p = if idx == 0, do: prefix, else: cont_prefix

      ps =
        if idx == 0 or blockquote_prefix?(prefix), do: prefix_style, else: %{}

      inline_row(p, line_segs, ps)
    end)
  end

  defp blockquote_prefix?(prefix), do: prefix == @blockquote_prefix

  defp continuation_prefix(prefix, _prefix_style) do
    if blockquote_prefix?(prefix) do
      prefix
    else
      String.duplicate(" ", TextMeasure.display_width(prefix))
    end
  end

  # Wraps a `{text, style}` segment list into lines of at most `wrap_width`
  # display cells, delegating the break-point choice to the shared
  # `TextLayout.wrap/4` `:pretty` engine (Knuth-Plass) that every other
  # wrapped text in the UI uses.
  #
  # This used to pick breaks itself, and its unit of breaking was the
  # SEGMENT, not the word: a segment that didn't fit the remaining budget
  # moved whole to the next line, and only a segment wider than the entire
  # line was split at all. So one long unstyled run after a styled span --
  # `> Prefer **structured** styles — never embed raw ANSI...` -- emitted
  # "Prefer structured" / the entire rest of the sentence overflowing its
  # line / a lone trailing ".". Words were never a break candidate, so no
  # amount of width made it wrap sensibly.
  #
  # Delegating means measuring is no longer this module's job either
  # (Pretty force-splits a word wider than the line itself). Styles are
  # re-attached afterwards by slicing the ORIGINAL segments along the
  # returned line boundaries, so a break inside a styled span keeps that
  # span's style on both halves.
  defp soft_wrap_segments(segments, wrap_width) do
    plain = Enum.map_join(segments, "", &elem(&1, 0))

    plain
    |> TextLayout.wrap(wrap_width, :normal, :pretty)
    |> reslice_segments(segments, plain)
  end

  defp reslice_segments(lines, segments, plain) do
    {rows, _cursor} =
      Enum.map_reduce(lines, 0, fn line, cursor ->
        case line_span(plain, line, cursor) do
          {start, len} -> {slice_segments(segments, start, len), start + len}
          # The wrapper is not supposed to emit a line that isn't a
          # substring of its input, but if it ever does, the text still
          # reaches the screen -- unstyled rather than dropped.
          nil -> {[{line, %{}}], cursor}
        end
      end)

    Enum.reject(rows, &(&1 == []))
  end

  # Locates `line` in `plain` at or after `cursor`, in BYTES (the offsets
  # feed `binary_part/3` below). Searching forward from a cursor rather
  # than from 0 is what keeps a line that repeats earlier in the paragraph
  # from re-matching the earlier copy.
  defp line_span(_plain, "", cursor), do: {cursor, 0}

  defp line_span(plain, line, cursor) do
    rest = TextMeasure.slice_bytes(plain, {cursor, byte_size(plain) - cursor})

    case :binary.match(rest, line) do
      {offset, len} -> {cursor + offset, len}
      :nomatch -> fuzzy_line_span(rest, line, cursor)
    end
  end

  # `:pretty` collapses every whitespace run in its input to a single
  # space (`Pretty`'s tokenizer emits one `" "` token per run,
  # regardless of the run's original width), so a returned `line` is only
  # a literal substring of `plain` when the source had single spaces
  # throughout. Source text with a double space, or leading/trailing
  # space inside a wrapped span, makes the exact byte search above
  # miss -- this retries whitespace-insensitively (each space in `line`
  # matches one-or-more whitespace chars in `plain`) before the caller
  # gives up and emits the line unstyled.
  defp fuzzy_line_span(rest, line, cursor) do
    # Escape each space-delimited piece BEFORE joining with the raw
    # (unescaped) `\s+` construct -- escaping the whole line first and
    # then substituting spaces would double-escape the backslash
    # `Regex.escape/1` itself inserts before a literal space, turning the
    # intended whitespace class into "a literal backslash, then one-or-
    # more literal 's' characters" instead.
    pattern =
      line
      |> String.split(" ")
      |> Enum.map_join("\\s+", &Regex.escape/1)

    case Regex.run(Regex.compile!(pattern, "u"), rest, return: :index) do
      [{offset, len}] -> {cursor + offset, len}
      _ -> nil
    end
  end

  # Cuts the byte range [start, start + len) out of the segment list,
  # preserving each segment's style on whatever part of it survives.
  defp slice_segments(segments, start, len) do
    stop = start + len

    {pieces, _offset} =
      Enum.flat_map_reduce(segments, 0, fn {text, style}, offset ->
        size = byte_size(text)
        from = max(start, offset)
        to = min(stop, offset + size)

        piece =
          if to > from do
            [{TextMeasure.slice_bytes(text, {from - offset, to - from}), style}]
          else
            []
          end

        {piece, offset + size}
      end)

    pieces
  end

  # --- Built-in regex-based rendering (no deps) ---

  @doc false
  @spec render_with_builtin(String.t(), non_neg_integer()) :: [map()]
  def render_with_builtin(markdown_text, width),
    do: render_with_builtin(markdown_text, width, @default_syntax_theme)

  @doc false
  @spec render_with_builtin(String.t(), non_neg_integer(), atom() | term()) ::
          [map()]
  def render_with_builtin(markdown_text, width, theme) do
    markdown_text
    |> TextUtil.sanitize_controls()
    |> String.split("\n")
    |> parse_blocks(width, theme, [])
    |> Enum.reverse()
  end

  defp parse_blocks([], _width, _theme, acc), do: acc

  # Fenced code block. GFM allows either ```` ``` ```` or `~~~` as the
  # fence marker; a fence only closes on a line using the SAME marker it
  # opened with, so a stray line of the other marker type while the fence
  # is open is fence CONTENT, not a closer (mismatched fences never
  # prematurely end the block). Whatever follows the marker on the opening
  # line is the info string -- its first word (if any) becomes the
  # displayed language label; the rest (e.g. a `title=demo` attribute) is
  # discarded, same as it always was before labels existed.
  defp parse_blocks(["```" <> info | rest], width, theme, acc) do
    parse_fenced_block("```", lang_word(info), rest, width, theme, acc)
  end

  defp parse_blocks(["~~~" <> info | rest], width, theme, acc) do
    parse_fenced_block("~~~", lang_word(info), rest, width, theme, acc)
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
  defp parse_blocks([header, sep | rest], width, theme, acc) do
    if table_row?(header) and separator_row?(sep) do
      header_cells = split_table_row(header)

      {row_lines, remaining} =
        take_table_rows(rest, [], length(header_cells), leading_pipe?(header))

      body_rows = Enum.map(row_lines, &split_table_row/1)
      aligns = separator_aligns(sep)
      table_elements = render_table_rows(header_cells, body_rows, width, aligns)
      parse_blocks(remaining, width, theme, Enum.reverse(table_elements) ++ acc)
    else
      elements = parse_line(header, width)
      parse_blocks([sep | rest], width, theme, Enum.reverse(elements) ++ acc)
    end
  end

  defp parse_blocks([line | rest], width, theme, acc) do
    elements = parse_line(line, width)
    parse_blocks(rest, width, theme, Enum.reverse(elements) ++ acc)
  end

  # ATX heading: 1-6 `#` characters followed by a space (GFM/CommonMark
  # caps headings at h6; `#######` and beyond fall through to the
  # non-heading clauses below as literal text, same as a bare "#" with no
  # trailing space always has). One regex-driven clause replaces what
  # used to be three duplicated `"# " <> text` / `"## " <> text` /
  # `"### " <> text` function heads capped at h3, so h4-h6 render with the
  # same heading style instead of falling through to plain-paragraph
  # parsing with their `####` markers left unstyled in the visible text.
  @heading_pattern ~r/^(\#{1,6}) (.*)/

  defp parse_line(line, width) do
    case Regex.run(@heading_pattern, line) do
      [_, hashes, text] -> render_heading_line(hashes <> " ", text, width)
      nil -> parse_non_heading_line(line, width)
    end
  end

  # Thematic break — continuous box-drawing rule, full content width.
  defp parse_non_heading_line("---" <> rest, width) do
    if String.trim(rest) == "" or String.match?(rest, ~r/^-+\s*$/) do
      [hr_element(width)]
    else
      render_segments_line(builtin_segments("---" <> rest), width)
    end
  end

  defp parse_non_heading_line("***" <> rest, width) do
    if String.trim(rest) == "" or String.match?(rest, ~r/^\*+\s*$/) do
      [hr_element(width)]
    else
      render_segments_line(builtin_segments("***" <> rest), width)
    end
  end

  defp parse_non_heading_line("> " <> text, width) do
    segments =
      text
      |> builtin_segments()
      |> Enum.map(fn {t, s} -> {t, Map.merge(@blockquote_style, s)} end)

    render_segments_line(segments, width, @blockquote_prefix, @blockquote_style)
  end

  defp parse_non_heading_line("- " <> text, width) do
    render_segments_line(builtin_segments(text), width, @ul_prefix)
  end

  defp parse_non_heading_line("* " <> text, width) do
    render_segments_line(builtin_segments(text), width, @ul_prefix)
  end

  defp parse_non_heading_line(line, width) do
    # Check for ordered list: "1. text", "2. text", etc.
    case Regex.run(~r/^(\d+)\.\s+(.*)/, line) do
      [_, num, text] ->
        render_segments_line(builtin_segments(text), width, "  #{num}. ")

      _ ->
        render_segments_line(builtin_segments(line), width)
    end
  end

  defp render_heading_line(prefix, text, width) do
    segments =
      text
      |> builtin_segments()
      |> Enum.map(fn {t, s} -> {t, Map.merge(@heading_style, s)} end)

    # Heading lines also get the underline chrome for h1/h2 in Earmark;
    # builtin path keeps a single styled line (prefix + body).
    render_segments_line(segments, width, prefix, @heading_style)
  end

  # Inline markup scanner. Match precedence follows alternation order:
  # code span, then bold+italic, then bold, then italic, then links.
  # Unmatched markers pass through as literal text.
  #
  # The triple-marker alternatives MUST precede the double ones. Each
  # emphasis body is `[^*]+` / `[^_]+`, which cannot cross its own marker
  # character, so on `***both***` the `\*\*(...)\*\*` alternative fails at
  # offset 0 (the third `*` is not a body character) and `:re` retries one
  # character in, where it happily matches `**both**` -- yielding a bold
  # "both" wrapped in two literal leftover asterisks. Matching the triple
  # form first is what makes `***x***` bold+italic instead.
  #
  # Every underscore alternative additionally requires NOT being flanked
  # by a word character on either side (CommonMark's intraword-emphasis
  # rule for `_`, which `*` is deliberately exempt from). Without this an
  # ordinary `snake_case_identifier` matches `_case_` as italic, silently
  # deleting the underscores from otherwise plain text -- common in any
  # dev-tool content (code identifiers in prose, table cells).
  @builtin_pattern ~r/`([^`]+)`|\*\*\*([^*]+)\*\*\*|(?<!\w)___([^_]+)___(?!\w)|\*\*([^*]+)\*\*|(?<!\w)__([^_]+)__(?!\w)|\*([^*]+)\*|(?<!\w)_([^_]+)_(?!\w)|\[([^\]]+)\]\(([^)]+)\)/

  defp builtin_segments(text) do
    scan_builtin_segments(text, [])
  end

  defp scan_builtin_segments("", acc), do: Enum.reverse(acc)

  defp scan_builtin_segments(text, acc) do
    case Regex.run(@builtin_pattern, text, return: :index) do
      nil ->
        Enum.reverse([{text, %{}} | acc])

      [{whole_start, whole_len} | groups] ->
        # BYTE offsets, not grapheme offsets -- `:re` counts bytes, so these
        # must be cut with `binary_part/3`. `String.slice/3` counts
        # graphemes, and any multibyte character earlier in the line (an em
        # dash, "—", is 3 bytes / 1 grapheme) desynchronized the two by the
        # excess byte count: the cut landed mid-word, so a span lost leading
        # characters, its markers survived into the visible text, and its
        # color started partway through the word.
        before = TextMeasure.slice_bytes(text, {0, whole_start})
        after_start = whole_start + whole_len

        rest =
          TextMeasure.slice_bytes(
            text,
            {after_start, byte_size(text) - after_start}
          )

        {seg_text, style} = classify_builtin_match(text, groups)

        acc = if before == "", do: acc, else: [{before, %{}} | acc]
        acc = [{seg_text, style} | acc]

        scan_builtin_segments(rest, acc)
    end
  end

  # `Regex.run/3` with `return: :index` trims trailing non-participating
  # capture groups from the result (an Erlang `:re` quirk), so the groups
  # list length varies depending on which alternative matched -- pad it
  # back out to the full 9-group shape before pattern matching.
  defp classify_builtin_match(text, groups) do
    padded = groups ++ List.duplicate({-1, 0}, 9 - length(groups))
    [code, tri1, tri2, bold1, bold2, em1, em2, link_text, link_url] = padded

    cond do
      code != {-1, 0} ->
        {slice_group(text, code), @code_style}

      tri1 != {-1, 0} ->
        {slice_group(text, tri1), %{bold: true, italic: true}}

      tri2 != {-1, 0} ->
        {slice_group(text, tri2), %{bold: true, italic: true}}

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
        label = if link == "", do: url, else: link
        {label, Map.put(@link_style, :link, url)}
    end
  end

  # Byte offsets from `:re` -- see `TextMeasure`'s "three units" note.
  defp slice_group(text, span), do: TextMeasure.slice_bytes(text, span)

  defp parse_fenced_block(marker, lang, rest, width, theme, acc) do
    {code_lines, remaining} = take_until_fence(rest, marker, [])
    code_text = Enum.join(code_lines, "\n")
    elements = fenced_code_elements(code_text, lang, theme)

    # Same reverse-then-cons convention every other `parse_blocks` clause
    # uses (`acc` is fully reversed once at the very end, in
    # `render_with_builtin/2`) -- pushing this block's elements on
    # pre-reversed keeps them in correct reading order after that final
    # reversal, exactly like a single `parse_line/2` result would be.
    parse_blocks(remaining, width, theme, Enum.reverse(elements) ++ acc)
  end

  # Fence block shape: blank, code lines (one row element each from
  # CodeBlock/SyntaxHighlighter), blank.
  #
  # The info string selects the highlighter's lexer but is NOT displayed --
  # there used to be a dim label line above the body carrying the language
  # name. The token colors already say what the language is, and the label
  # spent a line of vertical budget restating the fence's own source text.
  #
  # Shape law (MarkdownBody streaming): one element per source code line
  # so stable-prefix freezes stay line-granular. Do not collapse into a
  # single column element.
  defp fenced_code_elements(code_text, lang, theme) do
    language = lang || "text"

    code_elements =
      code_text
      |> CodeBlock.render_lines(language, theme)
      |> Enum.map(&indent_code_row/1)

    blank = Components.text(content: "")

    Enum.concat([[blank], code_elements, [blank]])
  end

  # Leading two-space gutter on every code body line (matches the pre-
  # highlighter indent so MarkdownBody phantom/"  " shape stays stable).
  defp indent_code_row(%{type: :row, children: children} = row)
       when is_list(children) do
    %{row | children: [Components.text(content: @code_indent) | children]}
  end

  defp indent_code_row(other), do: other

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
    |> Enum.map(&table_cell_text/1)
  end

  # Table cells hold inline Markdown like any other text, but the Table
  # component lays out plain strings -- it has no styled-span cell. So the
  # markers are consumed (`builtin_segments/1`, the same parse every other
  # line gets) and only the visible text is kept: `**A**` -> `A`,
  # `[foo](url)` -> `foo`. Emphasis is lost, but the alternative is worse
  # than lost styling -- the raw markers would render literally AND be
  # counted by `markdown_column_widths/2`, so every column would also be
  # mis-sized by the width of its own markup.
  defp table_cell_text(cell) do
    cell
    |> String.trim()
    |> builtin_segments()
    |> Enum.map_join("", &elem(&1, 0))
  end

  # GFM alignment, read off the separator row: `:---` left, `---:` right,
  # `:---:` center. A cell with neither colon is `:left`, matching the
  # default `render_table_rows/4` falls back to for a short/absent list.
  defp separator_aligns(sep) do
    sep
    |> String.trim()
    |> String.trim("|")
    |> String.split("|")
    |> Enum.map(fn cell ->
      trimmed = String.trim(cell)

      case {String.starts_with?(trimmed, ":"), String.ends_with?(trimmed, ":")} do
        {true, true} -> :center
        {false, true} -> :right
        _ -> :left
      end
    end)
  end

  # Consumes subsequent lines that still look like a row of THIS table:
  # the same number of cells as the header, AND the same leading-"|"
  # convention the header itself used. A blank line, a non-tabular line, or
  # a "|"-containing line that doesn't match that shape stops the row and
  # is left in `remaining` for normal block parsing -- GFM tables don't
  # span a blank/non-tabular-shaped line.
  #
  # The leading-"|" test is taken FROM THE HEADER rather than hardcoded to
  # `true`. Requiring it unconditionally silently dropped every body row of
  # a perfectly valid pipe-less table (`Name | Qty` / `--- | ---` / `foo |
  # 1`, a shape LLMs emit constantly): the header still matched, so a
  # header-only table rendered and the rows fell out below it as raw prose
  # lines. Deriving it keeps the original guard exactly as strong for
  # pipe-delimited tables -- where a stray "|" in prose would otherwise be
  # enough to extend a 2-column table, since cell count alone can't rule
  # that out -- while letting the pipe-less form absorb its own rows.
  defp take_table_rows([line | rest], acc, col_count, leading_pipe?) do
    if table_row_shaped?(line, col_count, leading_pipe?) do
      take_table_rows(rest, [line | acc], col_count, leading_pipe?)
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp take_table_rows([], acc, _col_count, _leading_pipe?),
    do: {Enum.reverse(acc), []}

  defp table_row_shaped?(line, col_count, leading_pipe?) do
    table_row?(line) and
      leading_pipe?(line) == leading_pipe? and
      length(split_table_row(line)) == col_count
  end

  defp leading_pipe?(line), do: String.starts_with?(String.trim(line), "|")

  defp render_table_rows([], [], _width, _aligns), do: []

  defp render_table_rows(header_cells, body_rows, width, aligns) do
    col_count =
      Enum.max([length(header_cells) | Enum.map(body_rows, &length/1)])

    header = pad_row(header_cells, col_count)
    rows = Enum.map(body_rows, &pad_row(&1, col_count))

    natural_widths = markdown_column_widths([header | rows], col_count)
    final_widths = fit_widths(natural_widths, width, col_count)

    columns =
      header
      |> Enum.zip(final_widths)
      |> Enum.with_index()
      |> Enum.map(fn {{label, w}, i} ->
        %{
          id: :"md_col_#{i}",
          label: label,
          width: max(w, @min_col_width),
          align: Enum.at(aligns, i) || :left
        }
      end)

    data =
      Enum.map(rows, fn row ->
        row
        |> Enum.with_index()
        |> Map.new(fn {cell, i} -> {:"md_col_#{i}", cell} end)
      end)

    {:ok, table} =
      Table.init(%{
        id: :markdown_table,
        columns: columns,
        data: data,
        options: %{
          border: :inner,
          header_separator: true,
          paginate: false,
          sortable: false,
          searchable: false
        }
      })

    rendered = Table.render(table, %{available_width: max(width, 1)})

    line_elements =
      rendered
      |> table_line_children()
      |> Enum.map(&normalize_table_element_style/1)

    line_elements ++ [Components.text(content: "")]
  end

  defp table_line_children(%{children: [body | _]}) when is_map(body) do
    Map.get(body, :children, [])
  end

  defp table_line_children(_), do: []

  # `Table.render/2` builds its cells through
  # `Raxol.Core.Renderer.View.text/2`, whose own convention is a `style:`
  # ATOM LIST (e.g. `[:bold]`, `[{:fg, :cyan}, :fg, :cyan]`), not the
  # `%{bold: true, fg: :cyan}` MAP every other element this module emits
  # uses (`Raxol.View.Components.text/1`'s convention). Splicing Table's
  # raw cells straight into this module's own tree would leak that
  # foreign representation into every consumer of `render_with_builtin/3`
  # -- including `Harness.Surface`'s `ViewText.lines/3` bridge, which
  # reads `:style` as a map unconditionally (`Map.get(style, :bold, ...)`)
  # and raises `BadMapError` the first time a rendered GFM table reaches
  # it. Re-mapped here, at this module's own output boundary, so every
  # element `render_with_builtin/3` returns keeps ONE style contract
  # regardless of which component built its cells.
  defp normalize_table_element_style(%{type: :text, style: style} = element)
       when is_list(style) do
    %{element | style: table_style_list_to_map(style)}
  end

  defp normalize_table_element_style(element), do: element

  defp table_style_list_to_map(style_list) do
    Enum.reduce(style_list, %{}, fn
      :bold, acc -> Map.put(acc, :bold, true)
      :italic, acc -> Map.put(acc, :italic, true)
      :underline, acc -> Map.put(acc, :underline, true)
      :dim, acc -> Map.put(acc, :dim, true)
      {:fg, color}, acc -> Map.put(acc, :fg, color)
      {:bg, color}, acc -> Map.put(acc, :bg, color)
      {:color, color}, acc -> Map.put(acc, :fg, color)
      # Bare color atoms (`convert_style_to_list/1`'s redundant
      # `[{:fg, color}, :fg, color]` encoding) and the bare `:fg`/`:bg`
      # tag atoms carry no information the `{:fg, _}`/`{:bg, _}` tuple
      # pair in the SAME list doesn't already capture.
      _other, acc -> acc
    end)
  end

  defp pad_row(cells, col_count) do
    cells
    |> Kernel.++(List.duplicate("", max(col_count - length(cells), 0)))
    |> Enum.take(col_count)
  end

  defp markdown_column_widths(rows, col_count) do
    for i <- 0..(col_count - 1) do
      rows
      |> Enum.map(fn row ->
        row |> Enum.at(i, "") |> TextMeasure.display_width()
      end)
      |> Enum.max()
      # +2 for Table's cell gutters so labels aren't clipped
      |> Kernel.+(2)
      |> max(@min_col_width + 2)
    end
  end

  # Shrinks natural column widths to fit `width` when possible; below the
  # min floor it stops shrinking and accepts a row wider than `width`.
  defp fit_widths(widths, width, col_count) do
    # :inner border: sum(widths) + (n-1) separators, no outer frame.
    overhead = max(col_count - 1, 0)
    budget = max(width - overhead, col_count * @min_col_width)
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
end
