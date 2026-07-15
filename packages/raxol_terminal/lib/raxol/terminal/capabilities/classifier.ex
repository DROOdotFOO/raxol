defmodule Raxol.Terminal.Capabilities.Classifier do
  @moduledoc """
  Pure classifier: scanner accumulator + env seed -> `%Capabilities{}`
  (04 design §1c).

  The env seed is a *free first pass only* -- it can set `multiplexer`
  and seed `truecolor` (marked `source: :env`), but a probe-able
  capability like mode 2026 is only ever set from a DECRQM reply
  (`source: :decrqm`). The quirk table runs after the naive parse.
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.{QuirkTable, ReplyScanner}

  @truecolor_env ["truecolor", "24bit"]

  @doc """
  Classifies a scan accumulator into a capability record.

  Options:

    * `:tty?` -- `false` forces the Core-minus non-TTY path (CAP-P-12)
    * `:platform` -- `:windows` applies the platform gates (CAP-N-12)
  """
  @spec classify(ReplyScanner.t(), map(), keyword()) :: Capabilities.t()
  def classify(%ReplyScanner{} = acc, env, opts \\ []) when is_map(env) do
    tty? = Keyword.get(opts, :tty?, true)

    multiplexer = detect_multiplexer(env)
    {sync_output, sync_source} = decide_mode(acc.mode, 2026)
    {resize, resize_source} = decide_mode(acc.mode, 2048)
    {lr_margins, lr_source} = decide_mode(acc.mode, 69)
    {theme_events, theme_source} = decide_mode(acc.mode, 2031)
    {grapheme_2027, _} = decide_mode(acc.mode, 2027)
    {truecolor, truecolor_source} = decide_truecolor(acc, env)
    {identity, identity_source} = decide_identity(acc)

    %Capabilities{
      identity: identity,
      tier: tier(acc, tty?),
      unicode: if(grapheme_2027, do: :grapheme, else: :wide),
      truecolor: truecolor,
      sixel: sixel?(acc),
      sixel_regs: acc.sixel_regs,
      kitty_graphics: acc.kitty_graphics == true,
      kitty_keyboard: acc.kitty_kbd,
      sync_output: sync_output,
      grapheme_width: if(grapheme_2027, do: :mode_2027, else: :assumed),
      in_band_resize: resize,
      lr_margins: lr_margins,
      theme_events: theme_events,
      cell_px: acc.cell_px,
      styled_underline: Map.has_key?(acc.xtgettcap, "Smulx"),
      multiplexer: multiplexer,
      source: %{
        identity: identity_source,
        sync_output: sync_source,
        in_band_resize: resize_source,
        lr_margins: lr_source,
        theme_events: theme_source,
        truecolor: truecolor_source
      }
    }
    |> QuirkTable.apply(acc, env, opts)
  end

  # ---- DECRQM value semantics (F0 §3): {1,2} supported, else not ----

  defp decide_mode(modes, mode) do
    case Map.fetch(modes, mode) do
      {:ok, value} when value in [1, 2] -> {true, :decrqm}
      {:ok, _other} -> {false, :decrqm}
      :error -> {false, :default}
    end
  end

  # ---- truecolor priority: XTGETTCAP RGB (probed) > $COLORTERM (seed) ----

  defp decide_truecolor(acc, env) do
    cond do
      Map.has_key?(acc.xtgettcap, "RGB") -> {true, :xtgettcap}
      Map.get(env, "COLORTERM") in @truecolor_env -> {true, :env}
      true -> {false, :default}
    end
  end

  # ---- identity: XTVERSION, DA2 fallback (no static DA2 table yet) ----

  defp decide_identity(%{xtversion: {_, _} = identity}),
    do: {identity, :xtversion}

  defp decide_identity(%{da2: params}) when is_list(params), do: {nil, :da2}
  defp decide_identity(_acc), do: {nil, :default}

  # ---- tier bucketing (output labels per terminfo.dev, F0 §5) ----

  defp tier(_acc, false), do: :core_minus

  defp tier(%{sentinel_seen?: false, da1: nil}, _tty?), do: :core_minus

  defp tier(acc, _tty?) do
    cond do
      rich?(acc) -> :rich
      modern?(acc) -> :modern
      true -> :core
    end
  end

  defp rich?(acc) do
    is_integer(acc.kitty_kbd) or acc.kitty_graphics == true
  end

  defp modern?(acc) do
    acc.mode[2026] in [1, 2] or acc.xtversion != nil or
      Map.has_key?(acc.xtgettcap, "RGB")
  end

  # ---- sixel: DA1 attribute 4 or reported color registers ----

  defp sixel?(%{da1: [_level | attrs]} = acc) when is_list(attrs) do
    4 in attrs or (is_integer(acc.sixel_regs) and acc.sixel_regs > 0)
  end

  defp sixel?(acc) do
    is_integer(acc.sixel_regs) and acc.sixel_regs > 0
  end

  # ---- multiplexer detection ($TERM=screen never trusted to widen) ----

  defp detect_multiplexer(env) do
    cond do
      present?(env, "TMUX") -> :tmux
      String.starts_with?(Map.get(env, "TERM") || "", "screen") -> :screen
      true -> :none
    end
  end

  defp present?(env, key) do
    case Map.get(env, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
