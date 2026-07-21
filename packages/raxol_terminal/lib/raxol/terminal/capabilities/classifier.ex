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
    {background, background_source} = decide_background(acc)
    {foreground, foreground_source} = decide_foreground(acc)
    {color_depth, color_depth_source} = decide_color_depth(acc, env)
    {polarity_seed, polarity_seed_source} = decide_polarity_seed(env)

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
      background: background,
      foreground: foreground,
      color_depth: color_depth,
      polarity_seed: polarity_seed,
      source: %{
        identity: identity_source,
        sync_output: sync_source,
        in_band_resize: resize_source,
        lr_margins: lr_source,
        theme_events: theme_source,
        truecolor: truecolor_source,
        background: background_source,
        foreground: foreground_source,
        color_depth: color_depth_source,
        polarity_seed: polarity_seed_source
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

  # ---- native-palette-riding detection seam (doc §2/§7, amendment A1) ----
  #
  # Wire bytes + env seed only -- no color science here (that's main
  # raxol's Salience module, doc amendment A3). background/foreground are
  # the raw OSC 11/10 replies; color_depth is the env+probe ladder from
  # §2 rungs 0/1/4; polarity_seed is the $COLORFGBG fallback (rung 2),
  # used downstream only when OSC 11 stays silent.

  defp decide_background(%{osc11: {:ok, rgb}}), do: {rgb, :osc11}
  defp decide_background(_acc), do: {nil, :default}

  defp decide_foreground(%{osc10: {:ok, rgb}}), do: {rgb, :osc10}
  defp decide_foreground(_acc), do: {nil, :default}

  # Rung 0 (NO_COLOR, absolute) > rung 4 (XTGETTCAP RGB, probed) > rung 1
  # seed ($COLORTERM) > $TERM *-256color > Core floor (:ansi16). Same
  # XTGETTCAP-over-COLORTERM priority as `decide_truecolor/2` (doc §1
  # provenance corollary), reused verbatim.
  defp decide_color_depth(acc, env) do
    cond do
      present?(env, "NO_COLOR") -> {:none, :no_color}
      Map.has_key?(acc.xtgettcap, "RGB") -> {:truecolor, :xtgettcap}
      Map.get(env, "COLORTERM") in @truecolor_env -> {:truecolor, :colorterm}
      term_256color?(env) -> {:ansi256, :term}
      true -> {:ansi16, :default}
    end
  end

  defp term_256color?(env), do: String.ends_with?(Map.get(env, "TERM") || "", "-256color")

  # $COLORFGBG "fg;bg" (konsole/rxvt family); urxvt sometimes emits a
  # 3-field form -- bg is always the LAST field. bg ∈ {0..6, 8} -> dark;
  # {7, 15} -> light; 9-14 or malformed -> nil (seed only, not a ground).
  defp decide_polarity_seed(env) do
    case Map.get(env, "COLORFGBG") do
      raw when raw in [nil, ""] -> {nil, :default}
      raw -> {polarity_from_colorfgbg(raw), :colorfgbg}
    end
  end

  defp polarity_from_colorfgbg(raw) do
    case raw |> String.split(";") |> List.last() |> then(&Integer.parse/1) do
      {bg, ""} when bg in [0, 1, 2, 3, 4, 5, 6, 8] -> :dark
      {bg, ""} when bg in [7, 15] -> :light
      _ -> nil
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
