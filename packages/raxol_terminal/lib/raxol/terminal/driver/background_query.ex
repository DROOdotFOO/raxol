defmodule Raxol.Terminal.Driver.BackgroundQuery do
  @moduledoc """
  OSC 11 terminal background-color detection.

  Emits an OSC 11 query (`ESC ] 11 ; ? BEL`) followed by a primary Device
  Attributes probe (`CSI c`). Every terminal answers DA, so a DA reply that
  arrives without an OSC 11 reply means the terminal does not support
  dynamic-color queries and callers should fall back to an assumed ground.

  Replies arrive asynchronously on the input stream, interleaved with
  keystrokes. `scan/1` extracts (and strips) the OSC 11 / DA replies from a
  raw input chunk so they never leak into key-event parsing.

  The detected background is stored in `:persistent_term` and readable via
  `detected_background/0`; higher layers (e.g. salience theming) convert it
  to a ground lightness.
  """

  @pt_key {__MODULE__, :background}

  # OSC 11 query (BEL-terminated) + primary DA probe.
  @query "\e]11;?\a\e[c"

  @type rgb :: {0..255, 0..255, 0..255}

  @doc "Escape sequence to write to the terminal to start detection."
  @spec query_sequence() :: String.t()
  def query_sequence, do: @query

  @doc """
  Scans a raw input chunk for OSC 11 / DA replies while a query is pending.

  Returns `{result, cleaned}` where `cleaned` is the chunk with any reply
  bytes removed (safe to hand to the key-event parser) and `result` is:

    * `{:ok, {r, g, b}}` - background color reported (8-bit per channel)
    * `:unsupported` - DA reply arrived without an OSC 11 reply
    * `:pending` - no reply in this chunk yet
  """
  @spec scan(binary()) :: {{:ok, rgb()} | :unsupported | :pending, binary()}
  def scan(data) when is_binary(data) do
    case extract_osc11(data) do
      {payload, cleaned} ->
        cleaned = strip_da_reply(cleaned)

        case parse_color(payload) do
          {:ok, rgb} -> {{:ok, rgb}, cleaned}
          :error -> {:unsupported, cleaned}
        end

      :none ->
        case strip_da_reply_if_present(data) do
          {:stripped, cleaned} -> {:unsupported, cleaned}
          :absent -> {:pending, data}
        end
    end
  end

  @doc "Stores a detected background color for later lookup."
  @spec store(rgb()) :: :ok
  def store({_r, _g, _b} = rgb), do: :persistent_term.put(@pt_key, rgb)

  @doc "Returns the detected background color, if any."
  @spec detected_background() :: {:ok, rgb()} | :error
  def detected_background do
    case :persistent_term.get(@pt_key, :undefined) do
      :undefined -> :error
      rgb -> {:ok, rgb}
    end
  end

  # ---- OSC 11 reply extraction ----
  # Reply shape: ESC ] 11 ; <payload> terminated by BEL or ST (ESC \).

  defp extract_osc11(data) do
    case :binary.match(data, "\e]11;") do
      :nomatch ->
        :none

      {start, prefix_len} ->
        rest_start = start + prefix_len
        rest = binary_part(data, rest_start, byte_size(data) - rest_start)

        case find_osc_terminator(rest) do
          :none ->
            :none

          {payload_len, term_len} ->
            payload = binary_part(rest, 0, payload_len)

            cleaned =
              binary_part(data, 0, start) <>
                binary_part(
                  data,
                  rest_start + payload_len + term_len,
                  byte_size(data) - rest_start - payload_len - term_len
                )

            {payload, cleaned}
        end
    end
  end

  defp find_osc_terminator(rest) do
    bel = :binary.match(rest, "\a")
    st = :binary.match(rest, "\e\\")

    case {bel, st} do
      {:nomatch, :nomatch} -> :none
      {{pos, len}, :nomatch} -> {pos, len}
      {:nomatch, {pos, len}} -> {pos, len}
      {{b, bl}, {s, _}} when b < s -> {b, bl}
      {_, {s, sl}} -> {s, sl}
    end
  end

  # ---- DA reply stripping: ESC [ ? <params> c ----

  defp strip_da_reply(data) do
    case strip_da_reply_if_present(data) do
      {:stripped, cleaned} -> cleaned
      :absent -> data
    end
  end

  defp strip_da_reply_if_present(data) do
    case Regex.run(~r/\e\[\?[\d;]*c/, data, return: :index) do
      [{start, len}] ->
        {:stripped,
         binary_part(data, 0, start) <>
           binary_part(data, start + len, byte_size(data) - start - len)}

      nil ->
        :absent
    end
  end

  # ---- X11 color spec parsing ----
  # Typical payloads: "rgb:2b2b/2b2b/2b2b" (widths 1-4 hex digits per
  # channel), "rgba:.../..../..../ffff", or "#2b2b2b".

  @doc false
  @spec parse_color(binary()) :: {:ok, rgb()} | :error
  def parse_color("rgb:" <> spec), do: parse_channels(spec)

  def parse_color("rgba:" <> spec) do
    case String.split(spec, "/") do
      [r, g, b, _a] -> parse_channels(Enum.join([r, g, b], "/"))
      _ -> :error
    end
  end

  def parse_color("#" <> hex) when byte_size(hex) == 6 do
    with {:ok, r} <- hex_channel(binary_part(hex, 0, 2)),
         {:ok, g} <- hex_channel(binary_part(hex, 2, 2)),
         {:ok, b} <- hex_channel(binary_part(hex, 4, 2)) do
      {:ok, {r, g, b}}
    end
  end

  def parse_color(_), do: :error

  defp parse_channels(spec) do
    case String.split(spec, "/") do
      [r, g, b] ->
        with {:ok, r} <- scale_channel(r),
             {:ok, g} <- scale_channel(g),
             {:ok, b} <- scale_channel(b) do
          {:ok, {r, g, b}}
        end

      _ ->
        :error
    end
  end

  # Scale a 1-4 hex-digit channel to 8-bit: value / (16^w - 1) * 255.
  defp scale_channel(digits) when byte_size(digits) in 1..4 do
    case Integer.parse(digits, 16) do
      {value, ""} ->
        max = Integer.pow(16, byte_size(digits)) - 1
        {:ok, round(value / max * 255)}

      _ ->
        :error
    end
  end

  defp scale_channel(_), do: :error

  defp hex_channel(digits) do
    case Integer.parse(digits, 16) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end
end
