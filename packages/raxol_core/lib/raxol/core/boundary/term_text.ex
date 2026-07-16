defmodule Raxol.Core.Boundary.TermText do
  @moduledoc """
  Terminal-injection confinement: neutralize ESC/ANSI/control bytes in
  untrusted text *before* it reaches the terminal renderer.

  One of the two centralized boundary confinements (PR #569 thread 2); the
  other is `Raxol.Core.Boundary.Path` (path-traversal). This one has byte-stream
  semantics — a total function over binaries, no filesystem, never errors, never
  passes a dangerous byte through. It enforces the repo rule "never embed raw
  ANSI codes in strings passed to `text()`" *at the untrusted boundary* instead
  of trusting upstream.

  ## What `sanitize/2` strips

  In a single left-to-right pass:

    * **ESC (`0x1B`) and every sequence it introduces** — CSI (`ESC [` … final
      `0x40..0x7E`), OSC (`ESC ]` … `BEL`/`ST`; kills title-set and OSC-8
      hyperlink smuggling), DCS/APC/PM/SOS (`ESC P`/`ESC _`/`ESC ^`/`ESC X` …
      `ST`), two-byte `ESC <c>` forms, and a truncated trailing `ESC`.
    * **C0 controls (`0x00..0x1F`)** except the `:allow` list (default `[?\\n]`).
    * **DEL (`0x7F`)** and **raw C1 controls (`0x80..0x9F`)**.
    * **Invalid UTF-8 bytes** → replaced with `U+FFFD` (never emit a broken
      sequence downstream). Raw C1 bytes are stripped (not replaced); other
      invalid bytes become `U+FFFD`.

  Valid printable text (including CJK, emoji, and other multi-byte UTF-8) passes
  through unchanged. The function never raises and its output contains no `ESC`
  and no disallowed control byte for ANY input binary.
  """

  @typedoc "A C0/allowed control byte value, e.g. `?\\t` or `?\\n`."
  @type control_byte :: 0..31

  @default_allow [?\n]

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

  # --- byte-stream scanner ---------------------------------------------------

  defp scan(<<>>, _allow, acc), do: acc

  # ESC and everything it introduces are removed as a unit.
  defp scan(<<0x1B, rest::binary>>, allow, acc) do
    scan(strip_escape(rest), allow, acc)
  end

  # A valid UTF-8 codepoint. ESC is handled above, so control checks here cover
  # the remaining C0/DEL/C1 codepoints; everything else is kept.
  defp scan(<<cp::utf8, rest::binary>>, allow, acc) do
    cond do
      cp == 0x7F -> scan(rest, allow, acc)
      cp < 0x20 and cp in allow -> scan(rest, allow, [cp | acc])
      cp < 0x20 -> scan(rest, allow, acc)
      cp >= 0x80 and cp <= 0x9F -> scan(rest, allow, acc)
      true -> scan(rest, allow, [cp | acc])
    end
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
