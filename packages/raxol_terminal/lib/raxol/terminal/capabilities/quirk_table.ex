defmodule Raxol.Terminal.Capabilities.QuirkTable do
  @moduledoc """
  Per-terminal quirk corrections applied *after* the naive grammar parse
  (F0 §3 catalog, 04 design §1c).

  Quirks in the 2026 slice:

    * **Alacritty stuck-at-2** -- Alacritty answers DECRQM 2026 with
      `Pm = 2` and the value never flips to `1` after a set. `2` ("mode
      recognized, currently reset") already classifies as supported under
      the generic rule; the quirk records `:no_verify_2026` so callers
      never do a set-then-requery verification (04 §10 Q1: `no_verify`,
      not a value override).
    * **tmux/screen conservative clamp** -- passthrough is off by default
      since tmux 3.3a (F0 §7.4); replies observed inside a multiplexer
      describe the *inner* terminal at best and garble at worst. Clamp:
      `sync_output: false`, tier capped at `:modern`, kitty caps cleared.
      `$TERM=screen` is never trusted to widen anything.
    * **Windows platform gates** -- no XTVERSION / pixel geometry / 2048
      on Windows Terminal; gate those caps by *platform*, not by DECRQM
      absence (F0 §9).
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.ReplyScanner

  @doc "Applies the quirk table to a naively-classified record."
  @spec apply(Capabilities.t(), ReplyScanner.t(), map(), keyword()) ::
          Capabilities.t()
  def apply(%Capabilities{} = caps, %ReplyScanner{} = acc, env, opts \\ []) do
    caps
    |> alacritty_stuck_at_2(acc)
    |> multiplexer_clamp(env)
    |> windows_platform_gate(Keyword.get(opts, :platform))
  end

  # Alacritty reports 2026 but its DECRQM value is stuck at 2: supported,
  # but never verify by set-then-requery (CAP-N-05).
  defp alacritty_stuck_at_2(caps, acc) do
    if identity_name(caps) =~ ~r/alacritty/i and acc.mode[2026] == 2 do
      add_quirk(caps, :no_verify_2026)
    else
      caps
    end
  end

  defp multiplexer_clamp(%{multiplexer: :none} = caps, _env), do: caps

  defp multiplexer_clamp(caps, _env) do
    %{
      caps
      | sync_output: false,
        tier: cap_tier(caps.tier),
        kitty_keyboard: nil,
        kitty_graphics: false,
        source: Map.put(caps.source, :sync_output, :tmux_clamp)
    }
    |> add_quirk(:multiplexer_conservative_clamp)
  end

  defp cap_tier(:rich), do: :modern
  defp cap_tier(tier), do: tier

  defp windows_platform_gate(caps, :windows) do
    %{
      caps
      | in_band_resize: false,
        cell_px: nil,
        source:
          caps.source
          |> Map.put(:in_band_resize, :platform)
          |> Map.put(:cell_px, :platform)
    }
    |> add_quirk(:windows_platform_gates)
  end

  defp windows_platform_gate(caps, _platform), do: caps

  defp add_quirk(caps, quirk) do
    if quirk in caps.quirks do
      caps
    else
      %{caps | quirks: caps.quirks ++ [quirk]}
    end
  end

  defp identity_name(%{identity: {name, _}}), do: name
  defp identity_name(_), do: ""
end
