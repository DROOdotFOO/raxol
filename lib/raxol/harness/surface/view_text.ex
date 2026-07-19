defmodule Raxol.Harness.Surface.ViewText do
  @moduledoc """
  The assembled harness's small view-map -> plain-text-lines bridge.

  Every harness Component in `Raxol.UI.Components.Harness.*` (`Block`,
  `BlockBody`, `Composer`, and everything `BodyProvider` mounts) renders a
  plain view map (`Raxol.View.Components`-shaped: `%{type: :column,
  children: [...]}` / `%{type: :text, content:, style:}`) meant for the
  normal `Preparer -> LayoutEngine -> UIRenderer` pipeline. The append-path
  / footer-viewport substrate (`InlineAuthority`/`FlatAuthority`) bypasses
  that pipeline entirely -- it is a byte-level, pinned-region writer whose
  `seal/2`, `repaint/2`, and `keyframe/2` all take already-flattened
  `iodata()`, one binary per row (`InlineAuthority`'s own moduledoc:
  "callers hand the paint authority already width-truncated text").

  This module is the bridge the assembled harness owns: flatten a view map
  into an ordered list of one-line-per-leaf-text-node strings (inline
  `:row`s of text leaves join into ONE line -- see below), truncated to
  a display-width budget (`Raxol.UI.TextMeasure`, never `String.length` --
  CJK undercounts), optionally wrapped in minimal SGR (`:bold`, `:dim`,
  `:fg` as 24-bit truecolor hex or a named ANSI color atom) for the
  styled/inline path.

  ## Why truncate BEFORE styling

  `lines/3`'s pipeline is: flatten -> truncate to `width` (plain content
  only) -> THEN wrap in SGR. Reversing that order would count escape bytes
  as display columns (`TextMeasure` has no ANSI awareness), silently
  truncating either mid-escape-sequence or too early. Truncating the plain
  string first and adding SGR as a pure string-wrap afterward keeps the
  width budget exact regardless of styling.

  ## Modes

    * `:plain` -- `FlatAuthority`'s destination (pipe/CI/screen-reader):
      zero escape bytes, ever (mirrors `FlatAuthority`'s own "zero escape
      bytes, full stop" contract) -- content only.
    * `:styled` -- `InlineAuthority`'s destination: content wrapped in a
      minimal SGR run (24-bit `:fg`, `:dim`, and the `:bg` tint vocabulary
      below) when the source view node carries a `:style` map with those
      keys, `\\e[0m` reset at the end of any styled line. A style-free node
      (no `:fg`/`:dim`/`:bg`) round-trips byte-identical to plain --
      neutral by default, matching every harness Component's own "absent
      prominence = zero change" contract.

  ## The `:bg` tint vocabulary (and `highlight_bg/3`)

  `:bg` accepts the terminal-neutral tint encoding
  `Raxol.UI.Theming.Palette`'s role tints resolve to: `"#RRGGBB"`
  (`48;2;r;g;b`), `{:xterm256, 0..255}` (`48;5;n`), or `{:ansi16, 0..15}`
  (`40+n` / `100+(n-8)`). Components never pick the value -- they name a
  role and the palette layer decides per capability tier ("roles, never
  colors").

  `highlight_bg/3` is the FULL-ROW variant for the DevTools hover
  highlight: it wraps an ALREADY-styled line (this module's own `:styled`
  output -- the one kind of SGR-bearing string this module itself
  produced) in a bg run, re-asserting the bg after every embedded
  `\\e[0m` so an inner styled run's reset cannot drop the tint mid-row,
  and pads with spaces to the full width budget so the tint reads as a
  row highlight, not a text-shaped smear. This is still styling applied
  at THIS byte-emission seam -- never bg bytes embedded upstream in
  content strings (the repo's ANSI-at-the-final-stage law).

  ## This module is the trust boundary: sanitize content here, not downstream

  Every string this module flattens can originate from an untrusted
  source -- a fixture's tool-call output, an LLM's streamed response, a
  bracketed paste landing in the Composer buffer (`Composer`'s own
  moduledoc: pasted content is inserted verbatim, "no matter how many
  lines the paste contains"). Neither `InlineAuthority` nor `FlatAuthority`
  re-validates the `iodata()` rows a caller hands them -- both take
  already-flattened content ON TRUST, one binary per row. So this module,
  the ONE seam every harness Component's content passes through before
  reaching either authority, is where two hostile-content properties get
  enforced, once, for both paint substrates:

    1. **Embedded `\\n` splits into multiple collected lines.** A `:text`
       node whose `content` contains a literal newline (a multi-line tool
       result, a pasted multi-line composer buffer, `Composer`'s own
       queued-steer banner built from raw composer text) would otherwise
       collect as ONE list entry containing an embedded newline --
       `InlineAuthority.repaint/2`'s "one binary per row" row-accounting
       assumes every list entry maps to exactly one physical terminal row,
       so a single entry that actually PRINTS as two rows (the terminal
       itself breaks on the embedded `\\n`) desyncs that count silently:
       every row after the split one is now off-by-one against whatever
       `InlineAuthority` believes it painted. Splitting on `\\n` here
       (before truncation, so each resulting line gets its own width
       budget) is CORRECT, not lossy -- it turns one row-accounting bug
       into the same content rendered as the multiple rows it actually is.
    2. **ESC and C0 control bytes (except `\\t`) are stripped from content.**
       An embedded ESC in a `:text` node's content -- unlike the styling
       this module adds itself around a truncated line -- is an
       INJECTION: it would ride through untouched and reach the terminal
       inside what `InlineAuthority`/`FlatAuthority` both assume is inert
       text, capable of anything from a stray color change to a full
       screen clear. The same byte-wise strip `FlatAuthority.scrub/1` uses
       is used here (see that module's own comment: multi-byte UTF-8 lead
       (`0xC2`-`0xF4`) and continuation (`0x80`-`0xBF`) bytes are both
       `>= 0x20`, so byte-wise stripping never splits a valid codepoint) --
       the C0 byte is removed and the rest of a hostile sequence's bytes
       are left as a visible, garbled fragment, same honest failure mode
       `FlatAuthority` documents: a reader sees something was stripped
       rather than an invisible, silently-swallowed injection.

  **This is complementary to, not a substitute for, `FlatAuthority`'s own
  scrub** (a module-enforced flat scrub). Two
  independent layers, two independent jobs: `FlatAuthority.append_sealed/2`
  holds the FLAT-TIER guarantee ("this authority never emits a
  cursor-moving byte, regardless of what any caller passes in" -- a
  property that has to live in the authority itself, since a caller
  bypassing this bridge entirely must still get it). This module's
  sanitize fixes the INLINE-TIER row-accounting bug (1) that
  `FlatAuthority`'s scrub has no reason to know or care about (flat mode
  has no row-accounting to desync -- it is append-only), and belt-and-
  braces re-applies the same ESC/C0 strip (2) at the one seam BOTH tiers'
  content flows through, before either authority ever sees it. Neither
  layer alone is the full guarantee; removing either one reopens exactly
  the hole the other was never responsible for closing.
  """

  alias Raxol.UI.TextMeasure

  @type mode :: :plain | :styled

  @typedoc """
  A background tint in the terminal-neutral encoding the palette layer's
  role tints resolve to (`Raxol.UI.Theming.Palette.bg_tint/0`) -- see the
  moduledoc's "`:bg` tint vocabulary" section.
  """
  @type bg :: String.t() | {:xterm256, 0..255} | {:ansi16, 0..15}

  @doc """
  Flattens `view` (a `Raxol.View.Components`-shaped map, or a list of
  them) into an ordered list of plain/styled lines, each truncated to
  `width` display columns (ellipsis-truncated when it would overflow,
  mirroring `Raxol.Harness.StatusStrip`'s own truncation convention).

  One line per `:text` leaf node, in document order -- every harness
  Component in this package already builds its multi-line bodies as one
  `Components.text/1` child per line (see `Block.plain_content_lines/2`,
  `Composer.render/2`'s children list), so this never needs to re-wrap
  text itself.

  ## `:row` nodes are ONE logical line, not N

  A `%{type: :row, children: [...]}` node whose children are ALL `:text`
  map leaves is an INLINE run -- one physical line composed of styled
  segments in document order. `Raxol.UI.Components.MarkdownRenderer`
  emits exactly this shape for a list item with inline styling (bullet
  prefix + code span + plain tail, its `inline_row/2`); flattening each
  leaf to its own line -- the pre-fix behavior -- exploded one bullet
  item into three rows (bullet alone, code content alone, tail alone).
  Joined segments keep their own styles: on the `:styled` path each
  segment gets its own minimal SGR run inline (so a code span renders
  styled INSIDE the line), on the `:plain` path contents are simply
  concatenated. Width truncation applies to the JOINED line (the
  ellipsis lands wherever the budget runs out, inheriting that
  segment's style), and the trust boundary is unchanged: an embedded
  `\\n` inside any segment still splits into real physical rows, every
  piece sanitized. A `:row` with any non-text child falls through to
  the normal recursive walk.

  `MultiLineInput`'s cursor/selection run segments arrive through this
  same `:row` rule: `RenderHelper.render_line/4` emits each visible line
  as one `:row` of styled `:text` segments (the legacy bare
  `{:text, content, style}` tuple vocabulary is retired -- no producer
  emits it), so the composer draft, a cursor split, and a selection run
  are all just inline rows here, per-segment styles included.
  """
  @spec lines(map() | [map()], non_neg_integer(), mode()) :: [String.t()]
  def lines(view, width, mode \\ :plain) when is_integer(width) do
    view
    |> collect([])
    |> Enum.reverse()
    |> Enum.map(fn segments ->
      # Content is already sanitized: `add_lines/3` and
      # `add_segment_lines/2` (the only builders of these segment-list
      # entries) split on `\n` and scrub every resulting piece before it
      # lands here, so this stage only measures and styles.
      segments
      |> truncate_segments(width)
      |> Enum.map_join("", fn {content, style} ->
        style_line(content, style, mode)
      end)
    end)
  end

  # -- flatten ----------------------------------------------------------
  #
  # `acc` entries are LINES, newest first; each line is a list of
  # `{content, style}` segments in document order. A plain `:text` leaf
  # contributes single-segment lines; an all-text `:row` contributes one
  # multi-segment line (see moduledoc, "`:row` nodes are ONE logical
  # line").

  defp collect(views, acc) when is_list(views) do
    Enum.reduce(views, acc, &collect/2)
  end

  defp collect(%{type: :text, content: content} = node, acc)
       when is_binary(content) do
    add_lines(acc, content, Map.get(node, :style, %{}))
  end

  # An inline `:row` of text leaves is ONE logical line of styled
  # segments (a Markdown list item's bullet + code span + tail, a
  # tool-call header's glyph + name + args -- see moduledoc) -- join,
  # never one-line-per-leaf. The row's `gap` (top-level key, or
  # `style: %{gap: n}` as `ToolResultBlock`'s header row carries it)
  # becomes literal spaces between adjacent segments, matching what the
  # real layout engine would paint between row children. Any other
  # children shape falls through to the shared generic walk.
  defp collect(%{type: :row, children: children} = node, acc)
       when is_list(children) and children != [] do
    if Enum.all?(children, &text_leaf?/1) do
      segments =
        children
        |> Enum.map(&leaf_segment/1)
        |> intersperse_gap(row_gap(node))

      add_segment_lines(acc, segments)
    else
      Enum.reduce(children, acc, &collect/2)
    end
  end

  defp collect(%{children: children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect/2)
  end

  # The `:indication` container (the harness's left-edge primitive): its
  # content flattens normally, then the gutter re-applies as a text
  # PREFIX per line — top glyph on the first row, bottom glyph on the
  # last, the 2-cell indent on every other — so this byte-path bridge
  # renders the same contour the LayoutEngine stamps as columns.
  defp collect(%{type: :indication} = node, acc) do
    inner =
      node
      |> indication_content_lines()
      |> apply_indication_gutter(Map.get(node, :gutter, :none))

    Enum.reduce(inner, acc, fn segments, acc2 -> [segments | acc2] end)
  end

  defp collect(_node, acc), do: acc

  defp indication_content_lines(%{content: content}) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.map(fn line -> [{sanitize_line(line), %{}}] end)
  end

  defp indication_content_lines(%{content: content}) when is_map(content) do
    content |> collect([]) |> Enum.reverse()
  end

  defp indication_content_lines(_node), do: []

  defp apply_indication_gutter([], _gutter), do: []

  defp apply_indication_gutter(lines, gutter) do
    last = length(lines) - 1

    Enum.with_index(lines, fn segments, index ->
      prefix =
        case gutter do
          {:corners, top, _bottom} when index == 0 and is_binary(top) ->
            top <> " "

          {:corners, _top, bottom} when index == last and is_binary(bottom) ->
            bottom <> " "

          {:top, glyph} when index == 0 and is_binary(glyph) ->
            glyph <> " "

          {:rule, glyph} when is_binary(glyph) ->
            glyph <> " "

          _none_or_middle ->
            "  "
        end

      [{prefix, %{dim: true}} | segments]
    end)
  end

  defp text_leaf?(%{type: :text, content: content}), do: is_binary(content)
  defp text_leaf?(_other), do: false

  defp leaf_segment(%{content: content} = leaf),
    do: {content, Map.get(leaf, :style, %{})}

  defp row_gap(node) do
    case Map.get(node, :gap) do
      gap when is_integer(gap) and gap > 0 -> gap
      _other -> style_gap(Map.get(node, :style))
    end
  end

  defp style_gap(%{gap: gap}) when is_integer(gap) and gap > 0, do: gap
  defp style_gap(_style), do: 0

  defp intersperse_gap(segments, 0), do: segments

  defp intersperse_gap(segments, gap) do
    Enum.intersperse(segments, {String.duplicate(" ", gap), %{}})
  end

  # The trust boundary (see moduledoc): splits `content` on embedded `\n`
  # into one collected entry PER LINE (correct row accounting -- not
  # lossy, see point 1 above), sanitizing (point 2) each resulting line
  # AFTER the split so a stray `\r` left over from an embedded `\r\n`
  # sequence (`String.split/2` only consumes the `\n` delimiter) is still
  # scrubbed same as any other C0 byte. `Enum.reduce/3` prepending each
  # line in order reproduces exactly what N separate single-line
  # `collect/2` calls would have built (each contributes one entry to the
  # head of `acc`, in document order) -- the SAME "build in reverse, one
  # final `Enum.reverse/1`" discipline `lines/3` already uses.
  defp add_lines(acc, content, style) do
    content
    |> String.split("\n")
    |> Enum.reduce(acc, fn line, acc2 ->
      [[{sanitize_line(line), style}] | acc2]
    end)
  end

  # The same trust boundary for a joined `:row`: an embedded `\n` inside
  # ANY segment still starts a new physical line (row accounting stays
  # exact -- `InlineAuthority`'s "one binary per row" contract), with
  # every piece sanitized after the split. Segments before/after the
  # split keep their own styles on their respective lines.
  defp add_segment_lines(acc, segments) do
    segments
    |> Enum.reduce([[]], fn {content, style}, [current | done] ->
      case String.split(content, "\n") do
        [only] ->
          [[{sanitize_line(only), style} | current] | done]

        [first | rest] ->
          started = [[{sanitize_line(first), style} | current] | done]

          Enum.reduce(rest, started, fn piece, lines_acc ->
            [[{sanitize_line(piece), style}] | lines_acc]
          end)
      end
    end)
    # Built newest-line-first with reversed segments; restore document
    # order per line, then prepend lines oldest-first so `acc` keeps its
    # newest-first convention.
    |> Enum.reverse()
    |> Enum.reduce(acc, fn rev_segments, acc2 ->
      [Enum.reverse(rev_segments) | acc2]
    end)
  end

  @c0_exception ?\t

  @doc """
  Strips control code points before untrusted content reaches the wire:
  C0 (0x00-0x1F, incl. ESC/0x1B) except `\\t`, DEL (0x7F), AND the C1 range
  (U+0080..U+009F) -- the 8-bit-encoded siblings of the ESC-led CSI/OSC/DCS
  sequences (0x9B is CSI, 0x9D is OSC), which a byte-wise `>= 0x20` allowlist
  would wrongly pass. Decodes by code point so a C1 encoded as UTF-8
  (`0xC2 0x9B`) is caught while legitimate multi-byte text is preserved; a
  lone raw high byte (a bare C1 like 0x9B, or a stray continuation byte) is
  dropped rather than passed through. `\\n` needs no exception -- `add_lines/3`
  already consumed every `\\n` as the line-split delimiter before this runs.

  Public: this is the ONE sanitize implementation every caller of untrusted
  single-line content shares -- `add_lines/3` above (and, historically, the
  retired `Raxol.Harness.DiffExpansion`'s per-row renderer, which needed this
  exact trust-boundary sanitize WITHOUT `lines/3`'s view-tree flatten). See
  the moduledoc's "trust boundary" section.
  """
  @spec sanitize_line(String.t()) :: String.t()
  def sanitize_line(text), do: sanitize(text)

  defp sanitize(text), do: sanitize(text, <<>>)

  defp sanitize(<<>>, acc), do: acc

  defp sanitize(<<@c0_exception, rest::binary>>, acc),
    do: sanitize(rest, <<acc::binary, @c0_exception>>)

  defp sanitize(<<cp::utf8, rest::binary>>, acc) do
    if cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F),
      do: sanitize(rest, acc),
      else: sanitize(rest, <<acc::binary, cp::utf8>>)
  end

  defp sanitize(<<_byte, rest::binary>>, acc), do: sanitize(rest, acc)

  # -- width truncation (plain content only, before any styling) ---------

  @doc """
  Truncates `text` to `width` display columns (`Raxol.UI.TextMeasure`,
  never `String.length` -- CJK undercounts), ellipsis-truncating
  (`…`) when it would overflow, mirroring
  `Raxol.Harness.StatusStrip`'s own truncation convention. Plain content
  only -- apply BEFORE any styling, never after (see the moduledoc's "Why
  truncate BEFORE styling"). Public for the same reason `sanitize_line/1`
  is (the retired `Raxol.Harness.DiffExpansion`'s per-row renderer reused
  this exact truncation instead of duplicating it).
  """
  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(_text, width) when width <= 0, do: ""

  def truncate(text, width) do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> "…"
    end
  end

  # -- segment truncation (joined width budget, styles preserved) --------
  #
  # A line is a list of `{content, style}` segments; the width budget
  # applies to the JOINED display width. When it overflows, the cut
  # lands mid-walk: segments that fit pass through untouched, the
  # overflowing segment is split at the remaining budget and gets the
  # ellipsis (inheriting its own style -- same convention as the
  # single-segment `truncate/2`), everything after it is dropped.
  defp truncate_segments(_segments, width) when width <= 0, do: []

  defp truncate_segments(segments, width) do
    total =
      segments
      |> Enum.map(fn {content, _style} ->
        TextMeasure.display_width(content)
      end)
      |> Enum.sum()

    if total <= width do
      segments
    else
      cut_segments(segments, max(width - 1, 0), [])
    end
  end

  defp cut_segments([], _remaining, acc), do: Enum.reverse(acc)

  defp cut_segments([{content, style} | rest], remaining, acc) do
    seg_width = TextMeasure.display_width(content)

    if seg_width <= remaining do
      cut_segments(rest, remaining - seg_width, [{content, style} | acc])
    else
      {left, _rest} = TextMeasure.split_at_display_width(content, remaining)
      Enum.reverse([{left <> "…", style} | acc])
    end
  end

  # -- styling (applied AFTER truncation, never counted toward width) ----

  # An empty segment must never emit a bare SGR-on + reset pair (escape
  # bytes with zero content).
  defp style_line("", _style, _mode), do: ""

  defp style_line(content, _style, :plain), do: content

  defp style_line(content, style, :styled) do
    case sgr_codes(style) do
      [] -> content
      codes -> "\e[" <> Enum.join(codes, ";") <> "m" <> content <> "\e[0m"
    end
  end

  # Built in reverse (prepend, never append-to-list) then reversed once at
  # the end -- the idiomatic `[new | list]` shape.
  defp sgr_codes(style) do
    []
    |> maybe_code(Map.get(style, :bold), "1")
    |> maybe_code(Map.get(style, :dim), "2")
    |> maybe_fg(Map.get(style, :fg))
    |> maybe_bg(Map.get(style, :bg))
    |> Enum.reverse()
  end

  defp maybe_code(reversed_codes, true, code), do: [code | reversed_codes]
  defp maybe_code(reversed_codes, _falsy, _code), do: reversed_codes

  # Named ANSI colors (the vocabulary `Raxol.UI.Components.
  # MarkdownRenderer`'s styles use -- `fg: :yellow` code spans,
  # `:cyan` headings, `:green` blockquotes). Standard 16-color SGR
  # codes, so an inline code span actually renders styled instead of
  # its atom fg being silently dropped. Unknown atoms still drop --
  # neutral by default, same as every other unrecognized style key.
  @named_fg %{
    black: "30",
    red: "31",
    green: "32",
    yellow: "33",
    blue: "34",
    magenta: "35",
    cyan: "36",
    white: "37",
    bright_black: "90",
    bright_red: "91",
    bright_green: "92",
    bright_yellow: "93",
    bright_blue: "94",
    bright_magenta: "95",
    bright_cyan: "96",
    bright_white: "97"
  }

  defp maybe_fg(reversed_codes, fg) when is_map_key(@named_fg, fg),
    do: [Map.fetch!(@named_fg, fg) | reversed_codes]

  defp maybe_fg(reversed_codes, "#" <> hex) when byte_size(hex) == 6 do
    case Integer.parse(hex, 16) do
      {value, ""} ->
        r = value |> Bitwise.bsr(16) |> Bitwise.band(0xFF)
        g = value |> Bitwise.bsr(8) |> Bitwise.band(0xFF)
        b = Bitwise.band(value, 0xFF)

        rgb = [Integer.to_string(r), Integer.to_string(g), Integer.to_string(b)]
        Enum.reverse(["38", "2" | rgb]) ++ reversed_codes

      _other ->
        reversed_codes
    end
  end

  defp maybe_fg(reversed_codes, _other), do: reversed_codes

  defp maybe_bg(reversed_codes, spec) do
    case bg_codes(spec) do
      [] -> reversed_codes
      codes -> Enum.reverse(codes) ++ reversed_codes
    end
  end

  # The `:bg` tint vocabulary (see moduledoc): "#RRGGBB", {:xterm256, n},
  # {:ansi16, n}. Anything else -- including a malformed hex -- resolves
  # to NO codes, mirroring `maybe_fg/2`'s own silent-neutral convention.
  defp bg_codes("#" <> hex) when byte_size(hex) == 6 do
    case Integer.parse(hex, 16) do
      {value, ""} ->
        r = value |> Bitwise.bsr(16) |> Bitwise.band(0xFF)
        g = value |> Bitwise.bsr(8) |> Bitwise.band(0xFF)
        b = Bitwise.band(value, 0xFF)

        [
          "48",
          "2",
          Integer.to_string(r),
          Integer.to_string(g),
          Integer.to_string(b)
        ]

      _other ->
        []
    end
  end

  defp bg_codes({:xterm256, n}) when is_integer(n) and n in 0..255,
    do: ["48", "5", Integer.to_string(n)]

  defp bg_codes({:ansi16, n}) when is_integer(n) and n in 0..7,
    do: [Integer.to_string(40 + n)]

  defp bg_codes({:ansi16, n}) when is_integer(n) and n in 8..15,
    do: [Integer.to_string(100 + (n - 8))]

  defp bg_codes(_other), do: []

  @doc """
  The bg tint as a ready-to-emit SGR prefix (`"\\e[48;5;24m"`-shaped), or
  `nil` for a spec outside the vocabulary (including `nil` itself).
  Public so `highlight_bg/3` callers/tests share one encoding source.
  """
  @spec bg_prefix(bg() | nil) :: String.t() | nil
  def bg_prefix(spec) do
    case bg_codes(spec) do
      [] -> nil
      codes -> "\e[" <> Enum.join(codes, ";") <> "m"
    end
  end

  @doc """
  Full-row background highlight over an ALREADY-styled line (see the
  moduledoc's "`:bg` tint vocabulary" section): prefixes the bg run,
  re-asserts it after every embedded `\\e[0m` (an inner styled run's
  reset must not drop the tint mid-row), pads with spaces to `width`
  display columns (measured on the SGR-stripped content -- the input is
  this module's own `:styled` output, whose only escape bytes are the
  SGR runs it emitted itself) so the tint covers the whole row, and
  closes with one final reset. A `nil`/unknown spec is the identity --
  zero byte change, matching the "absent prominence = zero change"
  contract.
  """
  @spec highlight_bg(String.t(), bg() | nil, non_neg_integer()) :: String.t()
  def highlight_bg(line, spec, width) do
    case bg_prefix(spec) do
      nil ->
        line

      prefix ->
        pad = max(width - TextMeasure.display_width(strip_sgr(line)), 0)

        prefix <>
          String.replace(line, "\e[0m", "\e[0m" <> prefix) <>
          String.duplicate(" ", pad) <> "\e[0m"
    end
  end

  defp strip_sgr(line), do: String.replace(line, ~r/\e\[[0-9;]*m/, "")
end
