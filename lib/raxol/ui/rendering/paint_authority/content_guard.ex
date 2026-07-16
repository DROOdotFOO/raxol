defmodule Raxol.UI.Rendering.PaintAuthority.ContentGuard do
  @moduledoc """
  Neutralizes control bytes inside agent/LLM-originated content before it
  reaches `PaintAuthority.InlineAuthority.seal/2` (T2b review fix, HIGH:
  "our code was wrong" -- `seal/2`/`append_sealed/2` wrote iodata
  verbatim, so an embedded `\\e[2J`/`\\e[3J`/CUP inside model output could
  wipe native scrollback or repaint an already-sealed row FROM INSIDE THE
  CONTENT, defeating every invariant the append path exists to hold, no
  matter how correct the fill-down/seal-once machinery around it is).

  This module is intentionally SHARED, not private to T2b:
  `Raxol.UI.Rendering.PaintAuthority.InlineAuthority.seal/2` is its first
  caller, and T2c's footer/pinned-viewport repaint path (also fed
  agent-controlled text) is expected to reuse it rather than growing a
  second, divergent sanitizer.

  ## The allowlist grammar

  Scanning byte-by-byte (UTF-8 multi-byte sequences pass through as
  opaque bytes -- nothing here decodes or re-encodes text, it only ever
  recognizes ASCII control structure):

    * **Printable ASCII** (`0x20..0x7E`) and any byte `>= 0x80`
      (UTF-8 lead/continuation bytes) -- passed through unchanged.
    * **`\\t`, `\\r`, `\\n`** -- passed through unchanged (the C0 controls a
      line of legitimate content actually needs).
    * **SGR (`CSI ... m`)** -- e.g. `\\e[1;31m`, `\\e[0m` -- passed through
      VERBATIM. This is the renderer's own styling vocabulary; content
      that legitimately carries color/style resets must keep working.
    * **Every other C0 control byte** (`0x00..0x1F` except the three
      above) and **DEL** (`0x7F`) -- stripped silently. These carry no
      printable residue worth preserving.
    * **Any other ESC (`0x1B`)-led sequence** -- a non-SGR CSI (cursor
      moves, erases, ...), OSC (`\\e]...`), DCS (`\\eP...`), or a bare/
      truncated ESC with no recognized introducer at all -- has ONLY its
      leading ESC byte stripped. Scanning resumes immediately after that
      ESC, so whatever printable bytes followed it (the `[2J` in
      `\\e[2J`, the `]0;title` in an OSC, etc.) are re-scanned as ordinary
      text and, being printable, survive into the output.

  ## "Visible-honest" neutralization, not silent deletion

  A `\\e[2J` with its ESC stripped becomes the literal, visible text
  `[2J` -- four printable characters a terminal just prints, doing
  nothing else. That is the deliberate choice this module makes over
  silently deleting the whole sequence: a visible `[2J` fragment in the
  sealed history is an honest record that content tried to inject a
  control sequence and got stopped, whereas an invisible drop would look,
  to anyone watching the terminal, exactly like the model simply never
  said anything unusual. Any C0 control byte embedded in what would have
  been that sequence's parameters (e.g. a stray BEL terminating an OSC)
  IS silently dropped, per the point above -- there is no printable
  residue for a non-printable control byte to leave behind.

  ## Scope note: OSC 8 hyperlinks

  `OSC 8 ; params ; URI ST text OSC 8 ; ; ST` (terminal hyperlinks) is
  currently neutralized like any other OSC -- the `\\e]8;...` introducer's
  ESC is stripped, leaving the URI parameters as visible residue text
  rather than a clickable link. Allowlisting OSC 8 specifically (parsing
  its structure enough to keep the link semantics while still rejecting
  every other OSC subcommand) is deliberately deferred; tracked as
  backlog, not implemented here.
  """

  @typedoc false
  @type acc :: iolist()

  @doc """
  Sanitizes `iodata` per the allowlist grammar above, returning a binary.
  Safe to call on a whole multi-line sealed block (not just a single
  line) -- `\\r`/`\\n` inside are always allowed through, so line
  boundaries are preserved exactly.
  """
  @spec sanitize_line(iodata()) :: binary()
  def sanitize_line(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> scan([])
  end

  # -- ESC handling -------------------------------------------------------

  # `\e[` -- attempt to match a complete CSI sequence. Only one whose
  # final byte is `m` (SGR) is legitimate and kept verbatim; anything
  # else falls through to the generic "strip just the ESC" rule below by
  # re-scanning from the `[` as ordinary bytes.
  defp scan(<<0x1B, ?[, rest::binary>>, acc) do
    case match_sgr(rest) do
      {:ok, sequence, remainder} ->
        scan(remainder, [sequence | acc])

      :error ->
        scan(<<?[, rest::binary>>, acc)
    end
  end

  # Any other ESC-led byte (OSC `\e]`, DCS `\eP`, or a bare/unrecognized
  # ESC, including one truncated at the end of input) -- strip only the
  # ESC byte itself and resume scanning from whatever follows as ordinary
  # bytes. OSC/DCS terminators (a BEL, or a further ESC for the `ST`
  # 2-byte terminator) are handled for free by this same rule and the C0
  # rule below on the next pass -- no separate OSC/DCS parser is needed.
  defp scan(<<0x1B, rest::binary>>, acc) do
    scan(rest, acc)
  end

  # A bare, unterminated ESC at the very end of the input -- nothing
  # follows to strip alongside it, so the loop's base case below already
  # handles this: `<<0x1B>>` matches the clause above with `rest == <<>>`.

  # `\t`, `\r`, `\n` -- always passed through.
  defp scan(<<c, rest::binary>>, acc) when c in [?\t, ?\r, ?\n] do
    scan(rest, [<<c>> | acc])
  end

  # Every other C0 control byte, and DEL -- stripped, no residue.
  defp scan(<<c, rest::binary>>, acc) when c < 0x20 or c == 0x7F do
    scan(rest, acc)
  end

  # Printable ASCII and UTF-8 lead/continuation bytes -- pass through.
  defp scan(<<c, rest::binary>>, acc) do
    scan(rest, [<<c>> | acc])
  end

  defp scan(<<>>, acc) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # -- CSI/SGR matching ----------------------------------------------------

  # CSI grammar (ECMA-48): parameter bytes `0x30..0x3F`, then intermediate
  # bytes `0x20..0x2F`, then exactly one final byte `0x40..0x7E`. Only a
  # final byte of `?m` is accepted here (SGR); every other final byte, or
  # no final byte at all (truncated at end of input), is `:error` --
  # callers strip just the leading ESC and let the parameter/intermediate
  # bytes fall through as ordinary printable text.
  defp match_sgr(bin), do: match_params(bin, [])

  defp match_params(<<c, rest::binary>>, params) when c in 0x30..0x3F do
    match_params(rest, [c | params])
  end

  defp match_params(bin, params), do: match_intermediates(bin, params, [])

  defp match_intermediates(<<c, rest::binary>>, params, inter)
       when c in 0x20..0x2F do
    match_intermediates(rest, params, [c | inter])
  end

  defp match_intermediates(<<?m, rest::binary>>, params, inter) do
    sequence =
      IO.iodata_to_binary([
        <<0x1B, ?[>>,
        Enum.reverse(params),
        Enum.reverse(inter),
        <<?m>>
      ])

    {:ok, sequence, rest}
  end

  defp match_intermediates(_bin, _params, _inter), do: :error
end
