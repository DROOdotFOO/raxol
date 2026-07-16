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
  into an ordered list of one-line-per-leaf-text-node strings, truncated to
  a display-width budget (`Raxol.UI.TextMeasure`, never `String.length` --
  CJK undercounts), optionally wrapped in minimal SGR (24-bit truecolor
  `:fg`, `:dim`) for the styled/inline path.

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
      minimal SGR run (24-bit `:fg`, `:dim`) when the source view node
      carries a `:style` map with those keys, `\\e[0m` reset at the end of
      any styled line. A style-free node (no `:fg`/`:dim`) round-trips
      byte-identical to plain -- neutral by default, matching every
      harness Component's own "absent prominence = zero change" contract.

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

  ## The one exception: `MultiLineInput`'s per-run tuple leaves

  `Composer.render/2` mounts `Raxol.UI.Components.Input.MultiLineInput`
  directly (a general-purpose input Component, not one of this package's
  own harness Components) for the actual typed buffer. That component
  renders each VISIBLE LINE as cursor/selection-aware RUN SEGMENTS --
  bare `{:text, content, style}` tuples, one per styling run (e.g.
  `[{:text, "hel", %{}}, {:text, " ", %{background: :red}}]` for a
  3-character buffer with the cursor at the end) -- never the
  `%{type: :text, content:}` map shape every harness Component uses. A
  naive `collect/2` walk either drops these silently (no clause matches a
  bare tuple) or, worse, would treat each RUN as its own line if a clause
  matched tuples individually -- splitting one visual row into N. This
  module's `collect/2` special-cases a `children:` list that is ENTIRELY
  bare text-tuples: it joins their content into ONE line (a single style,
  same as every other line here -- this module has never supported
  per-segment styling within one line, and `style_line/2` has no
  `:background` handling regardless, so the cursor-highlight run's style
  is dropped the same way it always would be). Any other `children:` shape
  (including a MIX of tuples and maps) falls through to the normal
  recursive walk unchanged.
  """
  @spec lines(map() | [map()], non_neg_integer(), mode()) :: [String.t()]
  def lines(view, width, mode \\ :plain) when is_integer(width) do
    view
    |> collect([])
    |> Enum.reverse()
    |> Enum.map(fn {content, style} ->
      # Content is already sanitized: `add_lines/3` (the sole builder of these
      # `{content, style}` entries) splits on `\n` and scrubs every resulting
      # line before it lands here, so this stage only measures and styles.
      content
      |> truncate(width)
      |> style_line(style, mode)
    end)
  end

  # -- flatten ----------------------------------------------------------

  defp collect(views, acc) when is_list(views) do
    Enum.reduce(views, acc, &collect/2)
  end

  defp collect(%{type: :text, content: content} = node, acc)
       when is_binary(content) do
    add_lines(acc, content, Map.get(node, :style, %{}))
  end

  # MultiLineInput's per-run tuple leaves (see moduledoc, "The one
  # exception"): when a node's ENTIRE children list is bare
  # `{:text, content, style}` tuples, they are run-segments of ONE visual
  # line -- join them into a single line entry rather than recursing (a
  # bare tuple matches no other `collect/2` clause, so recursing would
  # silently drop them; treating each as its own line would wrongly split
  # one row into N).
  defp collect(%{children: children}, acc)
       when is_list(children) and children != [] do
    if Enum.all?(children, &text_tuple?/1) do
      add_lines(acc, join_text_tuples(children), %{})
    else
      Enum.reduce(children, acc, &collect/2)
    end
  end

  defp collect(%{children: children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect/2)
  end

  defp collect(_node, acc), do: acc

  defp text_tuple?({:text, content, _style}), do: is_binary(content)
  defp text_tuple?(_other), do: false

  defp join_text_tuples(tuples),
    do: Enum.map_join(tuples, "", fn {:text, content, _style} -> content end)

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
    |> Enum.reduce(acc, fn line, acc2 -> [{sanitize(line), style} | acc2] end)
  end

  # Strips every C0 control byte (0x00-0x1F, which includes ESC/0x1B)
  # except `\t`, mirroring `FlatAuthority.scrub/1`'s own byte-wise
  # technique and its safety argument verbatim: multi-byte UTF-8 lead
  # (0xC2-0xF4) and continuation (0x80-0xBF) bytes are both `>= 0x20`, so
  # stripping byte-by-byte never splits a valid codepoint. `\n` needs no
  # exception here -- `add_lines/3` above already consumed every `\n` as
  # the line-split delimiter before this ever runs, so none survives into
  # a single line's content for this function to see. DEL (0x7F) is stripped
  # too -- it is `>= 0x20` but a non-printing control that terminals may act
  # on, so the `>= 0x20` allowlist alone would wrongly pass it.
  @c0_exception ?\t

  defp sanitize(text) do
    for <<byte <- text>>,
        (byte >= 0x20 and byte != 0x7F) or byte == @c0_exception,
        into: <<>>,
        do: <<byte>>
  end

  # -- width truncation (plain content only, before any styling) ---------

  defp truncate(_text, width) when width <= 0, do: ""

  defp truncate(text, width) do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> "…"
    end
  end

  # -- styling (applied AFTER truncation, never counted toward width) ----

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
    |> Enum.reverse()
  end

  defp maybe_code(reversed_codes, true, code), do: [code | reversed_codes]
  defp maybe_code(reversed_codes, _falsy, _code), do: reversed_codes

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
end
