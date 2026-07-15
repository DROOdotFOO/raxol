defmodule Raxol.Terminal.Capabilities.Ladder do
  @moduledoc """
  Degradation ladder: pure tier selection over the capability record
  (roadmap T3 seam, 04 design §1c / §7).

  Modes:

    * `:inline_log` -- the inline hybrid (scroll-region history + pinned
      footer). Requires a real terminal, no multiplexer, and either a
      Modern/Rich tier or Core with verified sync-output.
    * `:tmux_conservative` -- inside tmux/screen: clamped caps, no OSC
      marks assumed consumed.
    * `:flat` -- append-only + plain prompt, zero regions/cursor jumps.
      The screen-reader answer, the CI/pipe answer. Always safe.

  Env overrides: `RAXOL_FORCE_FLAT=1` forces `:flat` (downgrade is always
  safe; a forced downgrade on a capable terminal emits the
  `[:raxol, :degradation, :forced_downgrade]` telemetry so it is at least
  observable). `RAXOL_FORCE_MODE=inline_log` on an *incapable* record is
  REFUSED -- `select/2` returns `{:error, :incapable}` and
  `assert_capable!/2` raises `IncapableModeError`. Fail loud, never emit
  inline sequences to a terminal that cannot host them (LAD-N-01).
  """

  alias Raxol.Terminal.Capabilities

  defmodule IncapableModeError do
    defexception [:message]

    @impl true
    def exception(opts) do
      mode = Keyword.get(opts, :mode)
      caps = Keyword.get(opts, :caps)

      %__MODULE__{
        message:
          "refusing to run #{inspect(mode)} on an incapable terminal " <>
            "(tier=#{inspect(caps && caps.tier)} " <>
            "sync_output=#{inspect(caps && caps.sync_output)} " <>
            "multiplexer=#{inspect(caps && caps.multiplexer)}); " <>
            "falling back would corrupt the host -- fix the override"
      }
    end
  end

  @type mode :: :inline_log | :tmux_conservative | :flat
  @modes [:inline_log, :tmux_conservative, :flat]

  @truthy ["1", "true", "TRUE", "yes"]

  @doc "The three ladder modes."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  Selects the rendering mode for a capability record. Total: always
  `{:ok, mode}` or `{:error, reason}`, never raises (LAD-P-02).
  """
  @spec select(Capabilities.t(), map()) :: {:ok, mode()} | {:error, term()}
  def select(caps, env \\ %{})

  def select(%Capabilities{} = caps, env) when is_map(env) do
    cond do
      forced?(env, "RAXOL_FORCE_FLAT") or
          Map.get(env, "RAXOL_FORCE_MODE") == "flat" ->
        emit_downgrade_telemetry(caps)
        {:ok, :flat}

      Map.get(env, "RAXOL_FORCE_MODE") == "tmux_conservative" ->
        {:ok, :tmux_conservative}

      Map.get(env, "RAXOL_FORCE_MODE") == "inline_log" ->
        case guard(:inline_log, caps) do
          :ok -> {:ok, :inline_log}
          {:error, _} = error -> error
        end

      caps.tier == :core_minus ->
        {:ok, :flat}

      caps.multiplexer in [:tmux, :screen] ->
        {:ok, :tmux_conservative}

      capable?(:inline_log, caps) ->
        {:ok, :inline_log}

      true ->
        {:ok, :flat}
    end
  end

  def select(_caps, _env), do: {:error, :invalid_capabilities}

  @doc """
  Can this record host the given mode? Downgrades are always safe;
  `:inline_log` needs the scroll-region floor (proxy until T0's verdict:
  tier + sync_output -- 04 §10 Q5) and no multiplexer.
  """
  @spec capable?(mode(), Capabilities.t()) :: boolean()
  def capable?(:flat, %Capabilities{}), do: true
  def capable?(:tmux_conservative, %Capabilities{}), do: true

  def capable?(:inline_log, %Capabilities{} = caps) do
    caps.multiplexer == :none and
      (caps.tier in [:modern, :rich] or
         (caps.tier == :core and caps.sync_output))
  end

  @doc "Non-raising guard: `:ok` or `{:error, :incapable}`."
  @spec guard(mode(), Capabilities.t()) :: :ok | {:error, :incapable}
  def guard(mode, %Capabilities{} = caps) do
    if capable?(mode, caps), do: :ok, else: {:error, :incapable}
  end

  @doc """
  Fail-loud guard: raises `IncapableModeError` when the mode cannot be
  hosted (LAD-N-01). Never proceed and corrupt.
  """
  @spec assert_capable!(mode(), Capabilities.t()) :: :ok
  def assert_capable!(mode, %Capabilities{} = caps) do
    case guard(mode, caps) do
      :ok -> :ok
      {:error, :incapable} -> raise IncapableModeError, mode: mode, caps: caps
    end
  end

  # ---- internals ----

  defp forced?(env, key), do: Map.get(env, key) in @truthy

  # LAD-N-02: forcing :flat on a capable terminal is allowed (downgrade
  # is safe) but observable -- never a silent product downgrade.
  defp emit_downgrade_telemetry(caps) do
    if capable?(:inline_log, caps) do
      :telemetry.execute(
        [:raxol, :degradation, :forced_downgrade],
        %{},
        %{tier: caps.tier, multiplexer: caps.multiplexer}
      )
    end

    :ok
  end
end
