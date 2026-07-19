defmodule Raxol.Terminal.InlineDriver.CursorReport do
  @moduledoc """
  Pure scanner for a DSR-6 cursor position report (CPR — `CSI Pr ; Pc R`,
  the reply a terminal sends to `CSI 6n`) inside a raw tty input stream.

  Extracted from `Raxol.Terminal.InlineDriver.probe_cursor/2`'s receive
  loop so the byte-boundary contract is unit-testable with zero
  process/device setup:

    * **The CPR itself is consumed** — split out of the stream so it can
      never reach `Raxol.Terminal.ANSI.InputParser` (which would decode
      a row-1 reply, `\\e[1;<n>R`, as a modified **F3 keypress** — the
      classic DSR/F3 wire collision — and deliver a phantom key event to
      the app).
    * **Every other byte is preserved in arrival order** — real
      keystrokes interleaved with (or split around) the reply are handed
      back for normal dispatch, never dropped (the same leak-free rule
      the T1 capability probe's `{:leak_free, _}` action enforces).
    * **The held-back tail is bounded** — at most 12 bytes (the
      longest possible CPR is `\\e[9999;9999R`, 12 bytes) are ever kept
      waiting for a continuation chunk, so a flooding device cannot grow
      the probe buffer: everything already scanned past is flushed
      forward immediately.

  The scan is byte-oriented (no `/u` regex, no `String` walking): raw tty
  input is untrusted binary and may contain invalid UTF-8, 8-bit C1
  controls, or anything else — none of which may crash the scanner.
  """

  # `\e[` + up to 4 row digits + `;` + up to 4 col digits + `R`.
  @max_tail 12

  @cpr ~r/\e\[(\d{1,4});(\d{1,4})R/

  @typedoc "1-based `{row, col}` as reported by the terminal."
  @type position :: {pos_integer(), pos_integer()}

  @doc """
  Scans `buffer` for a complete CPR.

    * `{:reply, {row, col}, leading, trailing}` — a CPR was found.
      `leading`/`trailing` are the non-CPR bytes before/after it, in
      arrival order, for normal input dispatch. The CPR bytes themselves
      appear in neither.
    * `{:pending, forward, keep}` — no complete CPR yet. `forward` is
      safe to dispatch as ordinary input NOW; `keep` (at most
      #{@max_tail} bytes, possibly empty) is the tail that could still
      be the start of a CPR split across chunks — prepend it to the next
      chunk and scan again (or dispatch it as ordinary input once the
      probe deadline lapses).

  A `0` row or column (`\\e[0;0R` — not a screen position any 1-based
  terminal can report) is rejected as a reply and forwarded as ordinary
  input; scanning continues past it.
  """
  @spec scan(binary()) ::
          {:reply, position(), binary(), binary()}
          | {:pending, binary(), binary()}
  def scan(buffer) when is_binary(buffer) do
    case Regex.run(@cpr, buffer, return: :index) do
      [{start, len}, {r_start, r_len}, {c_start, c_len}] ->
        row = buffer |> binary_part(r_start, r_len) |> String.to_integer()
        col = buffer |> binary_part(c_start, c_len) |> String.to_integer()

        leading = binary_part(buffer, 0, start)
        after_start = start + len
        trailing = binary_part(buffer, after_start, byte_size(buffer) - after_start)

        if row >= 1 and col >= 1 do
          {:reply, {row, col}, leading, trailing}
        else
          # Not a position a 1-based screen can report: forward the
          # sequence as ordinary input and keep scanning past it.
          matched = binary_part(buffer, start, len)

          case scan(trailing) do
            {:reply, pos, lead2, trail2} ->
              {:reply, pos, leading <> matched <> lead2, trail2}

            {:pending, forward, keep} ->
              {:pending, leading <> matched <> forward, keep}
          end
        end

      nil ->
        split_partial_tail(buffer)
    end
  end

  # No full CPR in the buffer: flush everything forward except a tail
  # that could still be the start of one. Only the final @max_tail bytes
  # can possibly hold such a prefix (a longer candidate would already be
  # longer than any complete CPR).
  defp split_partial_tail(buffer) do
    size = byte_size(buffer)
    window_start = max(size - @max_tail, 0)

    case last_esc_index(buffer, size - 1, window_start) do
      nil ->
        {:pending, buffer, <<>>}

      idx ->
        tail = binary_part(buffer, idx, size - idx)

        if cpr_prefix?(tail) do
          {:pending, binary_part(buffer, 0, idx), tail}
        else
          {:pending, buffer, <<>>}
        end
    end
  end

  defp last_esc_index(_buffer, i, window_start) when i < window_start, do: nil

  defp last_esc_index(buffer, i, window_start) do
    if :binary.at(buffer, i) == 0x1B do
      i
    else
      last_esc_index(buffer, i - 1, window_start)
    end
  end

  # A PROPER prefix of `\e[<digits>;<digits>R` (a full match never
  # reaches here -- scan/1 already consumed it).
  defp cpr_prefix?(<<0x1B>>), do: true

  defp cpr_prefix?(<<0x1B, ?[, rest::binary>>),
    do: digits_semi_prefix?(rest, false)

  defp cpr_prefix?(_other), do: false

  defp digits_semi_prefix?(<<>>, _semi_seen?), do: true

  defp digits_semi_prefix?(<<c, rest::binary>>, semi_seen?)
       when c in ?0..?9,
       do: digits_semi_prefix?(rest, semi_seen?)

  defp digits_semi_prefix?(<<?;, rest::binary>>, false),
    do: digits_semi_prefix?(rest, true)

  defp digits_semi_prefix?(_rest, _semi_seen?), do: false
end
