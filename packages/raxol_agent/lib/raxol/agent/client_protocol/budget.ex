defmodule Raxol.Agent.ClientProtocol.Budget do
  @moduledoc """
  Session-lifetime turn and spend cap for the ACP surface.

  `raxol p` has honoured `RAXOL_MAX_COST_USD` and `RAXOL_MAX_TURNS` since the
  benchmark profile landed, but the ACP surface never did, so an editor or a
  harness could drive it until the provider account ran dry. Same env contract,
  same arithmetic, same fail-closed parsing: this is a place to keep the
  running total, not a second budget system.

  Not started when neither cap is set, and `check/0` answers `:ok` when it is
  not running, so callers never branch on whether budgeting is on.

  The bound is the SESSION, not the turn. A turn already under way finishes;
  the next one is refused. Interrupting mid-turn would abandon a half-applied
  edit, which is worse than one turn of overshoot.
  """

  use Agent

  alias Raxol.Agent.BenchmarkProfile

  @name __MODULE__

  @doc "Start only when a cap exists. Returns `:ignore` otherwise."
  @spec start_link(BenchmarkProfile.t()) :: {:ok, pid()} | :ignore
  def start_link(%BenchmarkProfile{max_cost_usd: nil, max_turns: nil}), do: :ignore

  def start_link(%BenchmarkProfile{} = profile) do
    Agent.start_link(fn -> %{profile: profile, usage: %{}, turns: 0} end, name: @name)
  end

  @doc "Whether another turn is affordable. `:ok` when no cap is running."
  @spec check() :: :ok | {:exceeded, :max_turns | :max_cost_usd}
  def check do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> Agent.get(pid, &BenchmarkProfile.budget_status(&1.profile, &1.turns, &1.usage))
    end
  end

  @doc "Fold one completed turn's usage into the running total."
  @spec record(map()) :: :ok
  def record(usage) do
    case Process.whereis(@name) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, fn state ->
          %{
            state
            | usage: BenchmarkProfile.add_usage(state.usage, usage),
              turns: state.turns + 1
          }
        end)
    end
  end

  @doc "Spend so far in USD, and turns taken. For `/usage`-style reporting."
  @spec spent() :: %{cost_usd: float(), turns: non_neg_integer()}
  def spent do
    case Process.whereis(@name) do
      nil ->
        %{cost_usd: 0.0, turns: 0}

      pid ->
        Agent.get(pid, fn s ->
          %{cost_usd: BenchmarkProfile.cost_usd(s.profile, s.usage), turns: s.turns}
        end)
    end
  end
end
