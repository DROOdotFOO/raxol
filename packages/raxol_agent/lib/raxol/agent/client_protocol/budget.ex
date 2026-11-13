defmodule Raxol.Agent.ClientProtocol.Budget do
  @moduledoc """
  Turn and spend cap for one `raxol acp` connection.

  The caps come from `RAXOL_MAX_TURNS` and `RAXOL_MAX_COST_USD` (which needs
  `RAXOL_COST_PER_MTOK_IN` and `RAXOL_COST_PER_MTOK_OUT`, USD per million
  tokens). `start_link/1` reads those four variables and nothing else, and
  starts a process only when a cap is set. The connection holds the pid;
  where no cap is set it holds `nil`, which allows every turn.

  ## What is counted

  `begin_turn/1` checks the caps and counts the turn in one step, when
  `Raxol.Agent.ClientProtocol.Turn` takes a prompt. A turn therefore counts
  once it has started, whether it is then answered, cancelled or fails, and
  prompts racing on several sessions cannot both take the last turn.

  Spend is the `usage` of the replies that carried one (`record_usage/2`). A
  turn that is cancelled or fails reports none, so its tokens are not under
  the cost cap; the turn cap is the one that bounds them. The turn that
  crosses the cost cap runs to its end, as do turns already running beside
  it; the next prompt is refused.

  ## A cap that cannot be checked

  `begin_turn/1` refuses with `{:exceeded, :cap_unavailable}` when the
  process it was given is gone: a cap that was set never fails open.
  """

  use Agent

  alias Raxol.Agent.BenchmarkProfile

  @cap_variables ~w(RAXOL_MAX_TURNS RAXOL_MAX_COST_USD RAXOL_COST_PER_MTOK_IN RAXOL_COST_PER_MTOK_OUT)

  @typedoc "What a connection holds: the cap's process, or `nil` for no cap."
  @type t :: pid() | nil

  @doc """
  Start the cap `env` (default: the OS environment) sets. `:ignore` when it
  sets none, `{:error, message}` when a cap variable cannot be read or the
  cost cap lacks its two prices.
  """
  @spec start_link(%{optional(String.t()) => String.t()}) ::
          {:ok, pid()} | :ignore | {:error, String.t()}
  def start_link(env \\ System.get_env()) do
    case BenchmarkProfile.from_env(Map.take(env, @cap_variables)) do
      {:ok, %BenchmarkProfile{max_cost_usd: nil, max_turns: nil}} -> :ignore
      {:ok, profile} -> Agent.start_link(fn -> %{profile: profile, usage: %{}, turns: 0} end)
      {:error, _message} = unreadable -> unreadable
    end
  end

  @doc """
  Take one turn: `:ok` and the turn is counted, or the cap that refuses it.
  """
  @spec begin_turn(t()) :: :ok | {:exceeded, :max_turns | :max_cost_usd | :cap_unavailable}
  def begin_turn(nil), do: :ok

  def begin_turn(budget) when is_pid(budget) do
    Agent.get_and_update(budget, fn state ->
      case BenchmarkProfile.budget_status(state.profile, state.turns, state.usage) do
        :ok -> {:ok, %{state | turns: state.turns + 1}}
        exceeded -> {exceeded, state}
      end
    end)
  catch
    :exit, _reason -> {:exceeded, :cap_unavailable}
  end

  @doc "Fold the `usage` a reply carried into the spend."
  @spec record_usage(t(), map()) :: :ok
  def record_usage(nil, _usage), do: :ok

  def record_usage(budget, usage) when is_pid(budget) do
    Agent.update(budget, &%{&1 | usage: BenchmarkProfile.add_usage(&1.usage, usage)})
  catch
    :exit, _reason -> :ok
  end

  @doc "Spend so far in USD, and turns taken."
  @spec spent(pid()) :: %{cost_usd: float(), turns: non_neg_integer()}
  def spent(budget) when is_pid(budget) do
    Agent.get(budget, fn state ->
      %{cost_usd: BenchmarkProfile.cost_usd(state.profile, state.usage), turns: state.turns}
    end)
  end
end
