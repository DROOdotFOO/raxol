defmodule Raxol.Terminal.Parser.ParserState do
  @moduledoc """
  Parser state for the terminal emulator.

  The buffers here fill from the output byte stream, which is untrusted (a
  program, a remote peer, a replayed `.cast` file) and can arrive split across
  any number of `process_input/2` calls, so every append goes through a
  function below that bounds it:

    * Control sequence parameters (`append_param/2`): at most 30, each clamped
      to 65535, which are xterm's `NPARAM` and `MAX_I_PARAM`. As in xterm, a
      separator past the last parameter is dropped and further digits keep
      accumulating into that parameter, clamped.
    * Intermediate bytes (`append_intermediate/2`): at most 15, further ones
      dropped, as libvterm does (`INTERMED_MAX` 16). No sequence the emulator
      recognises uses more than two.
    * OSC and DCS strings (`append_osc/2`, `append_dcs/2`): 20,000 bytes,
      xterm's default `maxStringParse`, except OSC 52 (clipboard, 4 MiB of
      base64) and sixel image data (`Raxol.Core.Defaults.max_image_payload_bytes/0`).
      A string past its cap is discarded and the rest of it skipped up to its
      terminator, which returns the parser to ground without dispatching it;
      xterm ignores an oversized string the same way.
  """

  alias Raxol.Core.Defaults

  @max_params 30
  @max_param_value 65_535
  @max_param_digits 5
  @max_intermediates 15
  @max_string_bytes 20_000
  @max_osc_52_bytes 4 * 1024 * 1024
  @max_sixel_bytes Defaults.max_image_payload_bytes()

  @type t :: %__MODULE__{
          state: atom(),
          params: list(),
          params_buffer: binary(),
          intermediates_buffer: binary(),
          payload_buffer: binary(),
          payload_overflow: boolean(),
          final_byte: byte() | nil,
          designating_gset: term() | nil,
          single_shift: term() | nil
        }

  defstruct state: :ground,
            params: [],
            params_buffer: "",
            intermediates_buffer: "",
            payload_buffer: "",
            payload_overflow: false,
            final_byte: nil,
            designating_gset: nil,
            single_shift: nil

  @doc """
  Appends a parameter byte (a digit, `;` or `:`) to a parameter buffer,
  keeping it within xterm's parameter count and value limits.
  """
  @spec append_param(binary(), byte()) :: binary()
  def append_param(buffer, digit) when digit in ?0..?9 do
    {head, last} = split_last_param(buffer)
    head <> clamp_param(last <> <<digit>>)
  end

  def append_param(buffer, separator) when separator in [?;, ?:] do
    if param_count(buffer) >= @max_params,
      do: buffer,
      else: buffer <> <<separator>>
  end

  @doc "Appends an intermediate byte, dropping it once the buffer is full."
  @spec append_intermediate(binary(), byte()) :: binary()
  def append_intermediate(buffer, _byte)
      when byte_size(buffer) >= @max_intermediates,
      do: buffer

  def append_intermediate(buffer, byte), do: buffer <> <<byte>>

  @doc """
  Appends a byte to an OSC string. Past its cap the string is discarded and
  `payload_overflow` is set, so the rest of it is skipped and never dispatched.
  """
  @spec append_osc(t(), byte()) :: t()
  def append_osc(%__MODULE__{} = state, byte),
    do: append_payload(state, byte, osc_limit(state.payload_buffer))

  @doc """
  Appends a byte to a DCS data string, with the same overflow handling as
  `append_osc/2`.
  """
  @spec append_dcs(t(), byte()) :: t()
  def append_dcs(%__MODULE__{} = state, byte),
    do: append_payload(state, byte, dcs_limit(state))

  defp append_payload(%__MODULE__{payload_overflow: true} = state, _byte, _limit),
    do: state

  defp append_payload(%__MODULE__{payload_buffer: buffer} = state, byte, limit)
       when byte_size(buffer) < limit,
       do: %{state | payload_buffer: buffer <> <<byte>>}

  defp append_payload(state, _byte, _limit),
    do: %{state | payload_buffer: "", payload_overflow: true}

  # `binary_part/3`, not a `"52;" <> _` match: matching the buffer would stop
  # the VM appending to it in place, and every byte would copy the whole of it.
  defp osc_limit(payload) when byte_size(payload) >= 3 do
    if binary_part(payload, 0, 3) == "52;",
      do: @max_osc_52_bytes,
      else: @max_string_bytes
  end

  defp osc_limit(_payload), do: @max_string_bytes

  # The emulator treats DCS q with no intermediate or with `"` as sixel
  # (`Raxol.Terminal.Commands.DCSHandler`); DCS $ q and DCS + q are not images.
  defp dcs_limit(%__MODULE__{final_byte: ?q, intermediates_buffer: i})
       when i in ["", "\""],
       do: @max_sixel_bytes

  defp dcs_limit(_state), do: @max_string_bytes

  defp param_count(buffer),
    do: length(:binary.matches(buffer, [";", ":"])) + 1

  defp split_last_param(buffer) do
    case :binary.matches(buffer, [";", ":"]) do
      [] ->
        {"", buffer}

      matches ->
        {position, 1} = List.last(matches)
        split_at = position + 1

        {binary_part(buffer, 0, split_at),
         binary_part(buffer, split_at, byte_size(buffer) - split_at)}
    end
  end

  # Keeps a parameter's digits no longer than its clamped value needs: leading
  # zeros go (a lone "0" stays, as it differs from an empty default), and
  # anything above the maximum becomes the maximum.
  defp clamp_param("0" <> rest) when rest != "", do: clamp_param(rest)

  defp clamp_param(digits) when byte_size(digits) > @max_param_digits,
    do: Integer.to_string(@max_param_value)

  defp clamp_param(digits) when byte_size(digits) == @max_param_digits do
    if String.to_integer(digits) > @max_param_value,
      do: Integer.to_string(@max_param_value),
      else: digits
  end

  defp clamp_param(digits), do: digits
end
