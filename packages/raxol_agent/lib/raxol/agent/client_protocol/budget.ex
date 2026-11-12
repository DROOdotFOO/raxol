defmodule Raxol.Agent.ClientProtocol.Budget do
  @moduledoc """
  Turn and spend cap for one `raxol acp` connection.

  The caps come from `RAXOL_MAX_TURNS` and `RAXOL_MAX_COST_USD` (which needs
  `RAXOL_COST_PER_MTOK_IN` and `RAXOL_COST_PER_MTOK_OUT`), read by
  `Raxol.Agent.BenchmarkProfile.from_env/1`. Not started when neither is
  set, and `check/0` answers `:ok` when it is not running.

  `Raxol.Agent.ClientProtocol.Turn` checks before each prompt and records
  the `usage` of each answered turn. The turn that crosses a cap runs to its
  end; the next prompt is refused.
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

  @doc "Count one answered turn and fold its usage into the running total."
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
