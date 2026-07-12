defmodule Raxol.Terminal.Driver.InputBuffer do
  @moduledoc """
  Input buffer management for Driver: accumulates bytes, detects incomplete
  escape sequences, and flushes complete sequences for parsing.
  """

  @doc """
  Returns true if the buffer ends with an incomplete escape sequence
  that needs more bytes before it can be dispatched.
  """
  def incomplete_escape?(<<>>), do: false

  def incomplete_escape?(buffer) do
    case :binary.matches(buffer, <<27>>) do
      [] ->
        false

      matches ->
        {last_esc_pos, _} = List.last(matches)

        tail =
          binary_part(buffer, last_esc_pos, byte_size(buffer) - last_esc_pos)

        incomplete_csi?(tail)
    end
  end

  # ESC alone — more bytes expected
  defp incomplete_csi?(<<27>>), do: true
  # ESC [ but no final byte
  defp incomplete_csi?(<<27, 91, rest::binary>>),
    do: not has_csi_terminator?(rest)

  # ESC O but no function key letter
  defp incomplete_csi?(<<27, 79>>), do: true

  # ESC ] (OSC, e.g. an OSC 11 color reply) — incomplete until BEL or ST
  defp incomplete_csi?(<<27, 93, rest::binary>>) do
    not (String.contains?(rest, "\a") or String.contains?(rest, "\e\\"))
  end

  defp incomplete_csi?(_), do: false

  defp has_csi_terminator?(<<>>), do: false

  defp has_csi_terminator?(data) do
    last = :binary.last(data)
    last >= 64 and last <= 126
  end
end
