defmodule Raxol.Terminal.Driver.BackgroundQuery do
  @moduledoc """
  OSC 11 terminal background-color detection + DECRQM 2026 probe.

  Emits an OSC 11 query (`ESC ] 11 ; ? BEL`) and a DECRQM query for mode
  2026 (`CSI ? 2026 $ p`, synchronized output), followed by a primary
  Device Attributes probe (`CSI c`) as the sentinel. Every terminal
  answers DA, so a DA reply that arrives without a wanted reply means the
  terminal does not support that query and callers fall back conservative
  (silence is the failure mode, F0 §2).

  Replies arrive asynchronously on the input stream, interleaved with
  keystrokes. `scan/1` routes the chunk through
  `Raxol.Terminal.Capabilities.ReplyScanner` (grammar dispatch, both
  OSC terminators, leak-free residual) so reply bytes never leak into
  key-event parsing. A parsed DECRQM 2026 reply is noted on
  `Raxol.Terminal.Capabilities` -- `Capabilities.sync_output?/0` is the
  one public emit-gate render paths consult. `scan/1` keeps its original
  `{result, cleaned}` contract for the driver.

  `detected_background/0` is now a **delegating shim** over the unified
  `Raxol.Terminal.Capabilities` session record (native-palette-riding): it
  reads `Capabilities.background/0` first, falling back to this module's own
  `:persistent_term` cache (written by `store/1`) only when no
  `Capabilities` record has been cached yet. `store/1` is unchanged and
  still the entry point older callers use directly. The parse functions
  (`parse_color/1` and friends) stay live -- `Raxol.Terminal.Capabilities`'s
  own scanner/classifier path reuses them. **Retirement planned**: once
  every caller reads `Capabilities.background/0` (or `ground/0`) directly,
  this module's `:persistent_term` fallback and `store/1` go away and only
  the parse helpers, if still needed, get a new home.

  Higher layers (e.g. salience theming) convert the background to a ground
  lightness -- see `Raxol.UI.Theming.SalienceTheme.detect_ground/0`.
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.ReplyScanner

  @pt_key {__MODULE__, :background}

  # OSC 11 query (BEL-terminated) + DECRQM 2026 probe + primary DA
  # sentinel LAST (F0 §2: read-to-sentinel bounds every unanswered query).
  @query "\e]11;?\a\e[?2026$p\e[c"

  @type rgb :: {0..255, 0..255, 0..255}

  @doc "Escape sequence to write to the terminal to start detection."
  @spec query_sequence() :: String.t()
  def query_sequence, do: @query

  @doc """
  Scans a raw input chunk for OSC 11 / DECRQM / DA replies while a query
  is pending.

  Returns `{result, cleaned}` where `cleaned` is the chunk with any reply
  bytes removed (safe to hand to the key-event parser) and `result` is:

    * `{:ok, {r, g, b}}` - background color reported (8-bit per channel)
    * `:unsupported` - DA reply arrived without an OSC 11 reply
    * `:pending` - no reply in this chunk yet
  """
  @spec scan(binary()) :: {{:ok, rgb()} | :unsupported | :pending, binary()}
  def scan(data) when is_binary(data) do
    {acc, leak_free} = ReplyScanner.scan(data, ReplyScanner.new())

    # scan/1 is stateless per chunk (the driver's contract): a trailing
    # partial reply is handed back untouched so the next chunk re-scans it.
    cleaned = leak_free <> acc.partial

    note_mode_replies(acc)

    case {acc.osc11, acc.sentinel_seen?} do
      {{:ok, rgb}, _} -> {{:ok, rgb}, cleaned}
      {{:invalid, _payload}, _} -> {:unsupported, cleaned}
      {nil, true} -> {:unsupported, cleaned}
      {nil, false} -> {:pending, cleaned}
    end
  end

  # Route parsed DECRQM replies (e.g. mode 2026) to the session
  # capability record so `Capabilities.sync_output?/0` -- the one public
  # emit-gate -- answers from the wire, never from env sniffing.
  defp note_mode_replies(%ReplyScanner{mode: mode}) when map_size(mode) == 0,
    do: :ok

  defp note_mode_replies(%ReplyScanner{mode: mode}) do
    Enum.each(mode, fn {m, value} -> Capabilities.note_mode_reply(m, value) end)
  end

  @doc "Stores a detected background color for later lookup."
  @spec store(rgb()) :: :ok
  def store({_r, _g, _b} = rgb), do: :persistent_term.put(@pt_key, rgb)

  @doc """
  Returns the detected background color, if any.

  Delegates to the unified `Capabilities` record when one has been cached
  for the session; falls back to this module's own `:persistent_term`
  cache (as written by `store/1`) only when no `Capabilities` record is
  cached yet. See the moduledoc's retirement note.
  """
  @spec detected_background() :: {:ok, rgb()} | :error
  def detected_background do
    case Capabilities.cached() do
      {:ok, %{background: {_, _, _} = rgb}} -> {:ok, rgb}
      {:ok, %{background: nil}} -> :error
      :error -> legacy_detected_background()
    end
  end

  defp legacy_detected_background do
    case :persistent_term.get(@pt_key, :undefined) do
      :undefined -> :error
      rgb -> {:ok, rgb}
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
    case Raxol.Terminal.Color.TrueColor.AnsiCodes.parse_hex_6(hex) do
      {:ok, r, g, b, _a} -> {:ok, {r, g, b}}
      {:error, _} -> :error
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
end
