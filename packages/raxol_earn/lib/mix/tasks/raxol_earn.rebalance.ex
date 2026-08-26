defmodule Mix.Tasks.RaxolEarn.Rebalance do
  @shortdoc "Run a one-shot rebalance-advisor sweep and print recommendations"

  @moduledoc """
  Reads the solver's live balances (from `config :raxol_payments, :accounting`) and
  prints `Raxol.Payments.RebalanceAdvisor`'s recommendations -- the on-demand
  counterpart of the always-on `Raxol.Payments.RebalanceMonitor`. Recommend-only;
  it moves no funds.

  Requires `RPC_*` and `XOCHI_SOLVER_ADDRESS` (see `config/runtime.exs`).

      mix raxol_earn.rebalance
      mix raxol_earn.rebalance --static-floors

  This sweep is BALANCE-driven only. It runs in its own VM and has no way to
  reach the running deployment's `SettlementLedger` (ETS in the accounting
  process, not on disk), so it starts an empty throwaway one -- which means a
  deployment configured for demand-aware inventory floors gets zero demand for
  every corridor and silently falls back to its static floors. Rather than print
  a "clean" snapshot computed from a policy it cannot honour, this refuses; pass
  `--static-floors` to ask for the static-floor snapshot on purpose.
  """

  use Mix.Task

  alias Raxol.Payments.{ChainReader, RebalanceMonitor, RebalancePolicy, SettlementLedger}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    acc = Application.get_env(:raxol_payments, :accounting, [])
    rpc_urls = Keyword.get(acc, :rpc_urls, %{})
    solver = Keyword.get(acc, :solver_address)

    cond do
      map_size(rpc_urls) == 0 ->
        Mix.shell().error("no rpc_urls configured -- set RPC_* and RAXOL_ACCOUNTING_ENABLED=true")

      is_nil(solver) ->
        Mix.shell().error("no solver_address configured -- set XOCHI_SOLVER_ADDRESS")

      true ->
        dispatch(acc, rpc_urls, solver, resolve_policy(acc, parse_argv(args)))
    end
  end

  @doc "The flags this sweep takes. Unknown switches are ignored, as Mix tasks do."
  @spec parse_argv([String.t()]) :: keyword()
  def parse_argv(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [static_floors: :boolean])
    opts
  end

  @doc """
  The policy this sweep can actually honour, given the deployment's accounting
  config and the parsed flags.

  Demand-aware floors are refused rather than quietly downgraded. The demand
  signal lives in the running deployment's `SettlementLedger`, which is ETS owned
  by that VM's accounting process; a mix task is a different VM and can only
  start an empty one. Every corridor would therefore report no demand and fall
  back to its static floor, so a monitor reporting a demand-widened deficit on
  Base and a task printing "no recommendations" would be two different answers
  from what looks like one tool.

  `--static-floors` is the explicit opt-in: it returns `default/0`'s static
  policy, so the sweep is honest about which floors it used rather than carrying
  demand config it drops.
  """
  @spec resolve_policy(keyword(), keyword()) ::
          {:ok, RebalancePolicy.t()} | {:static, RebalancePolicy.t()} | {:error, String.t()}
  def resolve_policy(acc, opts) do
    configured = RebalancePolicy.with_demand(RebalancePolicy.default(), acc)

    case {RebalancePolicy.demand_aware?(configured), Keyword.get(opts, :static_floors, false)} do
      {false, _} -> {:ok, configured}
      {true, true} -> {:static, RebalancePolicy.default()}
      {true, false} -> {:error, demand_refusal()}
    end
  end

  defp demand_refusal do
    "demand-aware inventory floors are configured " <>
      "(RAXOL_REBALANCE_DEMAND_MULTIPLIER), and this one-shot sweep cannot read them: " <>
      "the demand signal is in the running deployment's SettlementLedger, and a mix task " <>
      "is a separate VM that can only start an empty one. Every corridor would report no " <>
      "demand and fall back to its static floor. Read demand-aware recommendations from " <>
      "the running RebalanceMonitor, or re-run with --static-floors to take the " <>
      "static-floor snapshot on purpose."
  end

  defp dispatch(_acc, _rpc, _solver, {:error, message}), do: Mix.shell().error(message)

  defp dispatch(acc, rpc_urls, solver, {:static, policy}) do
    Mix.shell().info("--static-floors: sweeping with static inventory floors, demand ignored")
    sweep(acc, rpc_urls, solver, policy)
  end

  defp dispatch(acc, rpc_urls, solver, {:ok, policy}), do: sweep(acc, rpc_urls, solver, policy)

  defp sweep(acc, rpc_urls, solver, policy) do
    # A throwaway ledger. The drain it would carry only tiebreaks refuel ordering,
    # and `resolve_policy/2` has already refused any policy that would read the
    # demand half, so an empty one still yields correct balance-driven
    # recommendations for a snapshot.
    ledger =
      case SettlementLedger.start_link(table_name: :raxol_earn_rebalance_task) do
        {:ok, pid} ->
          pid

        # Re-running the sweep in one VM (or an ETS table left by a prior run)
        # is not a failure -- the ledger is a throwaway either way.
        {:error, {:already_started, pid}} ->
          pid

        {:error, reason} ->
          Mix.raise("could not start the throwaway settlement ledger: #{inspect(reason)}")
      end

    RebalanceMonitor.advise_once(
      ledger: ledger,
      reader: ChainReader.JSONRPC.new(chains: rpc_urls),
      solver_address: solver,
      policy: policy,
      chains: Map.keys(rpc_urls),
      price_source: Keyword.get(acc, :price_source, :coingecko)
    )
    |> print()
  end

  defp print([]), do: Mix.shell().info("no recommendations")
  defp print(recs), do: Enum.each(recs, &Mix.shell().info(format(&1)))

  defp format({:refuel_gas, r}) do
    "refuel_gas #{r.chain_id} #{r.native_symbol}: buy #{dec(r.native_to_buy)} " <>
      "via #{r.source} (funding #{r.funding})"
  end

  defp format({:rebalance_inventory, r}) do
    "rebalance #{r.symbol} #{r.from_chain}->#{r.to_chain} #{dec(r.amount)} via #{r.rail}"
  end

  defp format({:alert, a}) do
    "ALERT #{a.kind} #{a.symbol} chain #{a.chain_id} deficit #{dec(a.deficit)}"
  end

  defp dec(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp dec(other), do: inspect(other)
end
