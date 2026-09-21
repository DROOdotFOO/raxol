defmodule Raxol.Core.Boundary.TermText do
  @moduledoc """
  Terminal-injection confinement: neutralize ESC/ANSI/control bytes in
  untrusted text *before* it reaches the terminal renderer.

  One of the three centralized boundary confinements (PR #569 thread 2); the
  others are `Raxol.Core.Boundary.Path` (path-traversal) and
  `Raxol.Core.Boundary.Evaluation` (code-evaluation exposure). This one has
  byte-stream semantics — a total function over binaries, no filesystem, never
  errors, never passes a dangerous byte through. It enforces the repo rule
  "never embed raw ANSI codes in strings passed to `text()`" *at the untrusted
  boundary* instead of trusting upstream.

  ## What `sanitize/2` strips

  In a single left-to-right pass:

    * **ESC (`0x1B`) and every sequence it introduces** — CSI (`ESC [` … final
      `0x40..0x7E`), OSC (`ESC ]` … `BEL`/`ST`; kills title-set and OSC-8
      hyperlink smuggling), DCS/APC/PM/SOS (`ESC P`/`ESC _`/`ESC ^`/`ESC X` …
      `ST`), two-byte `ESC <c>` forms, and a truncated trailing `ESC`.
    * **C0 controls (`0x00..0x1F`)** except the `:allow` list (default `[?\\n]`).
    * **DEL (`0x7F`)** and **raw C1 controls (`0x80..0x9F`)**.
    * **Format characters that misrepresent a line** — the bidi
      embedding/override block and isolates (`U+202A..U+202E`,
      `U+2066..U+2069`), which reorder rendered text (Trojan Source,
      CWE-451) so `"disabled in a hosted session"` can be made to read as
      its opposite with nothing an ESC filter would catch; `U+200B`,
      `U+200E`, `U+200F`, `U+00AD`, `U+2028`, `U+2029` and `U+FEFF`, which
      hide or re-break the content a reader is asked to trust; and the tag
      characters `U+E0000..U+E007F`, which carry an invisible ASCII payload
      inside ordinary-looking text. ZWJ (`U+200D`) and ZWNJ (`U+200C`) are
      deliberately KEPT: they join emoji sequences, carry meaning in Indic
      and Perso-Arabic scripts, and reorder nothing.
    * **Invalid UTF-8 bytes** → replaced with `U+FFFD` (never emit a broken
      sequence downstream). Raw C1 bytes are stripped (not replaced); other
      invalid bytes become `U+FFFD`.

  Valid printable text (including CJK, emoji, and other multi-byte UTF-8) passes
  through unchanged. The function never raises and its output contains no `ESC`
  and no disallowed control byte for ANY input binary.

  ## Where confinement happens (authoritative)

  Untrusted content is confined at the OUTPUT SINKS, not by walking and
  rebuilding a component tree on every frame. Component modules keep their
  view data ordinary and do no terminal confinement of their own; they point
  here instead of restating this list. The sinks are:

    * **Cell writes** — `Raxol.Core.Runtime.Rendering.Backends.sanitize_char/1`
      delegates to `sanitize_cell/1` as a cell enters the screen buffer.
    * **Terminal emitters** — `Raxol.Terminal.Renderer` and
      `Raxol.Core.Renderer` pass every cell through `sanitize_cell/1` and
      every OSC 8 URL through `sanitize_url/1`, immediately before the bytes
      are assembled.
    * **Layout link propagation** — `Raxol.UI.Layout.Engine` confines a
      `:link` attribute with `sanitize_url/1` as it propagates.
    * **Append/paint authority** — `Raxol.Harness.Surface.ViewText`
      sanitizes per line while flattening the view tree, over this module's
      `strip_codepoint?/2` deny set.
    * **Replay/export text** — `Raxol.Agent.Code.Replay` sanitizes the
      exported transcript per line.

  A cell sink and a text sink differ in exactly ONE respect: a cell owns a
  column, so a disallowed cell is BLANKED (`sanitize_cell/1`), while
  disallowed text is DELETED (`sanitize/2`). Every sink shares one deny set,
  `strip_codepoint?/2`.
  """

  @typedoc "A C0/allowed control byte value, e.g. `?\\t` or `?\\n`."
  @type control_byte :: 0..31

  @default_allow [?\n]

  # OSC 8 hands the URL to the terminal, which hands it to the desktop's
  # URL handler: `file:` reads a local path and `x-apple.systempreferences:`
  # (and every other registered scheme) launches an application, all from a
  # link an LLM wrote into Markdown. Only the three schemes that cannot do
  # more than open a browser or a mail composer are allowed through.
  @hyperlink_schemes ["http", "https", "mailto"]

  @doc """
  Sanitize `binary` for safe delivery to a terminal renderer.

  Total: always returns a `String.t()`, never raises.

  ## Options

    * `:allow` — a list of C0 control byte values (`0..31`) to pass through.
      Defaults to `[?\\n]`. `ESC` (`0x1B`) is never allowed regardless of this
      list.
  """
  @spec sanitize(binary(), keyword()) :: String.t()
  def sanitize(binary, opts \\ [])

  def sanitize(binary, opts) when is_binary(binary) and is_list(opts) do
    allow = Keyword.get(opts, :allow, @default_allow)
    binary |> scan(allow, []) |> Enum.reverse() |> List.to_string()
  end

  def sanitize(_binary, _opts), do: ""

  @doc """
  The deny set, as a predicate over one codepoint.

  `true` when `codepoint` must never reach a terminal: a C0 control outside
  `allow`, `DEL`, a C1 control, or one of the format characters listed in the
  moduledoc. Public so that every sink — text, cell, and the
  `Raxol.Harness.Surface.ViewText` line scanner — decides with the SAME set
  rather than keeping a second list that drifts from this one.
  """
  @spec strip_codepoint?(integer(), [control_byte()]) :: boolean()
  def strip_codepoint?(codepoint, allow \\ @default_allow)

  # Printable ASCII first, in one range test: it is almost every code point
  # in almost every string, and nothing in `0x20..0x7E` is ever denied. The
  # deny set below is exhaustive but costs a dozen comparisons, and this
  # predicate runs per code point on the per-line projection path, not only
  # per cell on the render path.
  def strip_codepoint?(cp, _allow) when cp >= 0x20 and cp < 0x7F, do: false

  def strip_codepoint?(cp, allow) when is_integer(cp) do
    cond do
      cp < 0x20 -> cp not in allow
      cp == 0x7F -> true
      cp >= 0x80 and cp <= 0x9F -> true
      true -> format_char?(cp)
    end
  end

  @doc """
  Confine one screen CELL's text.

  A cell is POSITIONAL: it owns a column. Deleting it (what `sanitize/2` does
  to text) pulls every cell to its right one column left, so box borders,
  table columns and the approval line come apart around a single hostile
  byte. A disallowed cell is therefore BLANKED to `" "`, never deleted, and
  an invalid UTF-8 byte becomes the one-column `U+FFFD` the text path already
  substitutes.

  A non-binary cell fails closed as `""`, and an empty cell stays empty:
  neither occupies a column to preserve.
  """
  @spec sanitize_cell(term()) :: String.t()
  def sanitize_cell(char)

  # Hot path: one integer test, no intermediate list. A 200x60 frame walks
  # this 12_000 times per keyframe.
  def sanitize_cell(<<cp::utf8>> = char) do
    if strip_codepoint?(cp, []), do: " ", else: char
  end

  def sanitize_cell(""), do: ""

  # A multi-codepoint grapheme cluster, or a raw byte `String.graphemes/1`
  # split out of invalid UTF-8. Sanitizing away to nothing still owes the row
  # its column.
  def sanitize_cell(char) when is_binary(char) do
    case sanitize(char, allow: []) do
      "" -> " "
      text -> text
    end
  end

  def sanitize_cell(_char), do: ""

  @doc """
  Confine a URL for OSC 8 emission: `sanitize/2` with `allow: []`, then a
  scheme allowlist (`http`, `https`, `mailto`).

  Returns `""` for a non-binary, for a URL whose bytes all sanitize away, and
  for any other scheme — including a URL with no scheme at all, which a
  terminal resolves against a base this process does not control. Callers
  read `""` as "no link": the label text still renders, it is simply not
  clickable.
  """
  @spec sanitize_url(term()) :: String.t()
  def sanitize_url(url) do
    case sanitize(url, allow: []) do
      "" -> ""
      confined -> allowed_scheme(confined)
    end
  end

  defp allowed_scheme(url) do
    case String.split(url, ":", parts: 2) do
      [scheme, _rest] ->
        if String.downcase(scheme) in @hyperlink_schemes, do: url, else: ""

      _no_scheme ->
        ""
    end
  end

  defp format_char?(cp) do
    cp == 0x00AD or cp == 0x200B or cp == 0x200E or cp == 0x200F or
      (cp >= 0x2028 and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069) or
      cp == 0xFEFF or (cp >= 0xE0000 and cp <= 0xE007F)
  end

  # --- byte-stream scanner ---------------------------------------------------

  defp scan(<<>>, _allow, acc), do: acc

  # ESC and everything it introduces are removed as a unit.
  defp scan(<<0x1B, rest::binary>>, allow, acc) do
    scan(strip_escape(rest), allow, acc)
  end

  # Printable ASCII: kept, with no predicate call at all. Same short-circuit
  # as `strip_codepoint?/2`'s first clause, inlined here because this is the
  # innermost loop of the scanner. ESC (`0x1B`) is handled above and is below
  # this range, so the clause order is safe.
  defp scan(<<cp::utf8, rest::binary>>, allow, acc) when cp >= 0x20 and cp < 0x7F do
    scan(rest, allow, [cp | acc])
  end

  # Any other code point. ESC is handled above, so the deny set here covers
  # the remaining C0/DEL/C1 and format code points; everything else is kept.
  defp scan(<<cp::utf8, rest::binary>>, allow, acc) do
    if strip_codepoint?(cp, allow),
      do: scan(rest, allow, acc),
      else: scan(rest, allow, [cp | acc])
  end

  # A raw C1 byte (invalid as a standalone UTF-8 byte) is stripped, not
  # replaced — matches the "strip raw C1" rule over the generic invalid rule.
  defp scan(<<b, rest::binary>>, allow, acc) when b >= 0x80 and b <= 0x9F do
    scan(rest, allow, acc)
  end

  # Any other invalid UTF-8 byte becomes the replacement character.
  defp scan(<<_bad, rest::binary>>, allow, acc) do
    scan(rest, allow, [0xFFFD | acc])
  end

  # --- escape-sequence consumers (ESC already consumed) ----------------------

  # Truncated trailing ESC: nothing follows.
  defp strip_escape(<<>>), do: <<>>

  # ESC ESC: leave the second ESC for the outer scanner to re-handle, so no ESC
  # can ever leak through a double-escape.
  defp strip_escape(<<0x1B, _::binary>> = rest), do: rest

  # CSI: ESC [ … final byte.
  defp strip_escape(<<?[, rest::binary>>), do: skip_csi(rest)

  # OSC: ESC ] … BEL/ST.
  defp strip_escape(<<?], rest::binary>>), do: skip_string(rest)

  # DCS / SOS / PM / APC: ESC P/X/^/_ … ST.
  defp strip_escape(<<c, rest::binary>>) when c in [?P, ?X, ?^, ?_], do: skip_string(rest)

  # Two-byte ESC <c> form: drop the single following byte.
  defp strip_escape(<<_c, rest::binary>>), do: rest

  # CSI body: parameter/intermediate bytes 0x20..0x3F, then one final 0x40..0x7E.
  defp skip_csi(<<>>), do: <<>>
  defp skip_csi(<<b, rest::binary>>) when b >= 0x40 and b <= 0x7E, do: rest
  defp skip_csi(<<b, rest::binary>>) when b >= 0x20 and b <= 0x3F, do: skip_csi(rest)
  # Any other byte terminates a malformed CSI (and is consumed with it).
  defp skip_csi(<<_b, rest::binary>>), do: rest

  # String terminator scan (OSC/DCS/APC/PM/SOS): consume until BEL or ST.
  defp skip_string(<<>>), do: <<>>
  defp skip_string(<<0x07, rest::binary>>), do: rest
  defp skip_string(<<0x1B, 0x5C, rest::binary>>), do: rest
  defp skip_string(<<_b, rest::binary>>), do: skip_string(rest)
end
